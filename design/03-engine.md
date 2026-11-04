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

struct Slot {                                          // one per connection, in a slot_pool [V t04]
    gen: u32,                  // bumped on free; a handle or event with an old gen is ignored
    state: State,              // Inspecting, Connecting, Forwarding, Handling, Closing
    client: Side,
    server: Side,              // unused in handler mode
    route: u16,
    tag: u16,                  // handler tag or forward tag (for close-tagged)
    retry: Retry,              // which target addresses were tried
    last_active_ms: i64,
    inflight: u8,              // kernel ops that still refer to this slot (io_uring later; 0 with epoll)
}

struct Side { fd: i32, buf: i32 = -1, len: u32, pos: u32, eof: bool, shut_wr: bool, paused: bool }
```

- **epoll data = (slot, gen, side)** packed in the `u64` [R]: 32 bits slot, 24 bits gen, 8 bits
  side/kind (listener, client, server, message pipe). An event whose gen differs from the slot's
  is stale and dropped (RT-2b). **Validate the slot index before use** (goose-kb rule MUST-4):
  an out-of-range index from the kernel must not abort the worker.
- **A slot is freed only when its fds are closed and `inflight == 0`.** With epoll that is
  immediate; the field exists so io_uring can be added without changing the model.
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

## 10. io_uring later

The model above is engine-neutral: slots with generations, explicit `inflight`, stable buffers,
tag dispatch. The io_uring engine replaces §2's `epoll_wait` and §4's read/write calls behind the
same functions, through a thin C sidecar for liburing (the C proxy's pattern). It must pass the
same tests (doc 06).
