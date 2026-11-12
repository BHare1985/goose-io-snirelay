# Handoff (Brian, 2026-11-09, at the v0.1.0 candidate)

Everything is committed; nothing is half-built. `tests/run_tests.sh`: **30 test files, 0 failed**. Every v1 requirement row in
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

## Queue after v0.1.0 (updated 2026-11-11; the full list with details is the local `TODO.md`)

State of `main` at 3657c89 (pushed): policy hook (55be46b), CLAUDE.md, ReplaceDeadline + SetAddr + 64-byte Message (3657c89).
RT-6f is green 26/26 and 100 of 100 runs alone; the 100-run gate **under load is pending** (run it under `~/dev/docker/tools/run-locked.sh`, hogs killed by a trap;
`/tmp/rd_load.sh` was the script). The full suite has not been rerun since the policy-hook commit. RT-10c is green.

Order (Charlie, priority: tcprouter + tcpproxy ready for Demo 2):
1. **T01c Message.Policy + `on_message(p, body, now_ms) -> Effect`** (`Effect = None | CloseTagged { tag, gen }`, performed on that worker only; body at most 48 bytes).
   Unblocks about 17 of Bryan's 19 failing tests. **Work in progress, UNCOMMITTED in the working tree**: `engine.goose` (Message.Policy), `messages.goose`
   (kind 7: byte 15 = length, bytes 16 to 63 = body), `policy.goose` (Effect, hook, queueing, delivery), `tests/net/harness/policy_message_server.goose`,
   `tests/net/policy_message_test.py`, `tests/run_tests.sh`, and `on_message` stub added to `policy_server.goose` (every policy now needs the hook).
   Test state: 10 of 11 checks pass; the one failing check is probably the test's text match on `now_ok=` (Goose prints a bool in its own spelling; look at
   the harness output). Rows RT-13g, h, i are not yet in design/05. SetAddr/ReplaceDeadline/Deadline are still to be handed to the policy read-only (Charlie), not done.
2. **T01d `Pick.To.connect_ms`** (0 = `Limits.connect_timeout_ms`): Bryan's gate and a 6-line patch are in `~/dev/tcpproxy/gates/connect_ms`; every `Pick.To` constructor needs the
   field; check that a retry restarts the connect timer.
3. **T01b signals**: SIGUSR1 in the signalfd set, `wait_for_signal() -> i32`, `drain(deadline_ms) -> i64`; `wait_for_signal_then_drain` stays as a wrapper.
4. The RT-6f gate under load, then the full suite (`tests/run_tests.sh`, about 15 minutes, in the background).
5. **Tag v0.2.0, move v0, push** (the user approved the push; tag only when 1 to 4 are green), and tell Bryan the commit.
6. Then be Bryan's first responder: engine bugs from his 27-test verify_backends run come before everything else.
7. skein items (after tcpproxy passes 27/27): G-1 `shutdown_write`/`close_after_drain` + `w.send_room(conn) -> i64` (v0.2.x), `w.draining() -> bool`,
   `w.dial(addr, tag) -> Conn` (v0.3; red gate `~/dev/skein/docs/dial-red-gate.md`; `send` before `Opened` returns false, document in design/02).
Also open: T03 (tls_support_test fence flake, look at it with RT-8c) and the other public-release tasks in TODO.md (user decisions in T05).

## Update 2026-11-11 (wrap-up): what is pushed, what is left before v0.2.0

Pushed on main: policy hook 55be46b; ReplaceDeadline + SetAddr 3657c89; Message.Policy + PX-5 + 64-entry tag tables + licences feffc9d;
fail-closed deadline table (RT-6g, tag 65; red 1 of 5 then green 5/5) 3960a7e; Pick.To.connect_ms (RT-13k; red 3.01 s / 0.3 s, then green) cec6dac;
signals (RT-8d, RT-8e) in the commit after cec6dac (see `git log`). Full suite last run green at feffc9d (34 files, 0 failed); it has NOT been rerun since.
No working-tree changes are left uncommitted. TODO.md (local, untracked) holds the long list.

Remaining order before the tag:
1. The RT-6f 100-run gate under load, UNDER the host lock: build a worktree of the final commit and run `~/dev/docker/tools/run-locked.sh /tmp/rd_load.sh`
   (it starts nproc busy loops with a trap that kills them; the script is `/tmp/rd_load.sh`, rewrite it if /tmp was cleaned). Never run load outside the lock.
   RT-6f in design/05 still says "green after the 100-run gate (alone: pending; under load: pending)": alone is 100/100 (fixed test), update it with the result.
2. The full suite on the final commit (`tests/run_tests.sh`, about 15 minutes, in the background; its 34+ files include the new policy_message, connect_ms, signal and tag_overflow tests).
3. Tag v0.2.0 and move v0, push both (the user approved; Steve and Charlie said no further OK is needed), then tell Steve and Bryan the sha.
4. Then be Bryan's first responder for his 27-test verify_backends run (engine bugs first).
5. After tcpproxy passes 27/27: skein items G-1 `shutdown_write`/`close_after_drain` + `w.send_room`, `w.draining() -> bool`, `w.dial` (v0.3).
Open: T03 (tls_support_test fence flake, look with RT-8c), the public-release list in TODO.md. Policy types must define `on_message`; every `Pick.To` needs `connect_ms`.
Known mistake: commit feffc9d says library lines Goose 2373; the real count was 2388 (corrected in 3960a7e's message).

## Update 2026-11-12 (second wrap-up): suite result, what the tag still needs

Full suite on a3a5f2c (code identical to 6244c1a): 37 test files, 2 failed, both KNOWN flakes, neither understood: `drain_test` RT-8c ("SIGTERM closes the listener at
once (never)", about 1 run in 25; my untested guess is a recycled port on a busy host: another process takes the port the server just freed, so the "connect must be refused"
check sees a connection succeed) and `tls_support_test` (the fence check, an early close with 0 late bytes: the safe direction). The host was busy with other teams' runs.
Every other file passed, including policy_message, connect_ms, signal and tag_overflow.
NOT done: the RT-6f gate under load (a queued job never started and was removed: its wait loop matched its own wrapper; rebuild it as in the 2026-11-11 note, from a worktree at
the final commit, under `~/dev/docker/tools/run-locked.sh`), and the tag. Steve's ruling: tag v0.2.0 only AFTER the load gate passes; put RT-8c (`drain_test`) and the
`tls_support_test` early close in the tag message as known issues with test names; after the tag RT-8c is the next item. design/07 PX-2a now says the passive skip is one check
interval (1 s by default), per Bryan. Bryan pins a3a5f2c until the tag exists.

## Priority change 2026-11-12 (Charlie, via Steve)

Next-session order: 1) the RT-6f load gate (under run-locked.sh, from a worktree of the final commit); 2) tag v0.2.0 and move v0 (known issues named in the tag message:
`drain_test` RT-8c and the `tls_support_test` early close); 3) **`w.dial(addr, tag) -> Conn` (v0.3), moved up: red gate first (`~/dev/skein/docs/dial-red-gate.md`, 9+1 checks), then green**,
because Milli's million-users entry on skein needs it for non-blocking Postgres; 4) the rest: RT-8c, then G-1 `shutdown_write`/`close_after_drain` + `send_room`, `w.draining()`.
`send()` on a dialled connection before `Opened` returns false and queues nothing (Charlie's ruling; document it in design/02). Sprint 3 is unaffected; tcpproxy does not use dial.

w.dial extra check (Milli via Charlie, 2026-11-12): 500 small `send()`s queued back-to-back on a dialled connection (Postgres pipelining), a stalled peer fills the queue (send returns false), drain, `Writable` resumes it, bytes in order; same send queue as client connections.

## Update 2026-11-12 (later): v0.2.0 tagged, w.dial done

v0.2.0 and v0 are tagged and pushed (f54cf75; RT-6f 100/100 under load, 75 min 53 s). `w.dial` is on main: red 77eba44 (stub, 11 of 15 failed on assertions), implementation 9d37436
(dial_test 17/17; full suite 38 files, 0 failed on that run). No v0.3 tag yet (Steve/Charlie decide). Next, in order: RT-8c (`drain_test`, loop it under strace with a timestamped log; my untested
guess is a recycled port on a busy host), then G-1 `shutdown_write`/`close_after_drain` + `w.send_room(conn) -> i64`, then `w.draining() -> bool`. Library lines at 9d37436: Goose 2534, C 223
(the commit message says 2548, the red commit 2450 instead of 2451: both wrong, corrected here).

v0.3.0 is tagged and pushed (tag ae0c6f1, commit ac76768; dial_test 20/20 under load). The `v0` tag still points at v0.2.0 (f54cf75): my force-push to move it was refused by the permission check and is with the user. Until they decide, consumers pin v0.3.0 (Milli: tag ae0c6f1, commit ac76768).
