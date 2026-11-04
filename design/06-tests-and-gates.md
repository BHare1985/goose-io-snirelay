# 06 — Tests, red gates and done

## The red-gate process

1. **Brian writes a test first**, against the public API as doc 02 describes it, for one group of
   requirement rows. It must compile against stubs (functions that exist with the right
   signatures and do nothing) and **fail** for the right reason. That is a red gate.
2. **Brian sends Charlie the test** (path and commit). Charlie reviews only two things:
   - **Is the library used the way doc 02 intends?** Would a stranger write this code? Is anything
     awkward that the API should fix instead of the test working around it?
   - **Does the test prove its rows?** The numbers and pass/fail line in doc 05.
   Charlie approves, or asks for a change to the test or to the API (an API change updates doc 02
   in the same commit).
3. **Brian makes it green.** The approved test is the contract: changing it later needs Charlie's
   approval again, with the reason in the commit message.
4. Row status in doc 05 moves `design → red → green → done`.

Approval is per test file, so Brian can have several gates in flight.

## Layout

```
tcprouter/
├── tcprouter.goose          the package root (namespace tcprouter) [verify package layout]
├── tcprouter.build          C sidecar list, if any
├── src/…                    internal modules
├── tests/
│   ├── unit/                pure Goose: sni_test, route_test (matching), config_test, generation_test
│   ├── net/                 real sockets on 127.0.0.1: forward, retry, timeout, handler, drain …
│   ├── data/                captured ClientHellos
│   ├── harness/             test servers and clients (echo, sink, slow reader, refusing port)
│   └── run_tests.sh         builds with --debug, runs everything, prints rows proven
├── bench/                   compare.sh against the C proxy and HAProxy (v2)
├── examples/                forward_port, sni_router, http_hello
└── design/                  these docs
```

- **Unit tests** are Goose programs that print `PASS`/`FAIL` lines and exit non-zero on failure,
  like `goose-libdeflate/test/` (the user's existing Goose package).
- **Network tests** may drive the library from Goose and check from a small Python or shell
  client where that is clearer (goose-kb's `t02_test.py` pattern).
- **Every network test picks a free port** and checks it is free first (RT-1d's trap), and never
  runs while a benchmark or the Gatekeeper testbed is using the host.
- **Every test file's first comment lists its rows**: `// Proves: RT-4a RT-4b`.
- **Build tests with `--debug`** (overflow, range and tag checks [D]).

## Definition of done

**tcprouter v1:** every v1 row in doc 05 is `done`, examples build in CI, and the README shows
both modes.

**tcpproxy v1 and the Goose proxy:** Steve's acceptance suite `verify_backends.py` (26 tests in
`~/dev/c_proxy`) talks to the proxy only over sockets and the control protocol. A thin program on
top of tcprouter + tcpproxy that speaks the same CLI flags and control protocol must pass it
unchanged. Until then, the C proxy remains the one Gatekeeper ships.

## Steve's list: what must not go wrong (each has a row)

| Risk | Row |
|---|---|
| A frozen proxy forwards a byte past its deadline | RT-6a |
| Deadline on the wrong clock (suspend) | RT-6c |
| Retry after a client byte was consumed (the client sees garbage) | RT-4c |
| A stale completion touches a reused slot | RT-2b |
| A lease-required tag serving before its first deadline; a backup fenced by a lease | RT-6e, PX-3c |
| Kernel writes into memory that moved | RT-5a/doc 03 §4, O-3 |
| `SO_REUSEPORT` port theft hides bugs | RT-1d, test rule above |
| Drain that never ends | RT-8b |
