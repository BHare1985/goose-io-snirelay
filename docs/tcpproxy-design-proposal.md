# tcpproxy: a proposal for how to design and build it on tcprouter

**Status: Brian's proposal for Charlie's review. Not a decision.** `design/` is Charlie's, so this lives in `docs/` and does not change
`design/07-tcpproxy.md` or `design/08-c-map.md`. Where it disagrees with them it says so in section 9. Nothing here is built, and nothing starts
until the user or Charlie says so.

Facts below come from the tcprouter source at v0.1.0, `design/07`, `design/08`, and `~/dev/cnamecloud/c_proxy/AGENTS.md`. I have **not** read
`verify_backends.py`, so the control-protocol details in section 5 are an outline to be checked against it, not a specification.

## 1. What tcpproxy is

A program (one binary, its own repository) that does what the C proxy does for Gatekeeper, built on tcprouter:

- tcprouter already does the sockets: listeners, SNI routing without terminating TLS, copying, half-close, backpressure, timeouts, drain, lease
  deadlines enforced before every write, close-by-tag, per-worker stats.
- tcpproxy adds the **decisions**: which backend a connection goes to, whether a backend may serve, what happens when one fails, and a control
  channel through which Gatekeeper changes those answers while the proxy runs.

tcpproxy has no sockets of its own for data, and no data-path threads. It is plain data and plain functions that the engine calls on its worker.

## 2. Layers

```
Gatekeeper arbiter / agent                (writes commands on the control socket)
        │
tcpproxy program                          main.goose  flags, logging, signals, control thread
        │   commands → Messages posted to every worker
        ▼
tcpproxy policy        policy.goose       groups, servers, pick(), connect_failed(), connected(), closed(), on_message()
        │   called synchronously by the engine, on the worker, via w.serve(policy)
        ▼
tcprouter engine                          sockets, SNI, copy, backpressure, fences, drain, stats
```

Each worker holds its own copy of the policy tables. No locks and no shared mutable state. This is the same share-nothing rule as the C proxy
and as tcprouter itself.

## 3. What tcprouter has to give it (the work in tcprouter first)

One thing is verified, one is a gap, and the rest exists today.

| Needed | State |
|---|---|
| The engine calls plain functions on a generic policy value (`pick`, `connect_failed`, `connected`, `closed`, `on_message`) | Verified as Goose behaviour (O-1, `goose-kb/GOOSE_TEST_PROGRAMS/m0/o156_engine_shape.goose`). **`w.serve(policy)` itself is not built**: today the policy is the built-in rotation over `Config.targets`. This is the first red gate. |
| Retry the next address only before a client byte was consumed | Built (RT-4c, RT-4d). The engine retries, the policy chooses which address and when to give up. |
| Deadlines per tag, enforced before each write, also after a freeze; tag starting fenced; close-by-tag | Built (RT-6a to RT-6e). Targets already carry `tag` and `gen`. |
| Stats gathered by message | Built (RT-10). `Stats` gives per-worker numbers; sessions per server need a per-server counter in the policy, gathered the same way. |
| **Messages that carry an address** | **Gap.** `Message` is fixed at 16 bytes (kind, tag, gen, value) and has four kinds: `Drain`, `Deadline`, `CloseTagged`, `Stats`. An `Addr` is 48 bytes. Setting a server's state or deadline fits; **adding a server or changing its address does not.** See section 6. |
| An SNI-less/handler fallback for the control socket | Not needed: the control socket lives in the program's own thread, not in the engine. |

## 4. The policy: data and rules

Per worker, plain arrays (from `design/07`, unchanged):

```
Group[]   id, name, servers (ids), mode: round_robin | first_up, backup servers (ids)
Server[]  id, addr, state: up | down | degraded | maintenance, tag, deadline_ms (BOOTTIME, 0 = none),
          lease_required, sessions, passive_fail_until_ms
```

Rules are design/07's PX-1a to PX-4 as written. Two points where the implementation needs care:

- **`pick` is pure.** It reads the tables and the clock handed to it, and returns `Pick.To(addr, tag, gen)` or `Pick.None`. No I/O. That makes it
  testable without a socket, which is how most of the PX rows will be tested (a test double for the policy is already part of the O-1 design).
- **The clock is `CLOCK_BOOTTIME`, always.** Deadlines are absolute BOOTTIME milliseconds (RT-6d). A late or duplicate message is harmless
  because the latest deadline wins and a state set twice is the same state. This is why the C proxy's shared atomics can become per-worker tables.

## 5. The program around it

- **Control thread.** Reads the unix control socket (mode 0600), parses a command line, and turns it into `tcprouter::post(...)` calls. The
  workers never see the socket. Commands in the C proxy (to confirm against `verify_backends.py`): `show`, `down`, `up`, `maintenance`,
  `lease NAME IP:PORT|* MS|off`, add/remove servers of an `@NAME` target, `drain`.
- **`show` is a gather.** Post `Stats`, collect the replies, add per-server sessions across workers (PX-4), print. The existing `gather_stats`
  is the pattern.
- **Same protocol as the C proxy.** The goal in `design/08` is that `verify_backends.py` (26 tests) runs unchanged against tcpproxy. That is the
  acceptance test, and also the contract: any command the script uses is in scope, any it does not use is not.
- **CLI and logging** copy the C proxy's flags where the script or Danya's testbed uses them (`--start-down`, `--lease-required`,
  `--cut-on-down`, `--check-to`, `--control`, `--drain-timeout`). Others are left out until someone needs them.
- **DNS.** Not in the proxy (`design/08`): the program resolves names and sends addresses. A small resolver thread that posts address
  messages is enough, and it depends on the message gap in section 3.
- **Drain / reload.** `drain` and SIGUSR1/SIGTERM call tcprouter's drain. A reload is a new process on the same ports (`SO_REUSEPORT`) followed
  by a drain of the old one, the C proxy's model. tcprouter's fixed listener set already fits it.

## 6. The one real design question: changing servers at runtime

The C proxy changes addresses with shared atomics. tcprouter workers share nothing, so every change has to arrive as a message. Three ways:

| Option | What | Cost |
|---|---|---|
| **A. Wider messages (recommended)** | Raise `_MESSAGE_SIZE` from 16 to 64 bytes and add a `SetAddr { target, slot, text }` kind. A pipe write up to `PIPE_BUF` (4096 bytes on Linux) stays atomic, so the "each worker receives it once" guarantee (RT-10a) holds. | Additive change in tcprouter; Charlie approves it as API. Existing tests keep passing. |
| B. A shared append-only address table | The program writes the address into a table all workers can read, then posts only an index. | Breaks share-nothing; needs atomics Goose threads do not offer without C. Rejected. |
| C. No runtime address changes | Only state and deadlines are dynamic; an address change is a reload (new process, drain the old). | Zero tcprouter change. Fine **if** Gatekeeper rarely changes addresses; wrong if its agent adds and removes backends often. |

Recommendation: build the state/deadline commands first (they need no tcprouter change), and take option A to Charlie **only if** `verify_backends.py`
or the testbed shows that add/remove-at-runtime is used. Start with C and let the evidence decide.

## 7. Build order, each step red-gated

Same process as tcprouter: write the failing test first, commit each step with the PX rows it moves and the library line counts.

| Step | Output | Rows |
|---|---|---|
| 1. The policy hook | `w.serve(policy)` in tcprouter with the built-in rotation as the default policy; a test-double policy proving the engine calls `pick`, `connect_failed`, `connected`, `closed`. All 30 existing test files stay green. | new row(s) for the hook |
| 2. The policy tables and `pick` | `policy.goose` in the new repo, pure, tested with no sockets: PX-1a, PX-1b, PX-2b | PX-1a/b, PX-2b |
| 3. Passive failure | `connect_failed` marks a server skipped for 2 s on this worker, with a report callback for D44 | PX-2a |
| 4. State and deadlines by message | `SetState`, `SetDeadline` through the existing `Deadline` kind where it fits; lease_required starts fenced; backup never fenced by a lease | PX-3a to PX-3c |
| 5. Cut on down | `Down` with `cut` posts `CloseTagged` | PX-3d |
| 6. Sessions per server | counters bumped in `connected`/`closed`, gathered on `show` | PX-4 |
| 7. The program | flags, control thread, `show`, drain, logging | design/08 |
| 8. Acceptance | `verify_backends.py` unchanged, then `proxybench.sh` against the C proxy | the 25% rule |
| 9. Only if needed | option A (wider messages) and DNS re-resolution | (decide on evidence) |

Steps 1 to 6 are the library-sized work. I expect tcpproxy to be a small fraction of tcprouter's 2,126 lines, since the engine holds the
complexity, but that is an estimate, not a measurement.

## 8. Test and performance plan

- Policy rules: unit tests with no sockets (step 2 to 6), fast and deterministic.
- Engine behaviour with a policy: tcprouter's existing network harness, extended with a policy test double.
- Fences: the two 100-run gates (alone and under load) from RT-6a-H are repeated with tcpproxy's lease path.
- Acceptance: `verify_backends.py`, `verify_sni.py`, then `proxybench.sh` through `~/dev/cnamecloud/testbed/tools/run-locked.sh` against the C proxy. The pick
  adds a few array reads per new connection; forwarding already runs at about 100% of C and new-connection at about 91%, so the budget is the
  25% rule with room to spare. I would measure it rather than assume it.

## 9. Where this differs from design/07 and design/08, and what I do not know

- **Differs:** nothing in the rules. It adds section 6 (the message-width gap), which `design/07` does not mention ("`SetState`... through
  `tcprouter::post`, the same broadcast path") and which does not hold for addresses today.
- **Does not know:** the exact command set and replies of the C proxy's control protocol; whether Gatekeeper's agent adds or removes servers at runtime; whether
  Danya's testbed needs flags beyond the list in section 5; the D44 report format (a callback or a message, and to whom). Each is a question for
  Steve or Charlie before step 7.
- **Packaging:** a separate repository importing `github.com/bhare1985/tcprouter@v0`, so tcprouter stays an independent, generic release with no
  Gatekeeper words in it. Gatekeeper-specific names (`lease`, `fence`) stay in tcpproxy; tcprouter exposes only tags, deadlines and close-by-tag.
