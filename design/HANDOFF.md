# Handoff (Brian, 2026-11-04; updated after M4)

**Update after M4:** M4 is done (timeouts, drain, messages, tags and deadlines, stats across workers); 21 test files pass; 42 of 48 v1 rows are
green or done, the remaining six are M5 (RT-2a, RT-5f, RT-5g, RT-11a-c). `serve(w, policy)` (the tcpproxy hook) is still the one engine stub. The
backpressure_test flake hunt came back clean: 60 of 60 runs (30 alone, 30 beside a looping forward_test), so RT-5c and RT-5d are done.
library lines: Goose 2005, C 223. The sections below are the end-of-M3 handoff and are kept for the record.

Everything below is committed. Nothing is half-built: group C (handler mode) finished green before this was written.
The tip of `main` is this file's commit; the last code commit is `09255ec` ("engine: handler mode").

## Where things stand

**M0, M1, M2 are done. M3 is done except the timed-out half of RT-4c** (it needs the connect timeout, which is M4).
28 of 50 requirement rows are green or done (doc 05 is the source of truth; `tests/coverage.sh` prints rows with no test).
16 test files pass (`tests/run_tests.sh`, about 3 minutes; `REPEAT=20 tests/run_tests.sh forward` repeats a network driver and keeps every FAIL line).

| Milestone | Rows | State |
|---|---|---|
| M0 | O-1..O-6, O-8, O-10 answered; package skeleton; test runner | done |
| M1 | RT-3e, RT-3f (parser, matching) | done |
| M2 | RT-1a, RT-4a, RT-4b (done after 20 of 20 clean runs), RT-5a, RT-5b, RT-5c, RT-5d | green |
| M3 | RT-1b, RT-1c, RT-1d, RT-1e, RT-2b, RT-2c, RT-3a, RT-3b, RT-3c, RT-3d, RT-3g, RT-4d, RT-4e, RT-5e, RT-9a, RT-9b, RT-9c, RT-9d | green |
| M3 | RT-4c | green for refused connects; the timed-out half joins in M4 |
| M3 | RT-11a | partly green: the three examples build, http_hello runs; the README example and CI are later |
| M4 | RT-6a-e (tags, deadlines, fences), RT-7a-d (timeouts), RT-8a-c (drain), RT-10a-b (messages, stats across workers) | not started (`design`) |
| M5 | RT-2a (10,000 idle per worker), RT-5f (fairness), RT-5g (no allocation on the data path), RT-11b, RT-11c | not started |
| v2 | RT-4f (bench vs the C proxy), RT-4g (splice) | not started |

Measured so far (printed by the tests): 58 bytes of RSS per idle connection (limit 512); 1,000 idle connections grew RSS 64 kB; a 1 GB offer to a
backend that never reads stalls at about 6.7 MB with 0 RSS growth; 1,000,000 connect/close cycles with random RSTs in 92 s, 0 wrong tags; 500 half-sent
hellos cost 36 kB; 100,000 keep-alive requests from 100 clients in 2.4 s (client-bound: Python); worst Tick gap 101 ms.

## In flight

Nothing. No uncommitted work, no experiment left running. `tests/net/PLAN-M2.md` and `PLAN-M3.md` are the approved plans (M3 is fully done apart from RT-4c).

## Next step (M4), in the order I would do it

1. **Write the M4 test plan first** (`tests/net/PLAN-M4.md`) and send it to Charlie before any test, as for M2 and M3.
2. Timeouts (RT-7a-d): the connect timeout goes into the existing 250 ms sweep in `_sweep_timeouts` (conn.goose); idle needs a `last_active_ms` per
   slot, half-close needs the time a direction ended. Then add the timed-out half of RT-4c to `tests/net/retry_test.py`: a `listen(0)` socket with a
   full backlog never completes a SYN (deterministic). RT-4c is `done` only after that runs.
3. Drain (RT-8a-c): needs the message pipes (`spawn()` creates one per worker before the workers start; globals set in main are copied into each worker;
   `start()` finds its own end by index; design/03 section 7, verified in M0 `O-2`), a `Message` reader in the loop, and `wait_for_signal_then_drain`
   posting `Drain` (it currently just waits for the signal and returns).
4. Tags, deadlines, CloseTagged (RT-6a-e) on `CLOCK_BOOTTIME`, checked at the top of every loop pass and before any write to a server side.
5. `post` / `Message.Stats` gathering across workers (RT-10a-b).
6. Then the "tcpproxy can be written" evidence for Charlie: M2-M4 green, the examples building, `http_hello` at 100 clients x 1,000 requests.
7. Then M6: benchmark against the C proxy's epoll engine (`~/dev/c_proxy`: `proxybench.sh`, suite `sni-plain`, config `epoll_hybrid`), without sudo and with the
   C proxy run under exactly the same no-root conditions; ask Steve how to run his no-root copy; take the host lock; never bench while the Gatekeeper testbed runs.

## Open questions and things to check

- `serve(w, policy)` (the tcpproxy form) is still a stub; design/07 and O-1 (verified) say how the engine will call the policy (`p.pick(...)` on a generic parameter).
- `Worker` has about 16 growable fields, so each worker reserves roughly 16 x 2 GB of address space for data stacks (`--stacks` shows it). Fine for tens of workers;
  if it matters, `--stack-reserve` shrinks it, or fewer fields (e.g. merge the two free lists).
- Per-connection memory: `_ConnectionSlot` grew when handler mode arrived (output queue fields). RT-5b measured 58 bytes per idle connection *before* that; re-measure
  with `python3 tests/net/memory_test.py` and decide whether the handler fields should move to a side table (the user wants less memory).
- Library size: the user watches it. **library lines: Goose 1778, C 204** (wc -l of the root `*.goose` and `src/c_sys.c`, comments included).
- Chrome, Firefox and Go ClientHellos are not captured (not installed here); `tests/data/README.md` says so. O-9 (gslib's licence) is unanswered, so Example B (TLS with gslib) is described, not built.
- Goose moves fast: `goose-kb/bin/update-goose.sh --check` at the start of a session; the compiler in use is `goose 751794c`. A rebuild takes about 10 minutes.
- Intermittent failures seen and explained so far: forward_test (a race in my test, fixed), RT-5d (kernel autotuning absorbed the load; fixed with a small receive buffer on the stalled
  backend). Run a new network test with `REPEAT=10` before calling it green.
- Naming rule (README, unchanged since the user's last word): public names plain; private Goose names a leading underscore and spelled out; anything from C is `c_`
  (the functions in `src/c_sys.c` and their declarations in `sys.goose`, same names).
- The `goose-kb/` directory is our research notes and skills; it is not part of the package (`tcprouter.build` excludes it). `goose-kb/upstream/` is git-ignored (62 MB).

## How to pick this up

```bash
cd ~/dev/tcprouter
goose-kb/bin/update-goose.sh --check      # is Goose current?
tests/run_tests.sh                        # all 16 test files; about 3 minutes
tests/run_tests.sh retry                  # one test file by name
REPEAT=20 tests/run_tests.sh forward      # repeat a network driver, keep every FAIL line
tests/coverage.sh                         # rows with no test yet
```

Read first: `design/README.md`, `design/05-requirements.md` (status column), `design/03-engine.md` sections 11-13 (what the engine does, as built), `README.md` (naming rule),
`goose-kb/GOOSE_LESSONS.md` and `goose-kb/GOOSE_PACKAGES_AND_C.md` (Goose facts verified here).
