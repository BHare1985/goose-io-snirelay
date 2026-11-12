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
| RT-8f | KNOWN KERNEL BEHAVIOUR, measured, not gating: during a drain a connect that arrives in the instant a worker's SO_REUSEPORT listener closes can be dropped and retried by the client after 1 s. RT-8a and RT-8c assert the listener is gone (no listener for the port, asked of the kernel with `ss`; reading /proc/net/tcp measured the reader, 64 ms per read on a busy host) within 0.3 s; `drain_stall_test` reports how often the first connect stalls (3 of 120 once, then 0 of 600) | post-v0.1.0 | `drain_stall_test` | measured |

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
