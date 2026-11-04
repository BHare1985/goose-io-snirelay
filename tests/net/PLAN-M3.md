# M3 test plan: many workers, routing, retry, handler mode

Status: proposal for Charlie, before any M3 network test is written. Rows: RT-1b, RT-1d, RT-1e, RT-2b, RT-2c, RT-3c,
RT-3d, RT-3f/3g (engine halves), RT-4c, RT-4d, RT-4e, RT-5e, RT-9a, RT-9b, RT-9c, RT-9d. (RT-2a, 10,000 idle per worker, is
in M5's list; RT-5b already shows 10,000 idle connections on one worker, so it will likely be quick.)

Same method as M2: the system under test is a Goose program written like a user's, the checker is an independent
Python driver. Two system-under-test programs: `harness/forward_server.goose` (exists; gains `--connect-timeout-ms`, `--inspect`,
`--sni NAME=TARGET`, `--no-route-default`) and a new `harness/handler_server.goose` for handler mode, whose behaviour is chosen
by the route's tag, so one binary serves every handler test: tag 1 echo, tag 2 close-after-N-bytes, tag 3 send N bytes
as fast as `send` accepts them (honouring `false` and `Writable`), tag 4 `forward` to a target on Opened, tag 5 consume
one byte and then `forward` (must be refused), tag 6 `reset` at once, tag 7 the HTTP/1.1 server of examples/http_hello.

## Group A: workers, ports, chaos, generations (the engine's robustness)

**listen_test (existing, extended) RT-1b, RT-1d.**
- RT-1b: 4 workers, one port, echo backend, 400 connections from 400 sequential clients: every worker's own STAT line
  shows `accepted >= 50` and the sum is 400. (If the kernel's spread on this host is worse than that, the test prints each
  worker's count and fails; then we look at whether SO_REUSEPORT hashing or our accept batching is at fault.)
- RT-1d: a second process holding the port with a plain `bind`+`listen` (no SO_REUSEPORT): `start()` fails in every worker and `forward_server`
  prints the library's error on stderr; the driver checks that the message names the address and says "Address already in use". A listener that held it with SO_REUSEPORT is also refused (spawn probes with a plain
  socket). Afterwards the other process still gets all its connections (we did not steal any).

**chaos_test (new) RT-1e.** The worker must count and continue, never abort or exit:
- fd exhaustion: server started with `RLIMIT_NOFILE` 64; 200 clients connect (EMFILE on accept, or on the outgoing connect).
  Pass: process alive, STAT keeps ticking, once the clients close a new client is served; stderr has no "runtime error";
  the listener does not spin (CPU of the server over 3 s of EMFILE is below 50%, read from /proc).
- peer chaos: 2,000 connections that each do one of: connect+RST, send garbage then FIN, half-close and vanish, send 1 byte
  every 100 ms then reset, connect to a backend that accepts and immediately RSTs. Pass: alive, and `open` returns to 0 within 5 s.
- (ENOBUFS and ENOMEM cannot be provoked from outside; they take the same path as EMFILE and are covered by reading the code.)

**generation_test (new) RT-2b, RT-2c.**
- RT-2b over real sockets: 1,000,000 connect/close cycles with random RSTs, driven by 8 processes against a fast C echo
  backend (`harness/echo_server.c`, 60 lines of epoll, built by run_tests.sh; a Python backend cannot accept 100k/s).
  Pass: `accepted == 1,000,000`, `open == 0` at the end, `stale_events` is whatever it is but no connection ever got another
  one's bytes: every client sends its own 16-byte tag first and checks that what it reads back is that tag (a stale
  event touching a reused slot would show as a wrong tag or a hang).
- RT-2c as a Goose unit test (`tests/unit/generation_test.goose`, uses the internal `tr_dispatch`): a started worker is fed
  events whose slot is past the table, whose generation is old, and whose kind is unknown: `bad_events` and `stale_events` count
  them, nothing else changes, nothing aborts.

## Group B: inspection, retry (forward mode)

**sni_forward_test (new) RT-3c, RT-3d, RT-3f, RT-3g.** Listener with `inspect: Sni`, routes by name to two echo-with-tag backends.
- RT-3c: for each real ClientHello in tests/data (openssl, curl, python, node, wget captures), send it, and the backend that matches
  receives exactly those bytes, from byte 0, followed by whatever the client sends next; compared byte for byte with the file.
  Also a client that dribbles the hello one byte every 10 ms is routed when complete and the backend sees every byte.
- RT-3d: a client that sends nothing is closed within `inspect_timeout_ms + 300 ms` (config 1000 ms in the test); `closed[InspectTimeout]` is 1.
- RT-3f engine half: a hello declaring more than 16 KB is closed at once, the worker holds no more than 16 KB + 5 for it (RSS check).
- RT-3g: "GET / HTTP/1.1" on the SNI listener is routed after its first byte (a NoSni route), not after the inspect timeout.
- Unknown name -> the Any route; no route -> closed. Both asserted.

**retry_test (new) RT-4c, RT-4d.** Target list [refused port, refused port, good echo]; the three orderings.
- RT-4c: the client gets a normal echo reply, and the bytes the client sent before the connect finished arrive at the good
  backend complete and in order (the client sends 100 KB immediately after connecting, before the retries are done). `retries`
  counts the failed attempts, `connect_failures` too.
- RT-4d: all targets refused: the client is closed (EOF) within 1 s, `closed[ConnectFailed]` is 1, `connect_failures == len(targets)`,
  and the worker is fine.
- The timed-out half of RT-4c needs the connect timeout (RT-7a, M4): a saturated-backlog listener (listen(0), one pending
  connection filling the queue) never completes a SYN, which is deterministic. I propose RT-4c is `done` only after that case
  runs in M4; M3 covers refused.

## Group C: handler mode

**handler_test (new) RT-4e, RT-5e, RT-9a, RT-9c, RT-9d.** `handler_server` with the tags above.
- RT-9a: a scripted client opens/sends/closes 1,000 connections; the server logs one line per event (`E open c=…`, `E data c=… n=…`,
  `E closed c=… why=…`); the driver checks per connection: Opened first, Data in order with the exact bytes, exactly one Closed, nothing
  after it.
- RT-9c: tag 2 queues 1 MB then `close`: the client receives all 1 MB and then EOF (close sends queued bytes first). Tag 6 `reset`: the
  client sees ECONNRESET at once.
- RT-5e: tag 3 sends 64 MB to a client that does not read: `send` returns false at the cap (`buffer_size x 4` = 64 KB), the program logs
  the count of falses, proxy RSS grows by under 1 MB, then the client reads: `Writable` arrives and all 64 MB arrives intact.
- RT-9d: a Tick line is logged at least every 100 ms (gaps over 250 ms fail) for 5 s, with 50 busy connections.
- RT-4e: tag 4 `forward`s on Opened: the backend gets the client's bytes and the reply returns; tag 5 reads a byte first and then
  `forward` returns false and the connection keeps working as a handler connection.

**examples_test (new) RT-9b, RT-11a (part).** Builds the three examples (CI proof that they compile) and runs `http_hello`: 100 clients
(threads) keep-alive, 1,000 requests each = 100,000 requests, 0 errors, each response checked byte for byte; requests
split across TCP writes (head cut at every position for 1,000 of them) and pipelined pairs are answered correctly. Throughput printed.

## What changes in the library API (nothing in the shape)

Handler functions (`send`, `close`, `reset`, `set_user`, `forward`, `pause_reading`) become real; `Event` stays as in doc 02.
`Limits` gains nothing. `forward_server` and `handler_server` take their knobs from flags.

## Questions for Charlie

1. Is a small C echo backend (`harness/echo_server.c`, compiled by run_tests.sh with the same C compiler) acceptable for RT-2b? It is
   independent of our code and fast enough; Python cannot do 100k accepts per second.
2. RT-4c done only when its timed-out half has run in M4: agreed?
3. RT-2c through the internal `tr_dispatch` in a unit test: acceptable, since the kernel will not send an out-of-range slot?
4. RT-1b's "at least 50 of 400 per worker" depends on the kernel's SO_REUSEPORT hash over client source ports. If this host spreads worse, do we
   change the threshold or the engine (for example by accepting in a round robin of workers)? I propose we look at the measured spread first.
