# M4 test plan: timeouts, drain, messages, tags and deadlines, stats across workers

Status: proposal for Charlie, before any M4 test is written. Rows: RT-7a-d, RT-4c (its timed-out half), RT-8a-c, RT-10a-b,
RT-6a-e. Same method as M2/M3: a user-style system under test (forward_server, extended), independent Python drivers, red
gates per group, each reported with `library lines: Goose N, C M` (now Goose 1778, C 204).

## API this needs (shape additions; Charlie to approve)

1. **A tag and a generation on a forward target**: `Target { addrs, tag: u16 = 0, gen: u32 = 0 }`. A connection forwarded
   through it carries (tag, gen). Tag 0 is "untagged": never fenced. (doc 03 section 6: "close every connection forwarded under
   `tag` whose route was set up under generation <= `gen`". The generation has to come from somewhere; config is static in v1, so
   the config says it.)
2. **`Message` gains `Deadline { tag: u16, until_ms: i64 }`**: tag T may forward until the absolute `CLOCK_BOOTTIME` millisecond
   `until_ms`. A later `until_ms` raises the deadline (a renewal); an earlier or equal one is ignored (max, so a late or duplicate
   message is harmless and can never shorten or extend wrongly: RT-6d). Cutting a tag now is `CloseTagged`, not an earlier deadline.
   (Reading of RT-6d: "an earlier deadline never extends it".)
3. **`Config.fenced_tags: u16[..16]`**: tags that start with no deadline, i.e. fenced: their connections are closed at once
   (reason `Fenced`) until a `Deadline` in the future arrives (RT-6e).
4. **Stats across workers**: `Message.Stats { reply_to }` makes each worker `qput` a `StatsReply { worker, stats }`; a helper
   `tcprouter::gather_stats(workers: i64) -> Stats` posts and sums the replies (RT-10b). `Stats` gains `sessions` per tag:
   `tags: TagSessions[..16]` with `TagSessions { tag: u16, open: i64 }`.
5. **`wait_for_signal_then_drain(deadline_ms)` really drains**: waits for SIGTERM/SIGINT, posts `Drain`, waits for the workers
   (`spawn` keeps their thread ids in a global), returns. `serve` returns when its worker has drained.
6. Messages travel over one `pipe2` per worker, created by `spawn` before the workers start (verified in M0, O-2). A 17-byte flat
   record per message (a pipe write that small is atomic). `post` is callable from main or from a thread started after `spawn`.

## Harness changes

`forward_server` gains: `--idle-timeout-ms`, `--half-close-timeout-ms`, `--drain-ms` (the deadline main passes to
`wait_for_signal_then_drain`), `--tagged-route LISTEN=T[,T]@TAG:GEN`, `--fenced TAG`, and a **control thread** reading commands
from stdin and calling `post`: `deadline TAG BOOTTIME_MS`, `close-tagged TAG GEN`, `drain MS`, `stats` (prints `TOTAL accepted=…
closed=… bytes_in=… …` from `gather_stats`). A `thread_fn` started after `spawn` sees the pipe fds in its copy of the globals.
`netlib` gets `Server.command(line)`, a `BlackholeBackend` (a `listen(0)` socket with its accept queue filled: new SYNs are
dropped, so a connect never completes: deterministic, no firewall), and `boottime_ms()` (`time.clock_gettime(CLOCK_BOOTTIME)`).

## Group A: timeouts (timeout_test.py) RT-7a-d, RT-4c timed-out half

- RT-7a: connect timeout 500 ms. Target = blackhole: the client is closed within 500 ms + 300 ms, counted `ConnectFailed`, no bytes
  reach anything. RT-4c timed-out half: targets [blackhole, good echo]: the client's 100 KB, sent at once, arrives intact after
  about 500 ms (not before 450 ms, not after 800 ms), `connect_failures = 1`, `retries = 1`.
- RT-7b: idle timeout 1000 ms. No bytes either way: closed in 1.0-1.3 s, `IdleTimeout`. A connection sending one byte every 400 ms
  for 3 s stays open; the same with traffic only server-to-client stays open.
- RT-7c: half-close timeout 1000 ms. Client sends FIN, the backend never closes: closed in 1.0-1.3 s after the FIN, `HalfCloseTimeout`;
  and with the backend sending FIN first and the client silent. A half-closed connection that is still moving data is not closed
  by the half-close timer (data resets it).
- RT-7d: each of the above asserts limit + 300 ms (limit - 50 ms at the early edge). The whole file runs with the 250 ms sweep.
- Needs `last_active_ms` and the time a direction ended in the slot, and the connect deadline in the existing sweep.

## Group B: drain and signals (drain_test.py) RT-8a-c

- RT-8a: `drain 30000`: the listener closes within 200 ms (a connect to the port is refused); a second `forward_server` started on
  the same port then gets all new connections (50 of 50), process A's `accepted` does not move; A's existing connection keeps
  working during the drain.
- RT-8b: A exits (status 0) shortly after its last connection closes (within 500 ms); with a connection held open past the deadline
  (`drain 1000`) A closes it (`Drained`) and exits at the deadline + 300 ms, status 0.
- RT-8c: SIGTERM and SIGINT each start a drain (`--drain-ms 2000`): same checks, with the exit at the deadline for a held connection.

## Group C: messages, stats, tags and deadlines (message_test.py, deadline_test.py, tests/unit/clock_test.goose)

- RT-10a: with 4 workers, `post` of a `Stats` message gets exactly one reply per worker, indexes 0..3 once each, repeated 50 times
  (no loss, no duplicate); a `Drain` reaches every worker (all four exit).
- RT-10b: a workload with known totals through 4 workers: 400 connections moving 1,000,000 bytes up and 2,000,000 down, 20
  connections to refused targets, 10 closed by idle timeout, connections under two tags. The summed `gather_stats` equals the
  test's own counts exactly: accepted, closed by each reason, bytes in and out, connect failures, retries, sessions per tag.
- RT-6b: connections under tag 7 (gen 1 on listener A, gen 2 on listener B) and tag 8: `close-tagged 7 1` closes exactly A's tag-7
  connections within 100 ms (`Fenced`), leaves B's and tag 8's untouched; while a flood runs on tag 7 the bytes the backend gets stop
  growing within 50 ms of the command (messages are handled before events).
- RT-6a: tag 7 with `deadline 7 now+3000`: traffic flows; at the deadline its connections close (`Fenced`) and the recording backend
  saw zero bytes after `until_ms` (timestamps in the backend). The frozen case: SIGSTOP the proxy at deadline - 1 s, SIGCONT at
  deadline + 1 s, the client sends the instant it resumes: zero bytes reach the backend, the connection is closed.
- RT-6d: `deadline 7 T` then `deadline 7 T-1000` (earlier) then a duplicate of the first: the connection still closes at T, not before;
  `deadline 7 T+2000` (a renewal) extends it to T+2000.
- RT-6e: `--fenced 7`: a connection on tag 7 is closed at once; after `deadline 7 now+60000` it is served; after the deadline passes
  new connections are refused again.
- RT-6c (unit): `tests/unit/clock_test.goose`: the engine's clock (`c_boottime_ms`) agrees with `/proc/uptime` (which is CLOCK_BOOTTIME)
  within 50 ms, over several reads, and is non-decreasing; a comment states why not CLOCK_MONOTONIC.

## Sizing

I expect about +400 lines of library Goose (message pipe and decoding, drain, deadlines and tags, stats gather, timers in the sweep) and
about +10 lines of C (pipe helpers). I will keep each piece to what a test calls for.

## Questions for Charlie

1. Are the API additions (1-5) right, especially the deadline rule in 2 (later raises, earlier ignored) and `Config.fenced_tags`?
2. `gather_stats` as a public helper, or only the `Stats` message and the reply type?
3. Is a control thread in the harness (stdin commands) acceptable for driving messages, rather than a socket? (It is also the pattern a
   real program would use for its control protocol; Steve's control protocol will sit on this.)
4. RT-6a's frozen-process case with SIGSTOP/SIGCONT: acceptable as a network test on this host?
