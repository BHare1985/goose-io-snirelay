# M2 test plan: one worker, listen, forward, half-close, backpressure

Status: proposal for Charlie, before any M2 test is written. Rows: RT-1a, RT-4a, RT-4b, RT-5a, RT-5c, RT-5d
(RT-5b is in both the M2 and the M5 lists of design/README.md; see question 3).

## How a network test is built

Two programs per test group, as in goose-kb's t02:

1. **`tests/net/harness/forward_server.goose`**: the system under test, written the way a user would write
   `examples/forward_port.goose`, except that its config comes from the command line (a program may read
   flags; the library may not). `forward_server --listen 127.0.0.1:P [--listen [::1]:P2] --to 127.0.0.1:B
   [--workers 1] [--buffers N] [--buffer-size N]`. It prints `READY` after `start()`, and on a `Tick` prints
   `STAT accepted=… open=… buffers_in_use=… buffer_waits=… bytes_in=… bytes_out=…` once a second, which
   the driver parses. It is built with `--debug`, so a library bug aborts loudly.
2. **`tests/net/<name>_test.py`**: the driver and checker (Python 3 standard library only). It picks free
   ports (binds port 0, closes, re-checks), starts the backend it needs from `harness/backends.py`
   (echo, sink, slow reader that never reads, closes-after-N-bytes), starts `forward_server`, runs the clients,
   compares checksums and counters, kills everything, and prints `PASS`/`FAIL` lines. The first comment
   lists the rows: `# Proves: RT-4a RT-4b`.

`tests/run_tests.sh` builds `forward_server` once and runs every `tests/net/*_test.py` after the unit tests.
No network test runs while another is running (fixed port blocks per test file, checked free first), and none
runs while a benchmark or the Gatekeeper testbed is using the host (checked via a lock file in `/tmp`).

## Observability the tests need: one public addition

`tcprouter::stats(w: Worker&) -> Stats`, a flat snapshot of the worker's counters: `accepted`, `open`,
`closed_by_reason[10]`, `bytes_in`, `bytes_out`, `buffers_in_use`, `buffers_total`, `buffer_waits`, `connect_failures`,
`retries`. It is what RT-10b needs later anyway, and without it RT-5a and RT-5d cannot be observed from outside.
It is read on the worker's own thread (from a `Tick` event), so it needs no locking. Outside the tests the
real use is the stats message (M4).

## The tests

All sizes are the ones in doc 05. "Backend" = the Python server the proxy forwards to.

**listen_test (RT-1a).** 1 worker, listeners on `127.0.0.1:P1` and `[::1]:P2` (skipped with a printed notice, not a
pass, if the host has no IPv6 loopback), both forwarding to an echo backend.
- 1 client per listener sends 100 bytes, reads 100 bytes back, equal. 200 sequential connections per listener
  all succeed. `STAT accepted` equals 400 at the end.
- A connection to a port nobody configured is refused (proves we did not bind extra sockets).
- (RT-1b/1d, the multi-worker share and the port-in-use error, are M3.)

**forward_test (RT-4a, RT-4b).** 1 worker, echo backend and sink backend.
- RT-4a: 64 concurrent clients, each sends 10 MB of its own random bytes (own seed) and half-closes; the echo backend
  returns them; each client's SHA-256 of what it received equals what it sent. Then the same against a sink that
  reports the SHA-256 of what it got and a source that sends 10 MB back, to test each direction separately. Pass:
  64/64 equal in both directions, `STAT bytes_in == bytes_out == 64 * 10 MB` (twice that for echo), no `FAIL` and no
  runtime error in the server's stderr.
- RT-4b, client half-close: client sends 1 MB, `shutdown(SHUT_WR)`, then reads. Backend sees EOF only after the
  1 MB, replies 2 MB, closes. Client receives all 2 MB, then EOF. Repeat with the reply delayed 500 ms (the
  proxy must not close the client side early).
- RT-4b, backend half-close, the reverse: the backend sends 1 MB and shuts down its write side but keeps reading;
  the client sends 2 MB afterwards and the backend receives all of it, then closes. Client receives the 1 MB and EOF.
- RT-4b, both close at once, and a reset (RST) on one side: the other side is closed within 1 s; the worker stays up
  (a new connection afterwards still works).

**memory_test (RT-5a; RT-5b see question 3).** 1 worker, backend echo.
- RT-5a: open 1,000 connections, send nothing, wait 2 s: `STAT open == 1000` and `buffers_in_use == 0`. Send 1 byte on
  every 10th and read it back: afterwards `buffers_in_use == 0` again (a buffer is borrowed only while bytes are in
  flight). Close all: `open == 0`.
- RT-5b (if here): RSS (from `/proc/<pid>/status`) after 10,000 idle connections minus RSS with 0, divided by 10,000,
  is at most 512 bytes. Needs `ulimit -n` 20,000+ in the driver; the test raises the soft limit or prints SKIP with the
  reason (never a silent pass).

**backpressure_test (RT-5c, RT-5d).**
- RT-5c: the backend accepts and never reads. One client sends 1 GB as fast as it can, using non-blocking sends and a
  10 s budget. Pass: the client's sends stall (it cannot complete 1 GB: bytes accepted by the kernel stay below
  64 MB, the sum of the socket buffers on both hops with margin), the worker's RSS grows by at most 8 MB over its
  baseline, `STAT buffers_in_use <= 2` (one per direction), and `STAT` shows the worker still ticking (not wedged).
  Then the backend starts reading: the rest of the offered data arrives, in order, with the right checksum.
- RT-5d: `--buffers 4`, 100 concurrent echo clients, 1 MB each. Pass: all 100 finish with correct checksums, the
  worker did not abort, `buffer_waits > 0` (the pool really ran dry), and `buffers_in_use` never exceeds 4 in any `STAT`
  line. A client that connects while the pool is empty is served after a buffer returns.

## Red state

Today `serve()` is a stub: it never listens, so `forward_server` prints `READY` after a no-op `start()` and every
client gets "connection refused". The tests fail at their first connect, for the right reason.

## Questions for Charlie

1. May I add the public `stats(w)` snapshot (above) now rather than in M4? Its fields are the ones doc 03 §9 lists.
2. Python drivers: OK? (goose-kb's t02_test.py did the same; the alternative, a Goose client program, would need
   its own threads and a hash function, and tells us less than an independent client.)
3. RT-5b appears in the M2 list (5a-d) and in the M5 list of design/README.md. I plan it for M2 as the last test, as it only needs
   the idle path; say if you want it left to M5.
4. Is the 64 MB ceiling in RT-5c acceptable as "stalls"? Loopback socket buffers autotune to a few MB each, so the
   real number is far below it; I would rather assert a loose ceiling than a flaky tight one.
