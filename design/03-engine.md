# 03 — The engine

How one worker runs. Everything here is internal: none of it appears in the public API (doc 02).

## 1. Workers

- **One worker = one `thread_fn` = one epoll loop**, owning its listeners, connections, buffers
  and tables. No locks and no atomics on the data path [R; matches the C proxy].
- **Accept:** each worker binds its own listening socket with `SO_REUSEPORT`; the kernel spreads
  new connections across them. No hand-off between threads.
- **The port-theft trap** (Steve): `SO_REUSEPORT` lets a *second process* bind the same port
  silently and take a share of the connections. That caused a false "sessions bug" in the C
  proxy. So worker 0 first tries to bind without `SO_REUSEPORT` and fails if the port is in use
  (RT-1d), and tests check their ports are free before starting (doc 06).

## 2. The loop

```
loop:
    drain this worker's message pipe          (config, drain, close-tagged, stats)   §7
    check deadlines of tagged backends        (close-tagged by time)                 §6
    epoll_wait(timeout = time to next sweep, at most 100 ms)
    for each ready fd: dispatch on the tag in the event's data                       §3
    if a sweep is due: timeouts                                                       §5
    if a Tick is due: call the handler block with Tick
until drained or stopped
```

Messages and deadlines come **before** events in every pass, so a fence can never be outrun by a
burst of traffic (RT-6b). The C proxy learned this the hard way (463f670).

## 3. Connection slots and handles

```goose
struct Conn { slot: u32, gen: u32 }                    // public handle (doc 02)

struct _ConnectionSlot {                                       // one per connection, in a table inside the Worker root
                                                       // (a root cannot contain a slot_pool [V M0]); private names start with `_`; names that come from C start with `c_`
    gen: u32,                  // bumped on free; a handle or event with an old gen is ignored
    state: State,              // Inspecting, Connecting, Forwarding, Handling, Closing
    client: Side,
    server: Side,              // unused in handler mode
    route: u16,
    tag: u16,                  // handler tag or forward tag (for close-tagged)
    retry: Retry,              // which target addresses were tried
    last_active_ms: i64,
}

struct Side { fd: i32, buf: i32 = -1, len: u32, pos: u32, eof: bool, shut_wr: bool, paused: bool }
```

- **epoll data = (slot, gen, side)** packed in the `u64` [R]: 32 bits slot, 24 bits gen, 8 bits
  side/kind (listener, client, server, message pipe). An event whose gen differs from the slot's
  is stale and dropped (RT-2b). **Validate the slot index before use** (goose-kb rule MUST-4):
  an out-of-range index from the kernel must not abort the worker.
- **A slot is freed when its fds are closed**, and its generation is bumped at that moment.
- **Hot and cold fields:** start with one struct. Split into parallel arrays only if `bench/`
  shows it matters (doc README ground rule 2).

## 4. Buffers and backpressure

- **A per-worker buffer pool**: `buffers_per_worker` buffers of `buffer_size` bytes, allocated
  once at start in one array, handed out by index (`Side.buf`).
- **An idle connection holds no buffer.** A side borrows one only to read; if everything read was
  written at once, the buffer goes straight back (RT-5a). So memory per idle connection is the
  slot only (target: ≤ 256 bytes, RT-5b).
- **Backpressure:** while a side holds unwritten bytes, the engine stops reading from the other
  side (EPOLLIN off) and waits for EPOLLOUT on the destination (RT-5c). One buffer per direction
  at most, so a slow reader pins at most two buffers.
- **Pool empty:** new reads wait (EPOLLIN stays off for sides wanting a buffer) until one returns.
  Nothing aborts; the stats count waits (RT-5d). v2's splice-with-pipes moves pending bytes into
  the kernel so slow readers stop pinning userspace buffers at all (as the C proxy does).
- **Stable memory:** the pool is allocated before any I/O and never grows or moves while the
  kernel may write into it. Whether a Goose growable array can be grown in place without moving
  is open (doc 09, O-3); the design does not depend on it.
- **Slow destinations can pin the pool.** A buffer is held only while its destination is not taking bytes, so
  enough stalled connections pin every buffer and healthy connections on the same worker wait for one (measured
  in M2: 100 stalled transfers pinned all 4 buffers of a 4-buffer pool and 20 healthy echo clients waited, then
  finished intact; RT-5d). RT-5f (fairness) is where this is looked at.
- **Fairness:** at most 64 KB moved per side per wakeup; then the loop moves on (RT-5f).
- **Handler-mode output:** `send` copies into the connection's output queue (a chain of pool
  buffers, capped at 4 per connection); `Writable` fires when it drains below one buffer.

## 5. Timeouts

No timer per connection. Every 250 ms the loop sweeps slots in use and closes those past
`inspect`, `connect`, `idle` or `half-close` limits, using `last_active_ms` and `state` (RT-7a–d).
If sweeping all slots shows up in `bench/` at high connection counts, keep a compact list of
active slots; not before.

## 6. Close-tagged and deadlines

- **`CloseTagged(tag, gen)`**: close every connection forwarded under `tag` whose route was set up
  under generation ≤ `gen`. This is the primitive behind lease fences; tcprouter doesn't know what
  a lease is.
- **Deadlines** (from tcpproxy, doc 07): "tag T may forward until absolute time D". Checked at the
  top of every pass and before any write to a server side under that tag, so a worker that was
  frozen (SIGSTOP, VM pause) forwards **zero** bytes after D, even if the first thing it does on
  waking is handle a readable socket (RT-6a).
- **Clock:** deadlines use `CLOCK_BOOTTIME` (counts through suspend), not `CLOCK_MONOTONIC` (RT-6c).

## 7. Messages to workers

Goose's typed queues are shared per type: a `qput` reaches one worker, not all [V goose-kb].
Broadcast needs per-worker addressing. Verified [V, M0 O-2]:

- Each worker owns a **message pipe** (`pipe2`), registered in its epoll. `spawn(cfg, n, worker)`
  creates all `n` pipes **before** spawning (globals set in `main` are copied into each worker at
  spawn), so `start()` finds its own read end in that copy by its index, and `post(m)` writes the flat
  message to every write end. Messages are small and fixed size (≤ `PIPE_BUF`), so one write is
  atomic. 4 workers each received a broadcast exactly once.
- A typed queue is the opposite: one `qput`, one receiver. It carries replies (stats) back to one
  collector, tagged with the worker index.
- Goose has no per-thread queue (the queue is selected by type alone), so pipes it is.

## 8. Drain

`Drain(deadline)`: close listeners at once (new connections go to other processes, RT-8a), let
existing connections finish, close what remains at the deadline, then `serve` returns (RT-8b).
A program restart = new process binds (`SO_REUSEPORT`), old process drains.

## 9. Stats

Per-worker counters (accepted, closed by reason, bytes each way, connect failures, retries,
buffer waits, sessions per tag) kept in plain fields, sent on request (§7). Never shared memory.

## 10. No io_uring

epoll only (user, 2026-11-04): the C proxy's io_uring engines gave little over epoll in Steve's
benchmarks, so tcprouter does not carry a second engine.

## 11. As built in M2 (facts the tests measured; Brian, 2026-11-04)

- **Level-triggered epoll.** Interest is derived from state, never remembered: a source is read only when its
  direction has no unwritten bytes, is not at EOF and is not waiting for a buffer; a destination is watched for
  writability only while bytes are pending. `_update_epoll_interest` recomputes both masks after every change.
- **The pool grows lazily**, one buffer at a time up to `buffers_per_worker`, by appending to a growable array.
  An idle worker touches no buffer memory (RSS 4.7 MB at start). Growth never moves existing memory, so a buffer the
  kernel is writing into stays put (design/09 O-3, verified).
- **One buffer per direction, only while bytes are unwritten.** An idle connection holds none (RT-5a). Under pressure
  a read that finds the pool empty is queued (FIFO, with a generation so a closed connection's entry is skipped) and
  woken when a buffer returns.
- **The client is not read until the server connect completes** (registered with no interest), so a failed connect can
  still be retried with the client's bytes untouched (RT-4c, M3).
- **EOF becomes `shutdown(SHUT_WR)` on the other side**, the direction stops being read, and the connection closes when
  both directions have ended and told their destinations (half-close both ways, RT-4b).
- **Event data is `kind | gen << 8 | slot << 32`** and is validated before use: an out-of-range slot adds to
  `bad_events`, a generation that no longer matches adds to `stale_events`; neither touches a connection.
- **`spawn()` blocks SIGTERM/SIGINT before starting workers** (they inherit the mask; `wait_for_signal_then_drain` reads
  a signalfd) and **probes every listener with a plain socket**, so a port held by another process is an error and not a
  silently shared port (RT-1d's mechanism; its test is in M3). Worker 0 does not probe, as sketched in §1: workers start
  concurrently, so a worker probing after another had bound with SO_REUSEPORT would fail for no reason.
- **The C layer (`src/c_sys.c`) returns `-errno`** and builds `sockaddr` itself, so no struct layout is shared with Goose
  except the 12-byte epoll event, which `_Static_assert` and a unit test pin.
- **Measured:** 58 bytes of RSS per idle connection (RT-5b limit 512); 1,000 idle connections +64 kB; a backend that never
  reads stops a 1 GB offer at about 6.7 MB with no RSS growth (RT-5c).
- **Running out of resources (RT-1e).** When `accept` fails with EMFILE, ENFILE, ENOMEM or ENOBUFS the worker counts
  `accept_failures` and takes that listener out of epoll for 100 ms. Without that, level-triggered epoll would report
  the same pending connection again at once and the loop would spin at 100% of a core (measured: it did). The clients
  wait in the kernel's backlog and are served when descriptors come back. A client that left before `accept`
  (ECONNABORTED, EPROTO) is skipped. A failed outgoing connect (also EMFILE) closes that connection as ConnectFailed.
