# 05 — Requirements

One behaviour per row, with a pass/fail check. Priorities: **v1** (first release), **v2**, **later**.
Status: `design` (not started), `red` (test written and approved, failing), `green` (passes), `done`
(green on CI and documented). Every test file lists the row ids it proves in its first comment;
`tests/coverage.sh` (Brian) prints rows without a test.

Columns: id · behaviour · priority · test · status.

## RT-1 Listeners and workers

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-1a | A worker listens on every configured IPv4 and IPv6 address and accepts connections | v1 | `listen_test` | green |
| RT-1b | N workers on one port share new connections: with 4 workers and 400 connections, each worker gets at least 50 | v1 | `listen_test` | green |
| RT-1c | `check(cfg)` rejects: duplicate listener ids, a route to an unknown listener, `Sni` rows on a listener without `inspect: Sni`, empty targets; each with a message naming the field | v1 | `config_test` | green |
| RT-1d | Starting while another process holds the port fails with an error naming the address, instead of silently sharing it | v1 | `listen_test` | green |
| RT-1e | `worker()` and `serve()` never call `abort` or `exit` for anything a peer or the OS does (resets, EMFILE, ENOBUFS); they count and continue | v1 | `chaos_test` | green |

## RT-2 Connections

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-2a | 10,000 concurrent idle connections per worker are held | v1 | `scale_test` | green |
| RT-2b | An event or handle carrying an old generation never touches the connection now in that slot (1,000,000 open/close cycles with slot reuse, random resets) | v1 | `generation_test` | green |
| RT-2c | Slot indices from the kernel are range-checked; an out-of-range index is counted and dropped | v1 | `generation_test` | green |

## RT-3 Routing

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-3a | `Match.Any` routes every connection on a listener (port routing) | v1 | `route_test` | green |
| RT-3b | SNI routing: exact (case-insensitive, trailing dot ignored), then longest suffix, then `NoSni`, then `Any`; first in config order within a kind | v1 | `route_test` | green |
| RT-3c | The backend of a forwarded SNI connection receives the client's bytes from byte 0, unchanged (ClientHello not consumed) | v1 | `sni_forward_test` | green |
| RT-3d | A client that sends nothing within `inspect_timeout_ms` is closed | v1 | `sni_forward_test` | green |
| RT-3e | The parser passes vectors S1–S12 (doc 04) | v1 | `sni_test` | green |
| RT-3f | A ClientHello over 16 KB is closed, not buffered | v1 | `sni_test`, `route_test`, `sni_forward_test` | green (sni, route and engine halves) |
| RT-3g | A non-TLS client on an `inspect: Sni` listener is routed after its first byte (no wait) | v1 | `route_test`, `sni_forward_test` | green (route and engine halves) |

## RT-4 Forwarding

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-4a | Bytes are forwarded both ways exactly (64 clients × 10 MB random, checksums match) | v1 | `forward_test` | done |
| RT-4b | Half-close: client shuts down writing → backend sees EOF, and the backend's remaining reply still reaches the client; and the reverse | v1 | `forward_test` | done |
| RT-4c | A refused or timed-out connect is retried on the next target address **before any client byte is consumed**, and the client sees a normal reply | v1 | `retry_test`, `timeout_test` | green (refused and timed-out halves) |
| RT-4d | When every target fails, the client connection is closed and `connect_failed` counted | v1 | `retry_test` | green |
| RT-4e | `forward(c, target)` from handler mode works only before any byte was consumed; afterwards it is refused | v1 | `handler_test` | green |
| RT-4f | Throughput and p99 latency within 10% of the C proxy's copy engine on the same host (`bench/`) | v2 | `bench/compare.sh` | design |
| RT-4g | splice forwarding with a pipe pool; same tests as RT-4a/b pass | v2 | `forward_test --splice` | design |

## RT-5 Memory and backpressure

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-5a | An idle forwarded connection holds no pool buffer | v1 | `memory_test` | green |
| RT-5b | Memory per idle connection ≤ 512 bytes of worker memory beyond kernel socket buffers (RSS growth over 10,000 idle) | v1 | `memory_test` | green |
| RT-5c | A destination that stops reading stops the engine reading from the source; RSS grows ≤ 64 MB while 1 GB is offered (measured growth printed each run) | v1 | `backpressure_test` | done |
| RT-5d | With the pool exhausted, the worker keeps serving other connections as buffers return; no abort, waits counted | v1 | `backpressure_test` | done |
| RT-5e | Handler `send` returns false at the per-connection cap and `Writable` follows once drained; memory stays bounded | v1 | `handler_test` | green |
| RT-5f | One busy connection can't starve others: with one 1 GB stream and 100 small request/reply clients, small p99 < 10 ms | v1 | `fairness_test` | green |
| RT-5g | No allocation on the established forwarding path (Goose `--stats` or data-stack high-water flat across 10 GB forwarded) | v1 | `flat_memory_test` | green |

## RT-6 Tags, fences and deadlines

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-6a | Past a tag's deadline, **zero** bytes are forwarded to or from that tag's servers, also after the process was frozen (SIGSTOP) across the deadline and resumed | v1 | `deadline_test` (frozen case) | green |
| RT-6a-H | The same guarantee in handler mode: a Handle-tagged connection is sent **zero** bytes after its tag's deadline, also when the worker is held up inside the user's block across the deadline and when the process was frozen. `send` and the output flush read the clock themselves and close the connection as Fenced | v1 | `handler_deadline_test` | green (100 runs alone, 100 under load) |
| RT-6b | `CloseTagged(tag, gen)` closes every matching connection within one loop pass, before handling further events | v1 | `deadline_test` | green |
| RT-6c | Deadlines are on `CLOCK_BOOTTIME` | v1 | `deadline_test` (unit, clock source) | green |
| RT-6d | Deadlines are absolute and the latest wins: a later `until_ms` renews, an earlier or equal one is ignored, so a delayed old message or a duplicate can neither shorten nor stretch a deadline. Revoking is `CloseTagged` or a fence, never a smaller deadline | v1 | `deadline_test` | green |
| RT-6e | A tag can start fenced (no deadline yet = no connections) | v1 | `deadline_test` | green |
| RT-6f | `ReplaceDeadline { tag, until_ms }` sets the tag's deadline exactly: shorter, longer or the same, unlike the latest-wins `Deadline` (RT-6d), which ignores an earlier one. **`until_ms = 0` means "this tag is unfenced": it clears the deadline AND lifts the start fence (RT-6e).** It is not a "clear the deadline only" message. The engine has no notion of `lease_required`: that rule lives in tcpproxy's policy, which refuses `lease off` on such servers. Safe because shortening a fence is always safe, and only extending one needs ordering, which one control thread writing FIFO pipes gives | post-v0.1.0 | `replace_deadline_test` | green: 100 of 100 runs alone (after the ack fix) and 100 of 100 under load (8 busy loops, host lock, code of a3a5f2c) |
| RT-6g | A full per-worker deadline table fails closed: a tag whose deadline cannot be recorded (the 65th) is fenced, and so is every tag without an entry, never silently unfenced; open connections of such tags are closed at once. Red before the fix (the 65th tag was served), green after | post-v0.1.0 | `tag_overflow_test` | green |

## RT-7 Timeouts

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-7a | Connect timeout per attempt | v1 | `timeout_test` | green |
| RT-7b | Idle timeout closes a connection with no bytes either way | v1 | `timeout_test` | green |
| RT-7c | Half-close timeout closes a connection left half-open | v1 | `timeout_test` | green |
| RT-7d | Each timeout fires within its limit + 300 ms | v1 | `timeout_test` | green |

## RT-8 Lifecycle

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-8a | `Drain`: listeners close at once; a new process on the same port gets all new connections | v1 | `drain_test` | green |
| RT-8b | `Drain` returns when the last connection closes, or closes the rest at the deadline | v1 | `drain_test` | green |
| RT-8c | SIGTERM and SIGINT start a drain (via `wait_for_signal_then_drain`) | v1 | `drain_test` | green |
| RT-8d | `wait_for_signal() -> i32` blocks until SIGTERM, SIGINT or SIGUSR1 and returns its number; `wait_for_signal_then_drain` is a wrapper over it and `drain` | post-v0.1.0 | `signal_test` | green |
| RT-8e | `drain(deadline_ms) -> i64` returns the number of open sessions closed at the deadline (0 = every session ended by itself); sessions that end during the drain are not counted; every worker reports once, also one that failed to start | post-v0.1.0 | `signal_test` | green |
| RT-8f | KNOWN KERNEL BEHAVIOUR, measured, not gating: during a drain a connect that arrives in the instant a worker's SO_REUSEPORT listener closes can be dropped and retried by the client after 1 s. RT-8a and RT-8c assert the listener is gone (no listener for the port, asked of the kernel with `ss`; reading /proc/net/tcp measured the reader, 64 ms per read on a busy host) within 0.3 s; `drain_stall_test` reports how often the first connect stalls (3 of 120 once, then 0 of 600). Stress measure (8 workers, 6 client threads hammering connect while SIGTERM arrives, 100 iterations per run): 17 of 200 iterations stalled with the plain close, 11 of 200 with shutdown(RDWR) before close, 15 of 200 with shutdown + 30 ms + close: no variant moved the rate beyond noise (T07b, null result) | post-v0.1.0 | `drain_stall_test` | measured |

## RT-9 Handler mode

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-9a | Events arrive in order per connection: Opened, Data…, Closed; exactly one Closed | v1 | `handler_test` | green |
| RT-9b | An HTTP/1.1 keep-alive server built on handler mode (`examples/http_hello`) serves 100,000 requests from 100 clients with 0 errors | v1 | `examples_test` | green |
| RT-9c | `close` sends queued bytes first; `abort` resets at once | v1 | `handler_test` | green |
| RT-9d | `Tick` arrives at least every 100 ms while the worker runs | v1 | `handler_test` | green |

## RT-10 Stats and messages

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-10a | `post(m)` reaches every worker once | v1 | `message_test` | green |
| RT-10b | Stats: accepted, closed by reason, bytes each way, connect failures, retries, buffer waits, sessions per tag; summed across workers they match the test's own counts exactly | v1 | `message_test` | green |
| RT-10c | `SetAddr { target, slot, addr }` sets address `slot` (0 to 7) of `Config.targets[target]` on every worker; a slot past the end appends; an empty address clears the slot and a cleared slot is never picked (not counted as a failure); a target whose slots are all cleared closes new clients; a bad target, slot or address is ignored (a worker never aborts on a message); open connections keep their address. `Message` is 64 bytes (RT-10a holds: a pipe write up to PIPE_BUF is atomic). The address travels as text, at most 47 bytes (the longest valid Addr; the message body has 48), parsed by the worker as at every connect | post-v0.1.0 | `set_addr_test` | green |

## Documentation and polish (v1)

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-11a | README with a working forward example and the HTTP example, both built by CI | v1 | `examples_test`, `readme_test` | green (README example is examples/forward_port.goose, checked by readme_test; examples build) |
| RT-11b | Every public function has a comment saying what it does, who owns what, and whether it can fail | v1 | `comments_test` | green |
| RT-11c | `docs/memory.md`: what allocates and when, measured | v1 | review | green (docs/memory.md) |


## RT-12 The HTTP server example (examples/http_server.goose)

The server the benchmarking guides use, and the pattern a new agent copies. Behaviour is that of `bench/backend.c`.

| id | Behaviour | Ver | Test | Status |
|---|---|---|---|---|
| RT-12a | `GET /`, `GET /N` (N up to 64 MiB, body[i] = i % 251), `HEAD`, 404, 405, 400 and 431 are answered correctly; a worker survives all of them | v1 | `http_server_test` | green |
| RT-12b | Keep-alive, pipelining, a head cut at every position, `Connection: close`, HTTP/1.0, a request body that arrives in pieces, case-insensitive headers | v1 | `http_server_test`, `http_split_test` | green |
| RT-12c | 64 MiB to a slow reader arrives complete and byte-exact with the server's memory flat (send queue backpressure) | v1 | `http_server_test` | green |
| RT-12d | `--root DIR`: every file served byte-exact with its content type; a directory is a 404 | v1 | `http_server_test` | green |
| RT-12e | 100,000 requests from 200 keep-alive clients, every body byte-exact | v1 | `http_server_test` | green |

## RT-13 The policy hook (`w.serve(policy)`, design/07)

| id | Behaviour | Release | Test | Status |
|---|---|---|---|---|
| RT-13a | With `serve(policy)` the engine asks `pick(route, conn, tried, now_ms)` where a forwarded connection goes, connects there, and uses the pick's tag and generation | post-v0.1.0 | `serve_policy_test` | green |
| RT-13b | A failed connect calls `connect_failed`, then `pick` again with the failed slot's bit set in `tried` (bit set before the connect) | post-v0.1.0 | `serve_policy_test` | green |
| RT-13c | `Retry.GiveUp` closes the client with no further pick; `Pick.None` closes it with no byte sent | post-v0.1.0 | `serve_policy_test` | green |
| RT-13d | `connected` and `closed` are called with the pick's tag, `closed` only after `connected`; a policy never sees a connection that was not connected | post-v0.1.0 | `serve_policy_test` | green |
| RT-13e | Without a policy, `serve` behaves as before (built-in rotation); the other test files stay green | post-v0.1.0 | all other tests | green (31 test files; tls_support_test failed once in the full run and passed 3 of 3 alone, see TODO) |
| RT-13f | Retry only before a client byte was consumed holds under a policy (RT-4c on the policy path) | post-v0.1.0 | not yet written | open |
| RT-13g | `Message.Policy { body }` (body at most 48 bytes) reaches every worker's policy once, as `on_message(body, now_ms) -> Effect`; without a policy it is dropped | post-v0.1.0 | `policy_message_test` | green |
| RT-13h | Policy messages are delivered in post order on each worker; a 48-byte body arrives intact | post-v0.1.0 | `policy_message_test` | green |
| RT-13i | `Effect.CloseTagged { tag, gen }` closes that worker's connections of the tag (generation <= gen) and nothing else; nothing is re-broadcast | post-v0.1.0 | `policy_message_test` | green |
| RT-13j | With a policy, a Stats reply is queued behind the Policy messages read before it, so a gather returning proves each worker applied every earlier Policy message (PX-5: post, gather, reply); 100 of 100 in the test, red (40 early replies) with the immediate reply | post-v0.1.0 | `policy_message_test` | green |

| RT-13k | `Pick.To.connect_ms` is the timeout of that connect (0 = `Limits.connect_timeout_ms`); every retry starts its own timer. Red with the engine ignoring the field: 3.01 s instead of 0.3 s and 0.3 s instead of 1.2 s; green with it | post-v0.1.0 | `connect_ms_test` | green |

Per-worker tables for tags are 64 entries: `Config.fenced_tags`, the deadline table and `Stats.tags` (was 16; a deadline for a 17th tag was silently dropped, which left that tag unfenced).
Every policy type must define `on_message` (Goose has no optional hooks).

Row numbers RT-13a to f are Brian's proposal (Bryan's README left them for Charlie to assign).

## RT-14 Outbound handler connections (`w.dial`, post-v0.2.0; spec: skein docs/dial-red-gate.md plus Milli's pipelining check)

| id | Behaviour | Release | Test | Status |
|---|---|---|---|---|
| RT-14a | `dial(addr, tag, connect_ms) -> Conn` returns at once; Opened arrives when the connect finished; Data/Writable/Closed as for an accepted connection; a round trip works | v0.3 | `dial_test` | green |
| RT-14b | `send` on a dialled connection before Opened returns false and queues nothing (Charlie's ruling) | v0.3 | `dial_test` | green |
| RT-14c | A refused connect: no Opened, exactly one Closed with why = ConnectFailed, last | v0.3 | `dial_test` | green |
| RT-14d | `connect_ms` is the dial's own connect timeout (0 = Limits.connect_timeout_ms): a hanging connect fails at that time (0.2 to 0.4 s for 200 ms) | v0.3 | `dial_test` | green |
| RT-14e | The peer closes a dialled connection: one Closed, the handler frees its state | v0.3 | `dial_test` | green |
| RT-14f | A dial never blocks the worker: while a reply is 600 ms away other requests are answered within 50 ms | v0.3 | `dial_test` | green |
| RT-14g | A dialled connection can be tagged and fenced: no byte after the deadline, closed as Fenced | v0.3 | `dial_test` | green |
| RT-14h | Pipelining: 500 small sends back to back are all accepted (same send queue as accepted connections); a stalled peer fills the queue (send false), Writable resumes it, bytes in order (Milli) | v0.3 | `dial_test` | green |
| RT-14i | 200 concurrent dials across 2 workers all complete; no leaked slots afterwards | v0.3 | `dial_test` | green |

## RT-15 Graceful close of handler connections (G-1, send_room; v0.4.0, because the new Event variant PeerEof breaks exhaustive matches; consumer: skein)

| id | Behaviour | Release | Test | Status |
|---|---|---|---|---|
| RT-15a | A connection that called `set_keep_open_on_eof` is NOT closed when the peer finishes sending: the engine stops reading, delivers `PeerEof` once, and the handler can keep sending (send, Writable) and finishes with `shutdown_write` or `close`. A client that sends a request and shuts down its write side still receives the whole response, then EOF | v0.4.0 | `halfclose_test` | green |
| RT-15b | Without the opt-in the old behaviour stays: the peer's EOF closes the connection after the queued bytes are flushed; no PeerEof | v0.4.0 | `halfclose_test` | green |
| RT-15c | `shutdown_write(conn)`: after the queue is out, shut down the write side (the peer reads EOF) and keep reading; when the peer has also finished, the connection closes | v0.4.0 | `halfclose_test` | green |
| RT-15d | `send_room(conn) -> i64`: how many bytes `send` would accept now (the free queue room, 4 x buffer_size at most), 0 when full, shrinking by what was sent, back after Writable | v0.4.0 | `halfclose_test` | green |
| RT-15e | Fencing beats half-close: a kept-open connection whose tag deadline expires while the handler is still sending after PeerEof is closed as Fenced, with 0 bytes after the deadline | v0.4.0 | `halfclose_test` | green |
| RT-15f | A kept-open connection is bounded: the half-close timeout (`Limits.half_close_timeout_ms`) runs from PeerEof; a handler that never finishes is closed with HalfCloseTimeout (red: still open after 6 s) | v0.4.0 | `halfclose_test` | green |
| RT-15g | Ordering: PeerEof is delivered after every Data of the connection; Closed is last, exactly once; `send` after `shutdown_write` returns false | v0.4.0 | `halfclose_test` | green |

| RT-15h | `w.draining() -> bool` is false until a Drain message reaches the worker, then true; an already-open connection can still ask (a handler can answer 503 and close) | v0.4.1 | `halfclose_test` | green |

`close` already means close-after-drain (it closes once the queued bytes are out), so there is no separate `close_after_drain`.

## RT-16 Batching window (post-v0.4.0; Milli's challenge entry; spec from Steve, approved by Charlie)

`Limits.batch_min_events` and `Limits.batch_max_wait_us`, both 0 = off. When a pass finds fewer events than the minimum the worker waits up to the maximum for more, then processes.

| id | Behaviour | Release | Test | Status |
|---|---|---|---|---|
| RT-16a | Off by default (also with only one of the two set): the worker never waits (`Stats.batch_waits` = 0) | v0.5.0 | `batch_test` | green |
| RT-16b | With both set the worker waits: `batch_waits` and `batch_wait_us` count the windows | v0.5.0 | `batch_test` | green |
| RT-16c | The wait never passes a deadline (the earliest of max_wait, the next Tick/sweep, a tag deadline, `_dial_due`, the drain deadline): a 200 ms window does not delay a tag deadline by more than 60 ms (red with the cap removed: the connection closed 199 ms after the deadline) | v0.5.0 | `batch_test` | green |
| RT-16d | A posted message (control, Policy, Drain, Stats) ends the wait at once: a Stats gather with a 200 ms window is as fast as without (red with the message pipe not watched: 89 ms against 0.6 ms) | v0.5.0 | `batch_test` | green |
| RT-16e | Fencing is unaffected: zero bytes after a tag deadline that expires during a window (a guard: deadlines are enforced before events are dispatched, so it also holds without the cap) | v0.5.0 | `batch_test` | green |
| RT-16f | Rows: CPU per request and p50/p95 latency with the window on and off (printed); gate: the p95 grows by at most 20 ms | v0.5.0 | `batch_test` | green |

Measured (batch_test, 8 connections, one 64-byte ping-pong every ~4 ms each, window min=8 / wait=2000 us, this host, idle): CPU per request 71 to 79 us off, 66 to 69 us on (about 7 to 12% less); p50 latency 0.18 ms off, 4.3 ms on, p95 0.25 to 0.30 ms off, 4.5 ms on. The saving is modest at this light load; Milli's measurement (49% to 27% CPU) was at a much higher request rate.

## RT-17 End-of-pass signal (`w.want_pass_end`, `Event.PassEnd`; R5 from skein; v0.6.0 because a new Event variant breaks exhaustive matches)

| id | Behaviour | Release | Test | Status |
|---|---|---|---|---|
| RT-17a | After `w.want_pass_end(true)` the engine delivers `Event.PassEnd {}` exactly once after the last handler event (Opened, Data, Writable, PeerEof, Closed) of every pass that delivered at least one | v0.6.0 | `passend_test` | green |
| RT-17b | No PassEnd on a pass where nothing happened (idle passes, Ticks) | v0.6.0 | `passend_test` | green (red when the guard is removed: shown) |
| RT-17c | One PassEnd after a batching-window wait ends, covering the events it gathered | v0.6.0 | `passend_test` | green |
| RT-17d | Off by default: never a PassEnd, and no per-pass work | v0.6.0 | `passend_test` | green (red when the guard is removed: shown) |
| RT-17e | A send during PassEnd takes the normal send path, deadline check included: before the deadline it goes out; after the tag deadline passed it sends 0 bytes and returns false | v0.6.0 | `passend_test` | green |
| RT-17f | A pass that delivered only a posted Message (control, Policy, Stats) and no handler event gets no PassEnd: Messages, Ticks and policy hooks are NOT handler events | v0.6.0 | `passend_test` | green (red when the guard is removed: shown) |

## RT-18 to RT-20 Findings of the review of 2026-11-14 (verdicts for every claim: [docs/review-2026-11-14.md](../docs/review-2026-11-14.md); all in v0.6.0)

| id | Behaviour | Release | Test | Status |
|---|---|---|---|---|
| RT-18a | The engine's ready list (connections with bytes left to move) stays short under sustained load: one connection that hits the per-wakeup budget on every pass leaves it at most 64 entries (`Stats.ready_len`) | v0.6.0 | `queues_test` | green |
| RT-18b | With a saturated buffer pool (2 buffers, 6 streams) the waiting-reads list and the ready list stay at most 64 entries (`Stats.waiting_len`). A guard: it was NOT red before the fix (the load I can generate empties the list often, so it never grew past 64); the compaction is the same code as RT-18a's | v0.6.0 | `queues_test` | green (guard) |
| RT-19a | Closing a connection that waits for a buffer does not spend the buffers it frees on itself: the reader waiting behind it is woken | v0.6.0 | `handler_edges_test` | green |
| RT-19b | A `send` refused for lack of pool buffers (empty output queue) is followed by `Writable` when buffers return; a send larger than the 4-buffer queue is refused and promises none | v0.6.0 | `handler_edges_test` | green |
| RT-19c | Bytes the socket takes while the output queue drains count as activity: a slow but steady reader is not closed as idle | v0.6.0 | `handler_edges_test` | green |
| RT-19d | `forward` is refused after `shutdown_write` and after the peer's EOF | v0.6.0 | `handler_edges_test` | green |
| RT-19e | A dial that is still connecting ends by its own connect timeout (ConnectFailed), never by the idle timeout | v0.6.0 | `handler_edges_test` | green |
| RT-19f | A refused connect with no other address left (the rest cleared by SetAddr) is not counted as a retry | v0.6.0 | `handler_edges_test` | green |
| RT-20a | Bytes a backend sent before it reset the connection still reach the client (the proxy was frozen so data and RST arrived together; the 8-byte payload passes before the fix by luck of ordering, the 100 kB one does not); the client side keeps closing at once | v0.6.0 | `server_rst_test` | green |
| RT-20b | The connection is closed afterwards (no leak) | v0.6.0 | `server_rst_test` | green |


## RT-21 A server that ends before its first byte is retried (docs/early-close-retry.md, gate `gates/early_close_peek`)

| id | Behaviour | Release | Test | Status |
|---|---|---|---|---|
| RT-21a | On an `inspect: Sni` listener, a server that closes or resets before sending a byte gets its session moved to the next address with the client's whole hello from byte 0; the client sees only the second server | next | `early_close_test` | red |
| RT-21b | After the server's first byte nothing is retried: the client sees that byte and the close | next | `early_close_test` | green (guards) |
| RT-21c | A listener without `inspect: Sni` never replays the client's bytes: the session closes | next | `early_close_test` | green (guards) |
| RT-21d | The retry is counted in `retries`; the policy's `connect_failed` hook is asked, and its `closed` hook runs first when it had been told `connected` | next | `early_close_test` | red |
