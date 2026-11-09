# 07 — tcpproxy (outline; detailed after tcprouter M3)

tcpproxy decides **where** a forwarded connection goes and **whether** a backend may serve.
It has no sockets and no threads: tcprouter's engine asks it, synchronously, on the worker.

## How the engine calls it without callbacks

Goose generics are monomorphized and untyped parameters are generic [D]. So `w.serve(p) {…}`
is compiled once per policy type, and inside it the engine calls plain functions on `p`:

```goose
// What any policy provides (tcprouter's built-in one, tcpproxy's, or a test double): [verify O-1]
fn pick(p: P&, route: u16, conn: Conn, tried: u32) -> Pick      // Pick.To(addr, tag, gen) | Pick.None
fn connect_failed(p: P&, conn: Conn, tag: u16) -> Retry         // Retry.Next | Retry.GiveUp
fn connected(p: P&, conn: Conn, tag: u16)                       // sessions + 1
fn closed(p: P&, conn: Conn, tag: u16, why: CloseReason)        // sessions − 1
fn on_message(p: P&, m: PolicyMessage) -> Effect                 // state changes; may ask for CloseTagged
```

No interface declaration is needed if overload resolution on the generic type works as the docs
describe; that is open question O-1 and Brian's first check before writing tcpproxy.

## What tcpproxy holds (per worker, plain arrays)

```
Group[]   id, name, servers (ids), policy: round_robin | first_up, backup servers (ids)
Server[]  id, addr, state: up | down | degraded | maintenance, tag, deadline_ms (BOOTTIME, 0 = none),
          lease_required, sessions, passive_fail_until_ms
```

## Rules (PX rows)

| id | Behaviour |
|---|---|
| PX-1a | Pick skips servers that are down or in maintenance; prefers up over degraded; backups only when no primary is up |
| PX-1b | Round robin across eligible servers per worker |
| PX-2a | A refused or timed-out connect marks that server "skip" for 2 s (configurable) on this worker and reports the failure upward (D44: the report becomes a Gatus result) |
| PX-2b | Retry the next eligible server until each was tried once |
| PX-3a | `SetState(server, up/down/degraded/maintenance)` takes effect for new connections at the next loop pass |
| PX-3b | `SetDeadline(server, D)` with D absolute on BOOTTIME; never extends past a later-arriving earlier D (RT-6d) |
| PX-3c | A `lease_required` server starts fenced; a backup server is never fenced by a lease |
| PX-3d | `Down` with `cut: true` closes the server's open sessions (via CloseTagged) |
| PX-4 | Sessions per server are exact, summed across workers on request |

Messages come from the program (the Gatekeeper proxy's control socket today, the D44 `gatekeeper`
alert later) through `tcprouter::post`, the same broadcast path as everything else (doc 03 §7).
