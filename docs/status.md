# tcprouter v0.1.0: what is verified, what is measured, what is open

Every behaviour is a numbered row in [design/05-requirements.md](../design/05-requirements.md); each row names the test that proves it
and its status. `tests/run_tests.sh` runs every test; `tests/coverage.sh` lists rows no test proves yet. Compiler: `goose 751794c`.
Host for all measurements: AMD Ryzen 5 3550H (4 cores / 8 threads), Linux.

## Verified (a test fails if it breaks)

* Forwarding: both directions exact, half-close, backpressure, retry on the next address before a client byte is consumed, SNI routing without
  decrypting, no-SNI and unknown-name rules (RT-3, RT-4, RT-5).
* Handler mode: events in order, exactly one Closed, `send` all-or-nothing with `Writable`, `forward` only before the first byte (RT-9).
* **Fencing** (a tagged connection is sent no byte after its tag's deadline): forward mode (RT-6a) and handler mode (RT-6a-H), also when the
  worker is held up inside your block or the process is frozen. RT-6a-H: 100 of 100 runs alone and 100 of 100 under load. One residual
  window remains by construction, a pause between the last deadline check and the `send()` syscall; the lease margin must cover it
  ([design/06](../design/06-tests-and-gates.md), "The residual window of a fence").
* Drain, messages, stats (RT-8, RT-10); fairness: small requests keep a p99 of 3.3 ms next to a 1 GB stream (baseline 2.7 ms, limit 10 ms) (RT-5f).
* Scale: 10,000 idle connections on one worker, 200 of them used, 169 bytes each (RT-2a). Memory flat over 21.5 GB forwarded (RT-5g, [memory.md](memory.md)).
* `examples/http_server` (RT-12a to RT-12e): GET and HEAD, bodies of any size, files, pipelining, 400/404/405/431, backpressure, concurrent clients.
  The test found a real bug in it (pipelined requests were answered from a shifted buffer); fixed.
* The README example is the real `examples/forward_port.goose`, it builds, and the README's links exist (RT-11a). Every public function has a comment (RT-11b).

## Measured (not a pass/fail test)

[bench/RESULTS.md](../bench/RESULTS.md) has the method and the history. Against the C proxy's copy engine on the same host:
throughput 99% to 103% in every row except new connection per request (about 91%); idle RSS 3,024 kB against 2,620 kB.
HTTP server against the C backend: see "examples/http_server" in RESULTS.md.

## Not done, and why

* **HTTPS termination: not available in v0.1.0.** What works is SNI passthrough: the router reads the server name from the ClientHello and forwards
  the encrypted bytes. Terminating TLS needs a TLS engine; a spike with BearSSL (MIT licence, TLS 1.2 only) was started and not built, because
  that needs C code from outside this repository. Nothing about it is committed. If it is built later it will be an optional package with its
  own `.build`, the core stays free of a TLS library, and the guide will say TLS 1.2 only.
* **Policy hook and the Gatekeeper proxy (`tcpproxy`)**: backup tiers, first-up, passive failure skip, the control protocol. After this release
  ([design/07](../design/07-tcpproxy.md), [docs/gatekeeper-next-step.md](gatekeeper-next-step.md)).
* splice forwarding (RT-4g, v2) and a `bench/compare.sh` harness (RT-4f, v2; the numbers above come from `bench/run_m6.sh`).
* Linux only. One small C file (`src/c_sys.c`) is part of the package.

## Open and unexplained

* **RT-8c** (SIGTERM or SIGINT should close the listener at once): failed about once in 25 runs when run in a loop, before the performance work as well.
  **Unexplained.** The row is green in a normal run; the cause of the intermittent failure has not been found.
* Idle memory is 404 kB over the C proxy (3,024 against 2,620 kB), a known trade for readability (see RESULTS.md).
* New connection per request is about 91% of the C proxy (one extra `recv` per connection).
