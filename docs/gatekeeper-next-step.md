# Gatekeeper: what tcprouter v0.1.0 offers, and a plan outline if the proxy question is asked

**Replacing the C proxy is not a decided goal; the next Gatekeeper step is in `sprints/sprint-02.md`** (the parked Demo 2, D42, and the control panel, D45/D46/D48; see "Charlie's state" at the end of that file). This file is for the agent who is asked whether tcprouter should replace the C proxy.

**Status of this file:** reviewed by Charlie (corrections applied). Charlie owns the Gatekeeper facts; this file points at them and does not restate them
(reviewer: Charlie, before the v0.1.0 tag). Everything under "What tcprouter v0.1.0 provides" is tcprouter-side and measured or
marked unverified. The agent who writes the actual next-step plan fills section 4 from the sources in section 1.

## 1. Where the Gatekeeper facts are (read these, in this order)

All paths are in the Gatekeeper repository, `docs/` (on the dev host `~/dev/gatekeeper/docs`).

| Read | For |
|---|---|
| `decisions.md`, rows D41 to D48 | the current direction: health engine (D43, D44), control panel (D45, D46, D48), witness (D47), next deliverable (D42) |
| `sprints/sprint-02.md` | what the current sprint demands, acceptance steps, who owns what |
| `18-requirements.md`, section "Routing and proxy (PRX)" | the proxy rows, with their status; the rows a replacement proxy has to keep green |
| `21-design-status.md` | what is built, what is decided but not built, and what is open; the table at the top |
| `23-ui-workflows.md`, `24-panel-design-review.md`, `25-panel-redesign-brief.md`, and `~/dev/gk/docs/openapi.yaml` (in the gk repo, the runtime, not the gatekeeper docs repo; last changed in e988789) | the panel and its API contract (D45, D46, D48) |
| `02-architecture.md` | the witness (D47) |
| `22-health-checks.md` | the check model behind D43 and D44 |
| `~/dev/c_proxy/AGENTS.md`, `verify_backends.py` (26 tests) | the proxy that ships today and the acceptance suite a replacement must pass unchanged |

## 2. What tcprouter v0.1.0 provides (tcprouter facts; each links to its evidence)

| Proxy capability Gatekeeper uses | tcprouter | Evidence |
|---|---|---|
| Port forwarding, SNI routing without terminating TLS, no-SNI and unknown-name rules | built, tested | design/05 RT-3, RT-4; examples/sni_router.goose |
| Retry on the next address, only before a client byte was consumed | built, tested | RT-4c, RT-4d |
| Half-close, backpressure, fairness, flat memory, 10,000 idle connections per worker | **green:** RT-4b (half-close), RT-5a to RT-5e (backpressure), RT-5f (fairness: p99 3.3 ms beside a 1 GB stream), RT-5g (flat memory over 21.5 GB), RT-2a (10,000 idle, 169 bytes each). The 10k figure is for **plain connections only; a TLS session held in the handler costs about 300 kB** | `docs/status.md`, `docs/tls-support.md` |
| Lease deadline per tag, enforced before every write, also after a freeze; close-by-tag; tag starting fenced | built, tested in forward and handler mode | RT-6a, RT-6a-H, RT-6b to RT-6e |
| Drain with a deadline; per-worker stats gathered by message | built, tested | RT-8, RT-10 |
| Throughput and memory against the C proxy | measured: [bench/RESULTS.md](../bench/RESULTS.md) | rows 100% to 103% except one new-connection row at about 91% |
| Backup tiers, first-up policy, passive failure skip (2 s), sessions per server | **not built**: tcpproxy and the policy hook (design/07, `w.serve(policy)`), after v0.1.0 | design/07 rows PX-1 to PX-4 |
| The text control protocol (`show`, `down`, `lease` …), the CLI flags, logging | **not built**: belongs to the Gatekeeper proxy program on top of tcprouter | design/08 |
| Active health checks | not planned in the proxy (D43: the Gatus fork decides) | decisions.md D43, D44 |

**The residual window of the fence,** to be quoted accurately: a pause between the final deadline check and the `send()` syscall
cannot be closed in user space; the lease margin must cover it. design/06-tests-and-gates.md ends with the exact statement.

## 3. What a decision about the proxy needs to know that only tcprouter can say

* The engine is a library: a program is `tcprouter` + policy + control protocol. The C proxy is one C program (`~/dev/c_proxy`).
  What the program would need is listed in design/08 ("Where the C proxy's parts go").
* The Goose proxy is not drop-in until `verify_backends.py` passes unchanged against it (design/06, "tcpproxy v1 and the Goose proxy").
* **HTTPS termination: example only, via gslib** (pinned to a commit, never vendored, licence unstated, O-9); no graceful TLS close yet (G-1, after v0.1.0); ~300 kB per TLS session. See `docs/tls-support.md`. The core does SNI passthrough only.
* Language and toolchain facts that affect operations: Goose is pre-1.0 and tracked at a commit (README); the build needs a C
  compiler; threads need `goose build`; Linux only; no TLS termination in the core.
* Known open items in tcprouter itself are in docs/status.md ("Open"). A release blocker would be listed there.

## 4. If the user asks whether tcprouter should replace the C proxy

Fill from the sources in section 1, answering:
1. Which of Gatekeeper's PRX rows can the tcprouter-based proxy take over, and in what order (ports first? SNI first?).
2. What must exist before it can replace the C proxy in a sprint demo (policy hook, control protocol, `verify_backends.py` green).
3. Who owns each piece. Known: Steve owns `c_proxy` and the gk runtime; Danya owns the testbed; Brian owns tcprouter. **Not decided: who owns the control protocol and tcpproxy** (say so in the plan rather than assuming).
4. What to measure to decide (rows and tools: bench/run_m6.sh, bench/syscalls.py, `verify_backends.py`), and the threshold.
5. What the user must decide (D-number to record it under).

Do not restate decisions: cite their D-numbers.
