# tcprouter design

Status: draft 1, 2026-11-04, Charlie (Gatekeeper's architect) for Brian. Owner of the code: Brian.
Reviewer of tests and API use: Charlie. C questions: Steve (owner of the C proxy, `~/dev/c_proxy`).

`tcprouter` is a Goose library for writing fast TCP servers on Linux: listeners, one event loop per
core, connections, buffers, backpressure, timeouts, graceful drain, and routing of each new
connection by its port or its TLS server name (SNI, read without decrypting). A connection is
either **forwarded** to another address by the library, byte for byte, or **handed to your code**
as events (opened, data, writable, closed), so you can build an HTTP server or a protocol of your
own on it.

`tcpproxy` is a second library on top: which backend to pick, retry, health state set from
outside, and "serve until" deadlines. The Gatekeeper proxy is a program that reads YAML and calls
both. Neither library knows about Gatekeeper.

## How to read this

| Doc | What it settles | Read when |
|---|---|---|
| [01-scope.md](01-scope.md) | What the libraries are and are not; the layers; first-release list | First |
| [02-api.md](02-api.md) | The public API as Goose code, with the user's HTTP example rewritten | First |
| [03-engine.md](03-engine.md) | Workers, connection slots, buffers, backpressure, timeouts, drain, messages | Before writing the engine |
| [04-sni.md](04-sni.md) | The ClientHello parser contract | Before the parser (it is the first code) |
| [05-requirements.md](05-requirements.md) | Every behaviour as one row with a number and the test that proves it | Always; tests link here |
| [06-tests-and-gates.md](06-tests-and-gates.md) | How red gates work, test layout, what Charlie approves | Before the first test |
| [07-tcpproxy.md](07-tcpproxy.md) | The second library: policy as data, the engine calling it | After tcprouter M3 |
| [08-c-map.md](08-c-map.md) | Where each part of the C proxy goes, and what is left behind | When porting a piece |
| [09-open-questions.md](09-open-questions.md) | Goose facts this design assumes but nobody has verified | Before relying on one |

## Milestones

| M | Delivers | Rows |
|---|---|---|
| M0 | Open questions O-1 … O-6 answered in goose-kb; package skeleton builds; test runner | — |
| M1 | ClientHello parser and SNI matching, pure | RT-3e, RT-3f |
| M2 | One worker: listen, forward one port to one address, half-close, backpressure | RT-1a, RT-4a/b, RT-5a–d |
| M3 | Many workers, routing by port and SNI, retry, handler mode, `http_hello` example | RT-1b–e, RT-2, RT-3, RT-4c–e, RT-9 |
| M4 | Timeouts, drain, tags, deadlines, messages, stats | RT-6, RT-7, RT-8, RT-10 |
| M5 | Polish: docs, examples in CI, memory doc, scale tests | RT-2a, RT-5b/f/g, RT-11 |
| M6 | Benchmark against the C proxy's epoll engine with Steve's method (`~/dev/c_proxy`): goal less memory and faster | RT-4f, RT-5b |
| — | tcpproxy (doc 07), then the Goose proxy passing `verify_backends.py` | PX-…, doc 06 |

The user's HTTP server for another project can start on M3.

## Ground rules

1. **The C proxy is a reference for behaviour, not a spec to port line by line.** It is the
   trusted, working code until the Goose libraries pass the same tests (doc 06, "Definition of
   done").
2. **Readability first, then memory, then speed.** This is public code. A cleverer layout has to
   earn its place with a measurement in `bench/`.
3. **Goose facts carry a tag**, as in `goose-kb/`: **[V]** verified by running code here, **[D]**
   from the Goose docs, **[R]** a recommendation, **[verify]** assumed by this design and not yet
   checked. Anything **[verify]** is listed in doc 09; check it before building on it.
4. **Requirements are numbered** (`RT-…` for tcprouter, `PX-…` for tcpproxy) and every test names
   the rows it proves. A row without a test is not done.
5. **Library code never reads config files, environment variables or flags.** Programs do, and
   turn them into library calls.
