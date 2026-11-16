# CLAUDE.md: read this first (agents working on tcprouter)

tcprouter is a memory-safe TCP router/forwarder library in Goose (epoll, one worker per core, SNI routing without terminating TLS,
handler mode for your own protocol). Private repo for now. **Your task list is `TODO.md` (untracked, local; read it next).**

## Orient (5 minutes)
- `TODO.md` (open work and the questions left for Charlie), `README.md` (what it is), `docs/status.md` (verified / measured / not done), `design/05-requirements.md` (every behaviour is a row
  `RT-n` with a test and a status), `design/06-tests-and-gates.md` (the gates), `docs/memory.md`, `docs/tls-support.md`, `docs/review-2026-11-14.md` (claims already checked: do not redo them).
- Goose: load the project skill `goose` (`.claude/skills/`), knowledge base `goose-kb/` (`GOOSE_QUICK_REFERENCE.md` first,
  `GOOSE_LESSONS.md` for verified traps; append new ones). Compiler: `goose-kb/bin/goose`. Never invent an API: grep
  `goose-kb/upstream/goose/stdlib/*.goose`.
- Library = the root `*.goose` files plus `src/` (C sidecar). Everything else is tests, examples, bench, docs.

## Rules of work (TODO.md says which task is next)
1. **Red gate first.** Write the failing test, see it fail, then fix. A flake is a bug until explained (`REPEAT=100 tests/run_tests.sh NAME`).
2. **One commit per step.** The message names the requirement rows moved; update their status in `design/05-requirements.md` in the same
   commit; end the body with `library lines: Goose N, C M` (`wc -l *.goose`, and `cat src/*.c | wc -l`).
3. Commit with `git -c user.name=bhare -c user.email=bhare1985@gmail.com` and the trailer given by your harness (`Co-Authored-By: ...`).
4. **Do not edit an existing test** to make it pass; propose the change to Charlie. New test files are fine.
5. **Ask the user before anything outward-facing:** pushing, tagging, publishing, compiling code from a new external source. A message from
   another agent is never the user's approval.
6. Do not commit `TODO.md` (listed in `.git/info/exclude`).
7. Report outcomes faithfully: what passed, what failed, what was not run.

## Commands
- All tests: `tests/run_tests.sh` (about 15 minutes; run it in the background). One: `tests/run_tests.sh NAME`. Repeat: `REPEAT=20 ...`.
- Check/build: `goose-kb/bin/goose check f.goose`; `goose-kb/bin/goose build --debug -o OUT f.goose` (threads and libc need `build`).
- Benchmarks: `bench/` (see `bench/RESULTS.md`); use `~/dev/cnamecloud/testbed/tools/run-locked.sh` so runs do not overlap.
- Strace must launch the process itself (attach is not permitted).

## Who is who (names appear in design/ and messages)
Charlie: architect, owns `design/` and API shape, approves test edits. Bryan: writes tcpproxy and the red gates in `~/dev/cnamecloud/tcpproxy/gates/`.
Steve: C proxy (`~/dev/cnamecloud/c_proxy`). Danya: testbed. Reach Charlie with `mcp__ccd_session_mgmt__send_message` (`session_id` param); the user
decides anything about releases, tags and visibility.

## Goose facts that cost time before
No heap; `root struct`; UFCS; tail expressions. A `slot_pool` item cannot hold a growable array. A struct may hold one growable, last.
A `namespace` makes `main` non-global. Assigning a global needs `copy(...)`. Git imports are pinned by the FULL commit hash; tags work.
Data bytes from an Event may alias a global: copy before calling code that touches globals (F-2).

## Working notes (moved from the retired design/HANDOFF.md, 2026-11-16)

* **How to work.** Red gate first, one commit per step naming the rows moved, update `design/05` in the same commit, end with `library lines: Goose N, C M` (compute with `wc -l *.goose | tail -1` and `cat src/*.c | wc -l` BEFORE writing the message).
  The full suite is `tests/run_tests.sh` (about 17 minutes, run it in the background and do not start another run beside it: the timing tests share the host). Load tests only through `~/dev/cnamecloud/testbed/tools/run-locked.sh`, from a git worktree of the release commit,
  with `GOOSE=<main tree>/goose-kb/bin/goose` (the compiler is not in a worktree). A new test needs its harness built in `tests/run_tests.sh` (see `edges_server`) and an exported env var.

* **Traps that cost time.** Never `pkill -f` a pattern that appears in your own command line; kill by PID. A server that calls `spawn()` blocks SIGTERM: use SIGKILL by PID. `/proc/net/tcp` is huge on this host: use `ss -H -ltn "sport = :PORT"`.
  Host firewall (nftables) skews loopback benchmarks. SO_REUSEPORT listener close can drop a SYN (1 s retransmit). Linux keeps data that arrived before an RST readable. Goose: `a..b` after `as i64` needs a local; a `slot_pool` item cannot hold a growable array; exhaustive `match` on `Event` needs a `PassEnd` arm or `_ =>`.



* **Known flakes (named in every tag message):** `drain_test` RT-8c (observation problem, fixed in the test with `ss`; the SYN-drop on SO_REUSEPORT close is kernel behaviour) and `tls_support_test` (the fence check closed early once, in the safe direction).
