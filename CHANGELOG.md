# Changelog

## v0.1.0 (2026-11-09)

First release.

* Listeners and one epoll worker per core; routing by port or TLS server name (SNI, read without decrypting); byte-for-byte forwarding with retry before the first client byte,
  half-close, backpressure and fairness; edge-triggered, 99% to 103% of the C proxy's copy engine on throughput except new-connection-per-request (about 91%).
* Handler mode for protocols of your own: `Opened`, `Data`, `Writable`, `Closed` events; `send`, `close`, `reset`, `forward`, `pause_reading`, `set_user`.
* Deadlines, fences and `CloseTagged` by tag in forward and handler mode (no byte after the deadline; the residual window is documented in design/06); drain with a deadline; messages and stats across workers.
* `examples/`: `forward_port`, `sni_router`, `http_hello`, `http_server` (HTTP/1.1, bodies of any size, files, HEAD, pipelining, backpressure; within 25% of the C backend on every benchmark row).
* Docs: `docs/building-an-http-server.md`, `docs/memory.md`, `docs/status.md`, `docs/tls-support.md`, `docs/gatekeeper-next-step.md`.

Not in this release: HTTPS termination (a support check with gslib is in `docs/tls-support.md`), the policy hook and tcpproxy, splice, a graceful TLS close.
Unexplained: an intermittent RT-8c failure (about 1 in 25 looped runs).
