# Proposal

## Why

goose-io now has a contract (0.3) with eleven optional groups, and two event loops built on real sockets: goose-io-epoll (core plus five groups) and
goose-io-epoll-ext (all of the proxy groups: relay, peek, revoke, wake, limits). The groups were written for what tcprouter does. Nothing has
shown yet that they are enough. goose-io-snirelay (a copy of the private tcprouter, with its own epoll engine) is the proof: a real router, 46 test
files and speed gates, running on the contract instead of its own engine. If a group is wrong or missing, the port is where it shows, and it should
show before more groups are added or the optional-group model is changed.

## What Changes

- goose-io-snirelay's engine (`engine.goose`, `conn.goose`, `handler.goose`, about 1,650 of 2,770 Goose lines, and its C sidecar) is replaced by a
  router written against the goose-io contract. It is generic over the event loop and runs on goose-io-epoll-ext.
- Everything above the engine stays: `address`, `route`, `sni`, `policy`, `messages`, `config`, `check`. The public API (Worker, serve, Conn, Event,
  Config, Listener, Route, Target, Limits, the messages) keeps its shape, so the examples and the 46 test files run unchanged.
- goose-io-snirelay imports goose-io-epoll-ext by a pinned git import and owns no socket code. It is self-contained in its own repo.
- Where the port finds something the contract cannot express, the contract gains it (an `add-*` change and a conformance check), and the router does
  not work around it. Gaps found are recorded in this change.
- goose-io records the link to the end result (goose-io-snirelay) in its docs. The code stays in its own repo under `.implementations`, which goose-io
  ignores.
- No change to the contract is planned up front.

## Capabilities

### New Capabilities
- `router-on-goose-io`: a TCP router and forwarder (port and SNI routing, forwarding, handler mode, retry, tags, deadlines, fences, drain, stats,
  messages) that behaves and performs like tcprouter and runs on any goose-io event loop that offers the groups it requires.

### Modified Capabilities
<!-- none: the contract and the loops do not change unless a gap is found; any gap becomes its own change -->

## Impact

- `.implementations/goose-io-snirelay` (its own git repo, private): engine, conn and handler replaced; tests unchanged; new build wiring.
- `.implementations/goose-io-epoll-ext`: fixes only, for what the port finds in it. It stays code on top of goose-io-epoll.
- goose-io: documentation (README and docs) naming goose-io-snirelay as the worked example of the contract; contract changes only for gaps found.
- Nothing is pushed or tagged without asking: goose-io-snirelay is private and its CLAUDE.md requires it.
