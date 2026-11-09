# Gatekeeper: the next step after tcprouter v0.1.0 (STRUCTURE FOR REVIEW)

**Status of this file:** a scaffold. Charlie owns the Gatekeeper facts; this file points at them and does not restate them
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
| `~/dev/c_proxy/AGENTS.md`, `verify_backends.py` (26 tests) | the proxy that ships today and the acceptance suite a replacement must pass unchanged |

## 2. What tcprouter v0.1.0 provides (tcprouter facts; each links to its evidence)

| Proxy capability Gatekeeper uses | tcprouter | Evidence |
|---|---|---|
| Port forwarding, SNI routing without terminating TLS, no-SNI and unknown-name rules | built, tested | design/05 RT-3, RT-4; examples/sni_router.goose |
| Retry on the next address, only before a client byte was consumed | built, tested | RT-4c, RT-4d |
| Half-close, backpressure, fairness, 10,000 idle connections per worker | built; see docs/status.md for which rows are green | RT-4b, RT-5, RT-2a |
| Lease deadline per tag, enforced before every write, also after a freeze; close-by-tag; tag starting fenced | built, tested in forward and handler mode | RT-6a, RT-6a-H, RT-6b to RT-6e |
| Drain with a deadline; per-worker stats gathered by message | built, tested | RT-8, RT-10 |
| Throughput and memory against the C proxy | measured: [bench/RESULTS.md](../bench/RESULTS.md) | rows 100% to 103% except one new-connection row at about 91% |
| Backup tiers, first-up policy, passive failure skip (2 s), sessions per server | **not built**: tcpproxy and the policy hook (design/07, `w.serve(policy)`), after v0.1.0 | design/07 rows PX-1 to PX-4 |
| The text control protocol (`show`, `down`, `lease` …), the CLI flags, logging | **not built**: belongs to the Gatekeeper proxy program on top of tcprouter | design/08 |
| Active health checks | not planned in the proxy (D43: the Gatus fork decides) | decisions.md D43, D44 |

**The residual window of the fence,** to be quoted accurately: a pause between the final deadline check and the `send()` syscall
cannot be closed in user space; the lease margin must cover it. design/06-tests-and-gates.md ends with the exact statement.

## 3. What a decision about the proxy needs to know that only tcprouter can say

* The engine is a library: a program is `tcprouter` + policy + control protocol. The C proxy is one 2,800-line program.
  What the program would need is listed in design/08 ("Where the C proxy's parts go").
* The Goose proxy is not drop-in until `verify_backends.py` passes unchanged against it (design/06, "tcpproxy v1 and the Goose proxy").
* Language and toolchain facts that affect operations: Goose is pre-1.0 and tracked at a commit (README); the build needs a C
  compiler; threads need `goose build`; Linux only; no TLS termination in the core.
* Known open items in tcprouter itself are in docs/status.md ("Open"). A release blocker would be listed there.

## 4. The next-step plan itself (for the agent who writes it)

Fill from the sources in section 1, answering:
1. Which of Gatekeeper's PRX rows can the tcprouter-based proxy take over, and in what order (ports first? SNI first?).
2. What must exist before it can replace the C proxy in a sprint demo (policy hook, control protocol, `verify_backends.py` green).
3. Who owns each piece (Steve: C proxy and its suite; Brian: tcprouter; whoever owns the control protocol and tcpproxy).
4. What to measure to decide (rows and tools: bench/run_m6.sh, bench/syscalls.py, `verify_backends.py`), and the threshold.
5. What the user must decide (D-number to record it under).

Do not restate decisions: cite their D-numbers.
