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

## 12. As built: inspection and retry (M3 group B)

- **The ClientHello is peeked, never read.** A connection on an `inspect: Sni` listener starts `Inspecting`, watched
  for input. On input the worker `MSG_PEEK`s everything queued (up to 32 KB) into one per-worker inspect buffer and
  asks `parse_hello`. The bytes stay in the kernel, so the backend receives them from byte 0 (RT-3c).
- **One inspect at a time per worker.** The inspect buffer (32 KB) and the reassembly scratch (16 KB) are fields of the
  worker, not of a connection: the worker handles one event at a time, so one pair is enough and a connection holds
  nothing between events but the bytes the kernel queued. 500 connections each holding 1200 bytes of a half-sent hello
  grew RSS by 36 kB (RT-3f).
- **A short hello is never peeked again on a timer, nor twice.** `NeedMore{total}` raises the socket's `SO_RCVLOWAT` to
  `total`: with level-triggered epoll the socket is reported readable again only when that many bytes are queued, or the
  peer ends. A wake-up with no new bytes can therefore only be the peer ending, and the connection is closed. The
  low-water mark goes back to 1 before forwarding. (The design sketch said edge-triggered; the engine is
  level-triggered, and the low-water mark gives the same "wait for the next input".)
- **Invalid, or a `total` past the inspect buffer, closes the connection as `InvalidHello`** at once, from the record
  header if that is enough (a record over 16384 bytes). A non-TLS first byte is `NotTls`: routed by a `NoSni` or `Any`
  row after that one byte, without waiting (RT-3g).
- **Timeouts are one sweep, not a timer per connection.** Every 250 ms the loop walks the slot table and closes the
  connections that have waited longer than `inspect_timeout_ms` since accept (`InspectTimeout`); measured close times for
  a 1 s limit are 1.0-1.25 s (RT-3d). The connect timeout joins the same sweep in M4.
- **Retry.** A connection starts at address `k mod n` (k counts routed connections) and, after each failure, tries the
  next address, wrapping, until each has been tried once; then it is closed as `ConnectFailed`. The client has no
  interest registered until the server answers, so none of its bytes are consumed before a connect succeeds (RT-4c).
  `connect_failures` counts every failed attempt and `retries` the failures that were followed by another attempt.

## 13. As built: handler mode (M3 group C)

- **Events are queued, not called.** The engine appends flat `_PendingEvent` records (Opened, Data, Writable, Closed) while it
  dispatches a batch of epoll events, and `serve` drains the queue after the batch and after each Tick, calling the user's block
  once per record, including the records the block itself causes. No engine function is generic over the block, and the events
  of one connection are in the order they happened (RT-9a).
- **A Data event owns its pool buffer until the block returns**, and a connection has at most one Data pending (reading stops
  until the block has seen it), so a slow handler pins at most one buffer per connection. If the connection closes first, the
  record still owns the buffer and gives it back after delivery.
- **Output** is a queue of up to 4 pool buffers per connection; `send` is all or nothing, copies, then writes what the socket takes
  at once. `Writable` is queued once, after a refused send, when the queue drops below one buffer.
- **A peer's FIN closes the connection after the flush** (v1: no half-closed handler connections). `close` does the same, with
  reason `ByHandler`; `reset` closes now with an RST.
- **`forward`** copies the `Target` into a side table (`_override_targets`; a free entry has no addresses) and hands the connection
  to the forwarding path; the handler's ownership ends there and no Closed event follows.
- **Measured:** 100,000 keep-alive requests from 100 clients in 2.4 s (client-bound: Python); 50 Ticks in 5 s with the largest gap
  101 ms under 50 busy connections; a 64 MB send to a client that reads nothing for 2 s grew the server's RSS by 164 kB.

## 14. As built: timeouts (M4 group A)

- Each slot has `started_ms` (accept, or the start of the current connect attempt), `last_active_ms` (bytes moved in either
  direction, stamped from the loop's own clock reading, `_now_ms`, so no extra syscall per read) and `half_closed_at_ms`.
- One sweep every 250 ms walks the slot table: inspect (`InspectTimeout`), connect (the attempt is failed and the next address is
  tried, so a timed-out connect is retried exactly like a refused one: RT-4c), idle (`IdleTimeout`) and half-open
  (`HalfCloseTimeout`, measured from the later of the first EOF and the last byte, so data in the direction still open keeps it
  alive). Handler connections are covered by the idle rule.
- Measured, limit / closed at: connect 0.5 s / 0.60 s, idle 1.0 s / 1.20 s, half-close 1.0 s / 1.00-1.10 s: every one in limit
  to limit + 250 ms, the sweep period.

## 15. As built: messages and drain (M4 group B)

- **One pipe per worker**, made by `spawn()` before any worker starts (a global set in `main` is copied into each worker at spawn, so
  `start()` finds its own read end by index, and a control thread started after `spawn` can `post`). A message is one 16-byte flat
  record (kind, tag, generation, value); a pipe write that small is atomic. The worker registers its read end in epoll as a fourth event
  kind. At most 64 workers per `spawn`.
- **Messages are handled before the events of the same pass**: the loop reads the pipe first, then dispatches the rest of the batch, so a
  drain (and later a fence) cannot be outrun by a burst of traffic.
- **Drain.** `Message.Drain { deadline_ms }` closes the worker's listeners at once (new connections are then refused by the kernel and a
  new process can bind the port: RT-8a), lets open connections finish, and records the deadline. Once per loop pass the worker checks:
  nothing open means `serve` returns; past the deadline the rest are closed as `Drained` (their Closed events are delivered) and `serve`
  returns. `wait_for_signal_then_drain` reads the signalfd, posts the drain and `thread_wait`s for every worker.

## 16. As built: tags, deadlines, fences and stats across workers (M4 group C)

- **A tag and a generation come from the target** (`Target.tag`, `Target.gen`, or the tag of a `Handle` route) and are copied into the
  slot. Tag 0 is never fenced. Each worker keeps a small table of `(tag, until_ms)`; a tag with no entry is free, an entry with
  `until_ms` in the future allows connections, and `until_ms == 0` (a tag from `Config.fenced_tags` with no deadline yet) fences it.
- **The latest deadline wins** (`Message.Deadline`): a later `until_ms` renews, an earlier or equal one changes nothing, so a delayed or
  duplicate message cannot shorten or stretch anything. Revoking is `CloseTagged` or a fence, never a smaller deadline.
- **Where the deadline is enforced.** (1) When a connection is routed: a fenced or expired tag is closed at once. (2) Once per pass of
  the loop, after the messages and before any event is dispatched (`_enforce_deadlines`): the slot table is scanned only when some
  deadline has just expired (`_deadline_scan_at`), so a worker with no deadlines, or none due, pays one comparison. A process that was
  frozen across a deadline therefore closes the tag's connections before it looks at the readable data that woke it (RT-6a).
  (3) Before every write in the forwarding path, in both directions (to the server and to the client): `_flush_direction` checks the tag
  with the pass's clock reading and drops bytes under an expired tag.
- **`CloseTagged { tag, gen }`** closes (as `Fenced`) every connection of the tag whose target generation is `<= gen`, in the message
  handler, so it runs before the events of the same pass (RT-6b).
- **Stats across workers.** `Message.Stats` makes each worker `qput` a `_StatsReply { worker, stats }`; `gather_stats(workers)` posts one
  and adds up that many replies (one caller at a time: the replies share a queue). Sessions per tag are counted by walking the slots when
  `stats(w)` is called, not kept up to date.
- **Measured:** message_test 13 of 13 (exact sums over 4 workers, 390 connections); deadline_test 35 of 35 including the SIGSTOP/SIGCONT case
  with traffic in both directions.
