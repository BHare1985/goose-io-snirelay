# 05 — Requirements

One behaviour per row, with a pass/fail check. Priorities: **v1** (first release), **v2**, **later**.
Status: `design` (not started), `red` (test written and approved, failing), `green` (passes), `done`
(green on CI and documented). Every test file lists the row ids it proves in its first comment;
`tests/coverage.sh` (Brian) prints rows without a test.

Columns: id · behaviour · priority · test · status.

## RT-1 Listeners and workers

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-1a | A worker listens on every configured IPv4 and IPv6 address and accepts connections | v1 | `listen_test` | design |
| RT-1b | N workers on one port share new connections: with 4 workers and 400 connections, each worker gets at least 50 | v1 | `listen_test` | design |
| RT-1c | `check(cfg)` rejects: duplicate listener ids, a route to an unknown listener, `Sni` rows on a listener without `inspect: Sni`, empty targets; each with a message naming the field | v1 | `config_test` | red (awaiting approval) |
| RT-1d | Starting while another process holds the port fails with an error naming the address, instead of silently sharing it | v1 | `listen_test` | design |
| RT-1e | `worker()` and `serve()` never call `abort` or `exit` for anything a peer or the OS does (resets, EMFILE, ENOBUFS); they count and continue | v1 | `chaos_test` | design |

## RT-2 Connections

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-2a | 10,000 concurrent idle connections per worker are held | v1 | `scale_test` | design |
| RT-2b | An event or handle carrying an old generation never touches the connection now in that slot (1,000,000 open/close cycles with slot reuse, random resets) | v1 | `generation_test` | design |
| RT-2c | Slot indices from the kernel are range-checked; an out-of-range index is counted and dropped | v1 | `generation_test` | design |

## RT-3 Routing

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-3a | `Match.Any` routes every connection on a listener (port routing) | v1 | `route_test` | green |
| RT-3b | SNI routing: exact (case-insensitive, trailing dot ignored), then longest suffix, then `NoSni`, then `Any`; first in config order within a kind | v1 | `route_test` | green |
| RT-3c | The backend of a forwarded SNI connection receives the client's bytes from byte 0, unchanged (ClientHello not consumed) | v1 | `forward_test` | design |
| RT-3d | A client that sends nothing within `inspect_timeout_ms` is closed | v1 | `timeout_test` | design |
| RT-3e | The parser passes vectors S1–S12 (doc 04) | v1 | `sni_test` | green |
| RT-3f | A ClientHello over 16 KB is closed, not buffered | v1 | `sni_test`, `route_test` | green: sni_test half; route_test green |
| RT-3g | A non-TLS client on an `inspect: Sni` listener is routed after its first byte (no wait) | v1 | `route_test` | green |

## RT-4 Forwarding

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-4a | Bytes are forwarded both ways exactly (64 clients × 10 MB random, checksums match) | v1 | `forward_test` | design |
| RT-4b | Half-close: client shuts down writing → backend sees EOF, and the backend's remaining reply still reaches the client; and the reverse | v1 | `forward_test` | design |
| RT-4c | A refused or timed-out connect is retried on the next target address **before any client byte is consumed**, and the client sees a normal reply | v1 | `retry_test` | design |
| RT-4d | When every target fails, the client connection is closed and `connect_failed` counted | v1 | `retry_test` | design |
| RT-4e | `forward(c, target)` from handler mode works only before any byte was consumed; afterwards it is refused | v1 | `handler_test` | design |
| RT-4f | Throughput and p99 latency within 10% of the C proxy's copy engine on the same host (`bench/`) | v2 | `bench/compare.sh` | design |
| RT-4g | splice forwarding with a pipe pool; same tests as RT-4a/b pass | v2 | `forward_test --splice` | design |

## RT-5 Memory and backpressure

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-5a | An idle forwarded connection holds no pool buffer | v1 | `memory_test` | design |
| RT-5b | Memory per idle connection ≤ 512 bytes of worker memory beyond kernel socket buffers (RSS growth over 10,000 idle) | v1 | `memory_test` | design |
| RT-5c | A destination that stops reading stops the engine reading from the source; RSS stays flat while 1 GB is offered | v1 | `backpressure_test` | design |
| RT-5d | With the pool exhausted, the worker keeps serving other connections as buffers return; no abort, waits counted | v1 | `backpressure_test` | design |
| RT-5e | Handler `send` returns false at the per-connection cap and `Writable` follows once drained; memory stays bounded | v1 | `handler_test` | design |
| RT-5f | One busy connection can't starve others: with one 1 GB stream and 100 small request/reply clients, small p99 < 10 ms | v1 | `fairness_test` | design |
| RT-5g | No allocation on the established forwarding path (Goose `--stats` or data-stack high-water flat across 10 GB forwarded) | v1 | `memory_test` | design |

## RT-6 Tags, fences and deadlines

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-6a | Past a tag's deadline, **zero** bytes are forwarded to or from that tag's servers, also after the process was frozen (SIGSTOP) across the deadline and resumed | v1 | `deadline_test` (frozen case) | design |
| RT-6b | `CloseTagged(tag, gen)` closes every matching connection within one loop pass, before handling further events | v1 | `deadline_test` | design |
| RT-6c | Deadlines are on `CLOCK_BOOTTIME` | v1 | `deadline_test` (unit, clock source) | design |
| RT-6d | A deadline message with an earlier deadline than one already set never extends it; a duplicate is harmless | v1 | `deadline_test` | design |
| RT-6e | A tag can start fenced (no deadline yet = no connections) | v1 | `deadline_test` | design |

## RT-7 Timeouts

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-7a | Connect timeout per attempt | v1 | `timeout_test` | design |
| RT-7b | Idle timeout closes a connection with no bytes either way | v1 | `timeout_test` | design |
| RT-7c | Half-close timeout closes a connection left half-open | v1 | `timeout_test` | design |
| RT-7d | Each timeout fires within its limit + 300 ms | v1 | `timeout_test` | design |

## RT-8 Lifecycle

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-8a | `Drain`: listeners close at once; a new process on the same port gets all new connections | v1 | `drain_test` | design |
| RT-8b | `Drain` returns when the last connection closes, or closes the rest at the deadline | v1 | `drain_test` | design |
| RT-8c | SIGTERM and SIGINT start a drain (via `wait_for_signal_then_drain`) | v1 | `drain_test` | design |

## RT-9 Handler mode

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-9a | Events arrive in order per connection: Opened, Data…, Closed; exactly one Closed | v1 | `handler_test` | design |
| RT-9b | An HTTP/1.1 keep-alive server built on handler mode (`examples/http_hello`) serves 100,000 requests from 100 clients with 0 errors | v1 | `examples_test` | design |
| RT-9c | `close` sends queued bytes first; `abort` resets at once | v1 | `handler_test` | design |
| RT-9d | `Tick` arrives at least every 100 ms while the worker runs | v1 | `handler_test` | design |

## RT-10 Stats and messages

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-10a | `post(m)` reaches every worker once | v1 | `message_test` | design |
| RT-10b | Stats: accepted, closed by reason, bytes each way, connect failures, retries, buffer waits, sessions per tag; summed across workers they match the test's own counts exactly | v1 | `message_test` | design |

## Documentation and polish (v1)

| id | Behaviour | Pri | Test | Status |
|---|---|---|---|---|
| RT-11a | README with a working forward example and the HTTP example, both built by CI | v1 | `examples_test` | design |
| RT-11b | Every public function has a comment saying what it does, who owns what, and whether it can fail | v1 | review | design |
| RT-11c | `docs/memory.md`: what allocates and when, measured | v1 | review | design |
