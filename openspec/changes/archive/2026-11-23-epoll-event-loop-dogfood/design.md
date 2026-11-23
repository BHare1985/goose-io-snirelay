# Design

## Context

See proposal.md for why. State today:

- goose-io-snirelay (HEAD 8cd67fe) has its own engine: `engine.goose` (Worker, `start`, `serve`, `spawn`, Message), `conn.goose` (connection slots,
  accept, inspect, route, connect, retry, forward pump, timeout sweep), `handler.goose` (handler mode: send, dial, close, events, flush), a C sidecar
  `src/c_sys.c`, and the layers above it (`address`, `route`, `sni`, `policy`, `messages`, `config`, `check`) that do not touch a socket.
- The contract (goose-io 0.3) offers `listen`, `dial`, `send`, `close`, `tick_by`, `serve` (core) and half-close, sizing, abort, inspection,
  batching, unix, relay, peek, revoke, wake and limits as optional groups. goose-io-epoll-ext implements all of them except unix on real sockets. Its
  `listen` always sets SO_REUSEPORT, and its sockets always set TCP_NODELAY, as tcprouter's do.
- tcprouter's rules (its CLAUDE.md) still hold in that repo: a red gate first, one commit per step naming the RT rows, tests are never edited
  (propose to Charlie), nothing is pushed or tagged without asking the user.

## Goals / Non-Goals

**Goals:**
- A router over the contract that passes the same 46 test files and is not slower (spec: router-on-goose-io).
- A true test of the groups: every place where the router needs more than the contract gives is found and recorded.

**Non-Goals:**
- No new tcprouter feature, no change to its API shape, no splice (RT-4g stays v2; the relay group makes it possible later).
- No change to the optional-group model. That is the next piece of work and should start from what this port shows.
- No second event loop. The router is generic over `Io`, but this change proves it on goose-io-epoll-ext (and on the memory loop for the logic tests).
- Nothing pushed, tagged or published.

## Decisions

### D1. The router is generic over `Io`, in the root files of goose-io-snirelay
`Worker` keeps its public methods and wraps a loop value of a type given at compile time. Routing, SNI parsing, policy and messages stay as they are.
Alternative: copy goose-io-epoll-ext into goose-io-snirelay. Rejected: it would leave the router welded to one loop and teach nothing about the contract.

### D2. How tcprouter's features map onto the groups (to be confirmed task by task; a mismatch is a gap)

| tcprouter feature | Contract operation |
|---|---|
| per-worker listeners with SO_REUSEPORT | `listen` (reuse port is the loop's business), `listener_port`, `stop_listening` for drain (inspection group) |
| accept and `Opened{listener}` | core `Opened` |
| SNI inspect: read the ClientHello, keep it in the client socket | peek group: `wait_input(link, n)`, `peek`, `Input` event; the bound is the loop's `peek_bound` |
| retry: send the same hello to the next server; consume it only when a server answers | `peek` stays valid until bytes are consumed. Whether the contract can consume them after the first server byte (RT-21) is the first thing to check |
| forward pump (copy both ways, half-close, backpressure) | `relay(client, server)` (the loop moves the bytes), `relayed_bytes`; half-close group for `PeerEof` |
| handler mode: `send`, `pause_reading`, `dial`, `close`, `reset` | core, abort, sizing (`send_room`, `send2`) |
| connect timeout | `dial(addr, connect_ms)` |
| idle, half-close and inspect timeouts | limits group: `Idle`, `HalfOpen`, `Silent` (one limit per kind, armed per link) |
| tags, "close every connection tagged X", serve-until deadlines, fences | library side: a tag table, `tick_by` and a library heap; `write_deadline` and `discard_unsent` (revoke) for fences |
| messages to workers (Drain, Stats, CloseTagged, ReplaceDeadline, Policy, SetAddr) | wake group: `waker`, `wake`, `Woken`; the queue of message bodies is the library's |
| `Event.PassEnd`, batching window | batching group |
| drain with a deadline | `stop`, `draining`, `stop_listening` |
| stats | library counters |
| peer address, SO_LINGER close | inspection, abort |

### D3. Gaps are contract additions, not workarounds
When a row of D2 does not hold, the router stops and a gap record is written in tasks (what the router needs, the contract's nearest operation, why it
cannot be built on it). The fix is an `add-*` change with conformance checks on the memory loop first, then goose-io-epoll-ext, then the router uses it. Candidates
seen before starting, to be confirmed or dropped by the port and not assumed:
- TCP_NODELAY and SO_REUSEPORT: both are always on in goose-io-epoll-ext, so a transport-hints group is not needed for parity. The contract does not
  say so. Whether it should is a contract question for later.
- Name resolution: tcprouter takes literal addresses, so no async resolve is needed.
- Splice: not needed for parity (tcprouter copies today). `relay` may do better or worse than that copy, and the speed gate shows which.
- Loaned send, retained receive, kernel crypto, datagram: not used by tcprouter.

### D4. Proof by stages, each ending with the suite green on its own tests
1. Forward by port (no inspection): listeners, `relay`, half-close, limits, drain. Tests for forwarding, timeouts, drain, backpressure, scale.
2. Inspection, SNI routing and retry (peek, hello kept, early close).
3. Handler mode (send, dial, events, batching, pause, user value, generation checks).
4. Tags, deadlines, fences, messages, policy, stats.
5. Speed and memory gates, `examples/`, docs.
Each stage is one or more commits in goose-io-snirelay, named after the RT rows moved, as its CLAUDE.md requires. A stage's tests run first on the memory loop
where the test is a unit test, and on goose-io-epoll-ext for the network tests.

### D5. Acceptance numbers
- Tests: 46 files, 0 failed, none edited, run once at the end on a quiet host in the background (about 15 minutes) and repeatedly (`REPEAT=20`) for
  any test that failed once.
- Speed: each workload of `bench/RESULTS.md` at least 95% of the current tree's median measured back to back with `run-locked.sh`. The 95% is
  the design's assumption (loopback noise is a few percent); change it if you prefer another figure.
- Memory: at most 1.25 times the current bytes per idle connection.
- If relay turns out to be slower than the current copy pump on large bodies, that is a finding about the relay group, not a reason to rebuild the pump
  in the router.

### D6. Dependencies are pinned git imports
goose-io-snirelay imports goose-io and goose-io-epoll-ext by the full commit hash (goose's rule for git imports; tags work too). The two repos are private
and unpushed today, so the imports start as local paths during the work and become pinned imports once they are pushed. Pushing is asked of the user.

### D7. The library owns no loop; the application creates the loop and the router side by side
Goose forbids a root struct inside a root struct and root globals in threads, and a downstream library must not be limited in its grow-only arrays, so
`Worker` (a root struct) lives beside `epoll_ext::Loop`. Every call that touches a link takes the loop (`w.send(io, c, bytes)`, `w.start(io, cfg, index)`,
`w.serve(io) { w, io, ev => ... }`). Harnesses, examples and `generation_test` changed only to create the loop and pass it (D8); no assertion changed.

### D8. Existing tests change only to accommodate the new setup
Behaviour and assertions stay; each commit lists the harness edits. The engine-internal checks (stale and bad slot events RT-2b/2c, buffer pool counters
RT-5g/RT-2a, ready/waiting queue lengths) test the loop, not the router: unedited copies live in goose-io-epoll-ext (`net/tc/`, `unit/generation_test.goose`)
and are run there; tcprouter keeps the router-level files.

### D9. Memory per idle connection: 512 becomes 1024 bytes (RT-5b), decided by the owner
The old engine held one record per connection (about 150 bytes). A forwarded connection is now two general loop links (about 160 bytes each after slimming:
send queue, five limit slots, relay state, peek state) plus a small router record each (about 55 bytes), measured 746 bytes per idle connection against
936 before slimming (forward-state moved to a per-slot table, narrower fields). Reaching 512 would mean lazily filled side tables for the send queue, peer
address, peek and relay counters and compact timestamps in the loop, at the price of hot-path indirection. The owner chose to move the bound to 1024 bytes
(RT-5a is unchanged: no pool buffer per idle connection). The same edit is in tcprouter's `memory_test.py` and `design/05-requirements.md`.

### D10. Gaps found and closed in the contract or the loop (none worked around in the router)
- G1 `discard_input(link, n)` in the peek group (a retry must not replay the ClientHello twice).
- G3 `wake_with(waker, value, body)` and `Woken.body` (policy and control messages carry up to 64 bytes).
- G4 `relayed_bytes` stays readable in Closed (stats count a pair's bytes after it ended).
- G6 keep-open on inspect listeners; per-pass clock for fences; HalfOpen moved by traffic; batch window bounded by wakes and limits; pool minimum of one
  buffer; `workers_ready` once per start; drain counts a relayed pair once.
- Loop fairness: `_deliver` handles only events queued at its start, and `send` stops writing after 30 ms in one pass, so a handler that always has more to
  send cannot starve wakes. The router writes fences with `write_deadline(until_ms + 1)` so the loop never cuts a write inside the deadline's own millisecond.
- Handler Data bytes are copied into `Worker.data_copy` before the handler runs (the borrow checker cannot prove the handler apart from the loop's buffers):
  one copy per handler Data event, none on the forwarding path.
- `spawn` hands each thread the configuration through a global set before the threads start.

## Risks / Trade-offs

- [The contract cannot consume peeked bytes after a retry, so RT-21 (early close) cannot pass] → check first (task 1.2); if so it is the first gap, and a
  group addition (a consume or a replay of peeked bytes), not a router workaround.
- [Relay is slower than tcprouter's pump on large bodies] → measure early (task 2.4 of stage 1) rather than at the end, before inspection and handler code depend on it.
- [Messages and fences depend on timing the loops do not promise (Woken ordering, Expired at the first pass after due)] → the tests that check them are
  the evidence; a failing one is a gap record.
- [A 15-minute suite makes the loop slow] → unit tests on the memory loop and `tests/run_tests.sh NAME` per stage; the full run once per stage.
- [Replacing 1,650 lines at once] → stages above; the old engine stays in git history, and the tree builds and passes at the end of each stage for the files
  that stage covers.
- [goose-io-epoll-ext fixes disturb its own conformance] → every fix there reruns `conformance.sh --repeat 3` and `net/run.sh` before the commit.

## Migration Plan

Work in a branch of goose-io-snirelay. The old engine remains available until the last stage (the stage-1 revert 8cd67fe shows an earlier attempt that was
dropped, so start from HEAD). Rollback is to not merge the branch. The repo is private; nothing is published.

## Open Questions

- Is 95% (speed) and 1.25 times (memory) the right acceptance figure? It is recorded as an assumption in D5 and changes nothing about the tasks.
- Which of tcprouter's own tests count as sufficient evidence of behaviour? If a requirement row has no test, the port reports it instead of passing
  silently; whether to add tests is decided with Charlie, as tcprouter's rules say.
