# Can tcprouter carry gslib's TLS? A support check (not a finished HTTPS server)

> **Licence note:** gslib (github.com/SorinS/gslib) is now Apache-2.0 upstream (LICENSE added in its commit 84ac839; verify the commit you pin contains it). It is fetched at a pinned commit and never vendored here.

**Decision (the user's):** TLS termination will use **gslib** (`github.com/SorinS/gslib`), pure Goose, sans-I/O. This page records only whether
tcprouter gives it what it needs. It is not an HTTP router and `examples/http_server` stays minimal; small details come later.
**Licence: unstated** by gslib (no LICENSE file, README names only MPL 2.0 for its bundled suffix list). Open question O-9 stays open;
tcprouter does **not vendor** gslib. The compiler fetches it into `~/.goose/pkg` when a program imports it, pinned to a full commit
(`714f87b387f2f9de6a4c7a77d9abc9db2516ee80`; gslib has no tags, and a short hash cannot be fetched).

Evidence: `tests/net/harness/tls_server.goose` (a handler-mode server: Data events into `tls::server_feed`, its output into `send`) and
`tests/net/tls_support_test.py` (Python `ssl` as the independent client; needs `openssl` for a throw-away EC P-256 certificate). 14 checks,
run four times, all passed. Built with `goose 751794c`; gslib asks for a newer Goose commit (`683ebc94`) than our checkout can name, but it
compiles and runs (only warnings, inside gslib).

## Support matrix

| Need | Result | Evidence / note |
|---|---|---|
| TLS 1.3 server handshake driven by Data events and `send()` | **works** | handshake completes, `version() == TLSv1.3` |
| TLS 1.2 server handshake, same way | **works** | `version() == TLSv1.2` (ECDHE-ECDSA, one P-256 certificate) |
| One HTTP/1.1 request and response over it | **works** | both versions |
| Keep-alive: several requests on one TLS connection, bodies 3 B to 100 kB | **works** | exact bytes, both versions |
| SNI visible to the server | **works** | gslib keeps the name in `Conn.sni`; the server echoed `a.test`. (tcprouter's own SNI parse is for routing without decrypting; here the TLS engine reads it itself) |
| Backpressure: a 20 MB response to a reader that stops | **works** | the handler pushes in 32 KiB pieces, stops when `send` says no, resumes on `Writable`, and `pause_reading` while stalled; another session was served meanwhile; all bytes arrived in order |
| Peer hangs up mid-response | **works** | session freed by the Closed event (`/live` counted 1) |
| Fence: deadline passes while a TLS session streams | **works** | no byte after the deadline (last read 1 to 2 ms before it); closed as Fenced. The residual window in design/06 applies unchanged |
| Several certificates / choosing a certificate by SNI | **untested** | the test used one certificate (the scope); gslib's `ServerConfig` has one chain and key, so choosing by name would be the caller's job |
| ALPN | **untested** | the server offers `http/1.1`; the client did not check the result |
| Graceful TLS close (close_notify then FIN) | **untested** | the harness closes with `w.close` after the alert/bytes are out; gslib's README asks for shutdown-write, drain, then close, which tcprouter has no call for (see gap G-1) |
| Client certificates, resumption, KeyUpdate, HTTP/2, ECH | **untested** | not needed for this check |
| Request larger than one Data event / TLS record split across Data events | **untested** (small requests only) | gslib reassembles records by design |
| Many sessions | **gap, see G-3** | about 299 kB resident per open session in the harness |

## Gaps, written as what tcprouter would need (not as workarounds in gslib)

* **G-1: close with a lingering read.** A TLS server that has sent an alert should shut down writing, keep reading and dropping what the peer
  sends until it closes or a timeout, and only then close (otherwise unread data turns the close into an RST that can beat the alert). tcprouter's
  `close` closes after the queue is out; there is no half-close for handler connections (shutdown(SHUT_WR) without closing) and no "drain then
  close" mode. An engine change to consider: `close_after_drain(conn, timeout_ms)` or `shutdown_write(conn)` with the existing idle timeout.
  Not exercised by the test (a failed handshake would show it); status unverified.
* **G-2 (candidate, F-2): the bytes of a Data event cannot be passed to gslib without a copy.** The compiler cannot show that the event's slice
  does not point into a global that gslib's code shrinks (`SYSTEM_ROOTS`), so the harness copies each Data into a local first. One extra copy of
  the received bytes per event. Possible engine-side fix: a Data event whose bytes the compiler can see are not static data. Not changed.
* **G-3: memory per session.** One open session costs about 299 kB resident in the harness (measured: 200 sessions, 6,048 to 64,492 kB). Of that the harness's
  own `pend` (64 KiB) and `req` (4 KiB) are about 68 kB; the rest is gslib's `tls::Conn`, a fixed-size struct (not measured separately). tcprouter's
  10,000-idle-connections target (RT-2a, 169 bytes each) does not hold for TLS sessions held in a `slot_pool`; a pool of a few hundred active
  sessions is fine. A growable-per-session design is not available (see F-1).
* **F-1 (a Goose rule, no engine change):** a `slot_pool` item cannot hold any growable array, so a handler's per-connection output queue must be a fixed array.
  `Session.pend` is 64 KiB for that reason; an oversized flight (a long certificate chain) closes the session.
* **F-3 (docs):** tls_server must not declare `namespace` (then `main` is not global); `CONFIG = copy(sc)`; the listen address must be an owned copy, not a slice
  of argv, before a global is assigned.

## What this does not claim

No HTTPS server exists in v0.1.0. TLS 1.2 and 1.3 are what gslib states; the check ran both with one EC certificate. No cipher-suite, interoperability
(beyond Python `ssl`), performance or security review of gslib was done. The licence is unstated.
