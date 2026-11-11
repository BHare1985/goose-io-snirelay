# Building an HTTP server on tcprouter

> **Licence note:** gslib (github.com/SorinS/gslib) has no licence yet, so it is not redistributable. It is fetched at a pinned commit and never vendored here; do not redistribute binaries built with it until it has a licence.

For an agent (or a person) who has to write an HTTP/1.1 server, or any server speaking its own protocol, on tcprouter. Read
this first, then copy [examples/http_server.goose](../examples/http_server.goose); it is complete, tested
(`tests/net/http_server_test.py`, rows RT-12a to RT-12e in [design/05-requirements.md](../design/05-requirements.md)) and
benchmarked against the C backend the proxy benchmarks use. The reference for every call is
[design/02-api.md](../design/02-api.md), section 4.

## What tcprouter gives you, and what it does not

It gives you: listeners, one event loop per core (epoll, edge-triggered for forwarding, level-triggered for handlers), accepting,
a send queue with backpressure, idle timeouts, draining on SIGTERM/SIGINT, and the events `Opened`, `Data`, `Writable`, `Closed`,
`Tick`. It does not parse HTTP. That is your code, and it is about 200 lines (see the example).

## The shape of every handler-mode server

```goose
import tcprouter from "github.com/bhare1985/tcprouter@v0";   // or "../.." inside this repository
import slot_pool;

struct Session { live: bool, inbox: u8[..4096] /* your per-connection state */ }

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var sessions = slot_pool<Session> {};                      // YOUR per-connection state; tcprouter never stores it
    var w = tcprouter::Worker { .. };                          // a root struct: built where it lives
    if !w.start(cfg, index) { print(w.error); return; }        // false if the port is taken; never aborts
    w.serve() { w, ev =>
        match ev {
            Opened o => { let i = sessions.alloc_index(Session { live: true, inbox: [] }); w.set_user(o.conn, i as u32); },
            Data d => { on_data(w, sessions, d.conn, d.user, d.bytes); },
            Writable x => { on_writable(w, sessions, x.conn, x.user); },
            Closed c => { free_session(sessions, c.user); },
            _ => {},
        }
    };
}

fn main() {
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr("0.0.0.0:8080") });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Handle { tag: 1 }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { print(problems); exit(2); }   // every problem, naming its field
    tcprouter::spawn(cfg, tcprouter::cpu_count(), worker);              // one thread per worker; build with `goose build`
    tcprouter::wait_for_signal_then_drain(30000);                       // SIGTERM/SIGINT: stop accepting, finish, exit
}
```

Build it with `goose build` (not `goose run`: threads need the compiled form). The compiler is Goose at the commit named in the
README; a C compiler is needed for the package's one small C file.

## The rules that matter (each one has bitten someone)

1. **Put real code in named functions, never in the `serve` block.** A `return` inside the block returns from the function that
   contains the block, which is your whole `worker`. The block should be a `match` that calls functions.
2. **`d.bytes` in a `Data` event is a view into the engine's buffer.** It is gone when your block returns. Copy what you keep
   (the example appends to `s.inbox`).
3. **`send` is all or nothing.** It returns `false` and queues nothing when the bytes do not fit the send queue (4 buffers, 128 KiB
   at the default 32 KiB buffer). After a `false` you get exactly one `Writable` when there is room. A response that can be
   large must be sent in pieces from state you keep (an offset), the next piece on `Writable`. Never keep a copy "to retry":
   regenerate the piece from the offset. `http_server`'s `send_pieces` is the pattern; it streams 64 MiB in 16 KiB pieces.
4. **Check the `user` id before indexing your pool** (`if user >= sessions.items.len { return; }`). It comes back from the
   engine, but a library that range-checks what crosses a boundary is the point of this one.
5. **`Closed` is always last, exactly once, and tcprouter frees nothing of yours.** Free your session there. After
   `forward()` returns true no `Closed` event follows (you gave the connection away): free it then.
6. **Idle connections are closed after `limits.idle_timeout_ms` (5 minutes by default),** keep-alive included. A server that
   should hold quiet connections longer sets the limit; bytes you send count as activity.
7. **A peer's FIN ends the connection (v1).** There is no half-closed handler connection: after the peer closes its sending
   side, queued output is flushed and the connection is closed. HTTP/1.1 clients that send a request and half-close first
   are not supported in handler mode.
8. **Threads share nothing.** Each worker gets a copy of the globals as they were when it started, and has its own `sessions`.
   State that must be shared across workers goes through `tcprouter::post` messages, not memory.
9. **Names starting with `_` are private** by this project's convention (Goose itself has no privacy). Call the public API as
   methods: `w.send(conn, bytes)`, `w.close(conn)`, `w.set_user(conn, i)`.

## Limits and defaults (all in `tcprouter::Limits`)

| Limit | Default | Meaning |
|---|---|---|
| `buffer_size` | 32 KiB | one pool buffer; the send queue holds 4 |
| `buffers_per_worker` | 4096 | pool size; reads wait for a buffer when it is empty |
| `max_conns_per_worker` | 65,536 | further accepts are closed and counted |
| `idle_timeout_ms` | 300,000 | no bytes either way |
| `inspect_timeout_ms` | 5,000 | time for a TLS ClientHello (SNI listeners) |

Memory you can count on (measured, [bench/RESULTS.md](../bench/RESULTS.md)): an idle worker is about 3 MB; an idle connection costs
the engine a slot (a few hundred bytes) and no buffer; a connection with bytes in flight borrows pool buffers and returns them.
Your `Session` is on top of that: `http_server`'s is about 5 KiB (the 4 KiB inbox).

## HTTPS

Three ways, in order of how much is verified today:

1. **TLS passthrough / routing by name, nothing decrypted: works and is tested** (RT-3). Put tcprouter in front of any TLS
   server: `examples/sni_router.goose` routes by the server name in the ClientHello and forwards the bytes untouched.
2. **Plain HTTP behind a TLS terminator** (nginx, stunnel, HAProxy): `http_server` is the backend.
3. **TLS terminated inside your handler, with gslib's sans-I/O TLS.** A TLS engine written sans-I/O is four byte streams (ciphertext in,
   plaintext out, plaintext in, ciphertext out), which map onto `Data` and `send`. The support check
   ([docs/tls-support.md](tls-support.md), `tests/net/harness/tls_server.goose`) shows TLS 1.2 and 1.3 handshakes, HTTP/1.1 keep-alive, SNI,
   backpressure, a peer that hangs up and the deadline fence working on handler mode. There is **no finished HTTPS server in v0.1.0**, and what
   it does not cover matters:
   * **A graceful TLS close is not supported yet.** The TLS library asks for shutdown-write, read-and-drop until the peer closes or a timeout,
     then close; tcprouter's `close` has no such mode (engine item G-1, after v0.1.0). Closing with unread data can reset the connection before the
     peer has read the alert.
   * **About 300 kB of memory per open TLS session** (measured: 200 sessions, 6,048 to 64,492 kB). The RT-2a figure of 10,000 idle connections
     per worker, at 169 bytes each, is for **plain** connections only.
   * Each `Data` event's bytes are copied once before they go to the TLS engine (candidate engine change F-2, not made).
   * Keep the TLS library out of the tcprouter core. gslib is fetched by the compiler, pinned to a commit, never vendored here; its licence is
     unstated (open question O-9).

## Testing and benchmarking your server

* Correctness: copy `tests/net/http_server_test.py`; every body is checked byte by byte (body[i] = i % 251 is the trick that
  catches reordering and loss; `/N` serves it).
* Load: `wrk -t2 -c64 -d10s http://127.0.0.1:8080/16384`, and `-H "Connection: close"` for a connection per request.
* Against the C backend with the proxy benchmark's own harness and rows: `bench/run_http_server.sh` (see `bench/README.md`).
* Fencing and deadlines (if you use tags): `tests/net/handler_deadline_test.py` shows how to prove that nothing is sent after a
  deadline, including when the worker is stopped in the middle of your handler.

## Checklist before you call it done

- [ ] `goose build` (not `run`), run under `--debug` in tests: it catches overflow and range errors with line numbers.
- [ ] Every `send` result is looked at; a response larger than 64 KiB is streamed.
- [ ] Every index that came from outside (the `user` id, a length in the request, a path) is range-checked.
- [ ] A request cut at every byte position is answered once (see RT-12b); a request over your head limit gets an answer, not a hang.
- [ ] 10,000 idle connections do not change your memory by more than your `Session` size times 10,000.
- [ ] `SIGTERM` finishes in-flight responses and exits (`wait_for_signal_then_drain`).
