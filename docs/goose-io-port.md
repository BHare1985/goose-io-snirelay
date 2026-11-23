# Adopting the epoll event loop in tcprouter

> Done: tcprouter runs on goose-io as [goose-io-tcpproxy](https://github.com/BHare1985/goose-io-tcpproxy), a library beside `epoll_ext::Loop`. This page is the plan it was made from; what the port found is in `openspec/specs/router-on-goose-io/spec.md` and `openspec/changes/archive/2026-11-23-epoll-event-loop-dogfood/design.md`.

For the project that refactors tcprouter onto goose-io. Nothing here changes tcprouter; it says where tcprouter's code now lives in
goose-io-epoll (the loop) and goose-io-epoll-ext (the loop with forwarding added back), what was left behind, and
what that project has to keep true.

## Where tcprouter's files went

tcprouter is read at `e021769` (`bench/BASELINE.md`). The loop was made by taking its generic layer, deleting the proxy, and moving what
was left to the contract's names; the proxy's forwarding was added back in a copy.

| tcprouter | Here | What happened to it |
|---|---|---|
| `engine.goose`: `Worker`, `serve`, `Stats`, `spawn` | goose-io-epoll's `engine.goose` (`Loop`, `serve`, `Stats`), `messages.goose` (`spawn`) | `Conn` is `goose_io::Link`; an `Event` carries its link and nothing attached (no `tag`, no `user`); `Opened` names the `Listener` |
| `handler.goose`: `send`, `dial`, `close`, `reset`, `pause_reading`, `shutdown_write`, `set_keep_open_on_eof`, `send_room`, `want_pass_end` | `engine.goose` | `send` returns `SendStatus`; `send2`, `peer_address`, `listen`, `listener_port`, `stop_listening`, `tick_by` and `stop` are new; `PassEnd` is always on |
| `conn.goose`: slots, buffer pool, accept, interest, close | `engine.goose` | a slot is freed after its `Closed` is handled; `close` no longer resets a link with unread input |
| `conn.goose`: `_pump`, `_pump_direction`, `_write_buffer`, `_run_ready`, `_connect_finished`, the forwarding arm of `_dispatch_event` | goose-io-epoll-ext's `forward.goose` | copied with a fixed target and no routing, no retry, no policy, no tags; **owner review before this is pushed** |
| `messages.goose`: drain, statistics | `messages.goose` | kept; deadlines, close-by-tag, `SetAddr` and `Policy` messages are not carried |
| `address.goose`, `sys.goose`, `src/c_sys.c` | `address.goose`, `sys.goose`, `src/sys.c` | port 0 for `listen`; `c_peek` and `c_set_rcvlowat` (SNI) dropped; `c_local_port`, `c_peer` and `c_linger0` added |
| `config.goose`: `Limits` | `config.goose` | the proxy's limits dropped (`inspect_timeout_ms`); `buffers_per_worker` is `buffers_per_loop`, `max_conns_per_worker` is `max_links` |
| `route.goose`, `sni.goose`, `policy.goose`, `check.goose`, routes, targets, listeners and the SNI inspection and retry of `conn.goose` (`_inspect_connection`, `_route_and_connect`, `_start_connecting`, `_attempt_connect`, `_connect_failed`, `_send_hello`, `_commit_hello`, `_early_end`), tags and deadlines (`_tag_allows`, `_close_tagged`, `_enforce_deadlines`) | not carried | these are the proxy; the project moves them on top of the loop |

## What the project starts from

goose-io-epoll-ext's `forward.goose` is the forwarding pump living in the loop's own links and slot table: a forwarded link
takes a slot, is registered with epoll once (edge-triggered), and has no `Opened` and no `Closed` (the application is not told about it).
It holds tcprouter's forwarding numbers on the workloads of `bench/gate_forward.sh` (see `bench/results/forward-*.txt`): that is the
evidence that the loop's structure costs a proxy nothing. The loop has **no extension seam**: the owner asked for the proxy to be added
back to a copy of the loop, not plugged into it through hooks, so the project's first decision is where the proxy layer goes (a copy as
here, or hooks of its own); the loop's `serve` and `_dispatch_event` are the two places the pump enters.

Routes, SNI inspection, retry, tags and deadlines have to be added on top, and tcprouter's own tests (its `tests/unit` and `tests/net`)
are the judge of that: the loop's tests (its network tests, the conformance suite) never exercised them.

## The gates the project holds

- the conformance suite on the loop it builds, if it keeps the contract's handler path (goose-io-epoll's `conformance.sh --repeat 50`)
- the system calls per request of `bench/gate_syscalls.sh` and `bench/gate_forward.sh` equal to the baseline's
- throughput, p99 latency and CPU per request of `bench/gate_http.sh` and `bench/gate_forward.sh` within or better than tcprouter's own range
- memory of `bench/gate_memory.sh`: no more than tcprouter's, and at most 512 bytes per idle link
- tcprouter's own test suite and `bench/verify.py` (correctness through the proxy) against what it builds

## The fallback

If the refactor cannot hold a number, tcprouter keeps its engine and this loop stays what it is: a loop for libraries, a few percent faster
and lighter than tcprouter's handler path on the same program (`bench/results/`). Nothing in tcprouter depends on this repository.
