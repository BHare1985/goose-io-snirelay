# Handoff (Brian, 2026-11-09, at the v0.1.0 candidate)

Everything is committed; nothing is half-built. `tests/run_tests.sh`: **30 test files, 0 failed** (about 15 minutes). Every v1 requirement row in
[05-requirements.md](05-requirements.md) is green or done; the only rows not green are the two v2 rows (RT-4f bench harness, RT-4g splice).
library lines: Goose 2126, C 222. What is verified, measured and open is in [docs/status.md](../docs/status.md).

## What changed since the M4 handoff

* **Performance** (bench/RESULTS.md): edge-triggered forwarding; throughput 99% to 103% of the C copy engine in every row except new connection per request (about 91%).
  Idle RSS 3,024 kB against 2,620 kB (the shared name pool that reached 2,588 kB was reverted for readability).
* **Fencing is a release gate and passed:** RT-6a (forward) 100 of 100; RT-6a-H (handler mode, `send` and the flush read the clock) 100 of 100 alone and 100 of 100 under load.
  The residual window between the last check and the `send()` syscall is in design/06.
* **M5 rows:** RT-2a, RT-5f, RT-5g, RT-11a, RT-11b, RT-11c green. `examples/http_server` (RT-12a to RT-12e) benchmarks at 99.9% to 100.4% of the C backend up to 16 KiB and 83% to 84% at
  64 KiB and 1 MiB (the `send` copy). Engine change made for it: a pending Data event no longer clears EPOLLIN on a handler connection.
* **Code is written the author's way** (UFCS method calls, tail expressions); skills in `.claude/skills/`, notes in `goose-kb/GOOSE_LESSONS.md`.
* **gslib support check** (docs/tls-support.md): TLS 1.2 and 1.3 on handler mode work; no HTTPS server is shipped.

## Unexplained, left open on purpose

* **RT-8c** (SIGTERM/SIGINT closes the listener at once) failed about once in 25 looped runs, also before the performance work. It passed in the last full run. **Unexplained.** Do not call it fixed.
* Everything else that flaked was found and fixed (RT-8a: a stale stat line in the test; RT-6a: a stale pass clock in `_tag_allows`; a backpressure and a generation test: see git log).

## Next steps, in the order I would do them

1. **Policy hook** `w.serve(policy)` as the first red gate of tcpproxy (design/07; O-1 re-verified). Handle-mode fence gate is already green.
2. **Engine items from the TLS check** (post-v0.1.0): G-1 half-close/linger-close for handler connections; G-2/F-2 (Data bytes provably not static, to avoid a copy) is a candidate only; a borrowed-slice `send` would close the last gap at 64 KiB to 1 MiB (an API change for Charlie).
3. RT-8c: loop `drain_test` with `strace -f` and a timestamped log of the signal, the pipe write and the listener close.
4. Tell Steve that `bench/proxybench.sh` line 89 carries one local change (`NOROOT=1`).

## Things to check

* Goose is pre-1.0; tested with `goose 751794c`. gslib (used only by `tests/net/harness/tls_server.goose`) is fetched at a pinned commit; its licence is unstated (O-9).
* The Gatekeeper guide `docs/gatekeeper-next-step.md` was reviewed by Charlie; it says replacing the C proxy is not a decided goal.
