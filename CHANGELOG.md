# Changelog

## v0.2.0 (unreleased until the RT-6f load gate passes)

For tcpproxy and Gatekeeper. The API additions are small; **every policy type must now define `on_message`, and every `Pick.To` needs `connect_ms`.**

* Policy hook `w.serve(policy)`: `pick`, `connect_failed`, `connected`, `closed`, `on_message` (RT-13a to RT-13k). Policy calls are queued and made between event batches.
* `Message` is 64 bytes. New messages: `ReplaceDeadline` (exact deadline; 0 = unfenced, RT-6f), `SetAddr` (RT-10c), `Policy` (RT-13g to RT-13j; a Stats reply is ordered behind earlier Policy messages).
* A full deadline table fails closed: the 65th tag, and every tag without an entry, is fenced (RT-6g). The deadline table, `Config.fenced_tags` and `Stats.tags` hold 64 tags (were 16, and a 17th deadline was dropped silently).
* `Pick.To.connect_ms`: a connect timeout per pick (RT-13k).
* `wait_for_signal() -> i32` (SIGTERM, SIGINT and SIGUSR1) and `drain(deadline_ms) -> i64` (sessions closed at the deadline); `wait_for_signal_then_drain` is a wrapper (RT-8d, RT-8e).
* Licence: `MIT OR Apache-2.0`.

**Known issues** (not understood; full suite on this code: 35 of 37 test files pass):
* `drain_test` RT-8c "SIGTERM closes the listener at once": fails about 1 run in 25. Next item after the tag.
* `tls_support_test` fence check: once in a full run the stream ended before the deadline (0 late bytes, the safe direction).

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
