# 01 — Scope and layers

## The three layers

```
┌───────────────────────────────────────────────────────────────────────────┐
│ Programs                                                                  │
│   gatekeeper proxy: YAML, CLI, control socket, lease protocol, Gatus hook │
│   the user's HTTP server (another project), examples/                     │
└──────────────┬──────────────────────────────────┬─────────────────────────┘
               │ calls                            │ calls
┌──────────────▼───────────────┐   ┌──────────────▼─────────────────────────┐
│ tcpproxy (policy, as data)   │──►│ tcprouter (engine)                     │
│  backend groups and servers  │   │  listeners, workers, event loop        │
│  pick, retry or give up      │   │  connection slots with generations     │
│  up / down / degraded        │   │  buffers, backpressure, timeouts       │
│  "serve until" deadlines     │   │  routing by port or SNI                │
│  passive failure counting    │   │  forwarding (copy; splice later)       │
│  (no I/O of its own)         │   │  handler events for your own protocol  │
└──────────────────────────────┘   │  drain, stats, messages to workers     │
                                   └──────────────┬─────────────────────────┘
                                                  │ extern fn
                                   ┌──────────────▼─────────────────────────┐
                                   │ libc: socket, accept4, epoll, recv,    │
                                   │ send, splice, clock_gettime …          │
                                   └────────────────────────────────────────┘
```

- **tcprouter owns forwarding.** Moving bytes between two sockets needs the loop's buffers, its
  backpressure and its timeouts, so it lives with them (Steve, 2026-11-04). A program that only
  needs "forward this port to that address" uses tcprouter alone.
- **tcpproxy has no I/O.** The engine asks it questions while handling a connection ("which
  server for this connection?", "the connect failed, retry or give up?", "closed") and it answers
  from its own tables. It is linked in at compile time through Goose's generics, not callbacks
  (doc 07).
- **Programs own configuration.** The Gatekeeper proxy reads YAML and makes the same calls an
  example program makes by hand.

## Who uses it first

1. **The user's HTTP server for another project** (handler mode, doc 02 example B). This is why
   tcprouter comes first.
2. **The Gatekeeper proxy** (forward mode plus tcpproxy). The C proxy keeps serving Gatekeeper
   until the Goose version passes the same acceptance suite (doc 06).

## First release of tcprouter

| In | Notes |
|---|---|
| Linux, 64-bit: x86-64 and arm64 | No other OS in v1. epoll, clock and signalfd go through a small C header adapter, because `epoll_event` is packed only on x86-64 (Brian) |
| TCP listeners, IPv4 and IPv6, one per worker with `SO_REUSEPORT` | Port-in-use check, RT-1d |
| One event loop per worker thread, epoll, share-nothing | io_uring later behind the same internals |
| Routing by listener, by exact or wildcard SNI, and a default | Parser in doc 04 |
| Forward mode: connect to an address, copy both ways, half-close, backpressure | splice in v2 |
| Handler mode: events to your code, send, close, pause reading | Builds HTTP servers |
| Connect timeout and retry before any client byte is consumed | Policy decides; a trivial one is built in |
| Idle and half-close timeouts | Coarse sweep, no timer per connection |
| Graceful drain with a deadline | |
| "Close every connection tagged X" | The primitive behind lease fences |
| Stats per worker, gathered by message | |
| Messages to workers (config changes, drain, fence, stats) | Doc 03 §7 |

| Not in tcprouter, ever | Where it goes |
|---|---|
| YAML, CLI flags, environment | The program |
| TLS termination, certificates | A TLS library (gslib's TLS is sans-I/O and fits handler mode) |
| HTTP parsing | An HTTP library or the program |
| Backend health checks | Gatus decides health for Gatekeeper; tcpproxy only takes up/down/degraded |
| Leases, epochs, the arbiter, Gatus | The Gatekeeper proxy; the library only offers deadlines and "close tagged" |
| DNS resolution | The program resolves and sends addresses |

| Later (v2+) | Why later |
|---|---|
| io_uring engine | epoll first to prove the model (Steve); same internals |
| splice with a pipe pool | Copy first; splice is an optimisation with tricky ownership |
| Zero-copy tuning, TFO, smart ACK tricks | Measured C optimisations, not needed for correctness |
| Unix-socket and UDP listeners | No user yet |
| Hot listener changes without restart | Needs a design for moving listeners between workers |
