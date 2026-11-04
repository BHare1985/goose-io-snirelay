# 02 — Public API

The code below is the **shape** of the API, written as Goose as far as we know it. Syntax that
nobody has compiled is marked `// [verify]`; Brian fixes syntax freely, but a change to the
*shape* (what the caller writes, who owns what, when a call may block) goes back to Charlie.

## 1. Three Goose facts that decide the shape

1. **No stored callbacks.** Function values are compile-time only; a block passed to a function
   can't be kept for later [D]. So `router.add_sni_route("api") { conn => … }` from the user's
   draft can't register a handler. Instead, **routes are data**, and your code runs inside one
   block that the worker loop calls for every event: `serve(w) { ev => … }`.
2. **No coroutines.** A read loop per connection (`while stream.is_open() { stream.read(…) }`)
   needs a thread per connection, capped near 8k by Goose's per-thread stacks [V, goose-kb].
   So handler code is **event-driven**: it is called on open, on data, when writable, on close.
3. **Threads share no memory.** Each `thread_fn` is its own program; values cross only as flat
   messages [D][V]. So each worker builds its own router state from the same config value, and
   changes reach workers as messages (doc 03 §7).

## 2. The pieces

```goose
// One description of what to listen on and where each connection goes. Plain data: build it
// by hand or from a config file, pass it to each worker. Flat, so it can travel in a message.
struct Config {
    listeners: Listener[..16],
    routes: Route[..256],
    limits: Limits = Limits { .. },
}

struct Listener {
    id: u16,                    // yours; events and routes refer to it
    addr: Addr,                 // "0.0.0.0:443", "[::]:8080"; parsed by tcprouter::addr("…")
    inspect: Inspect = Inspect.None,   // None: route by listener only. Sni: read the ClientHello first
}

enum Inspect { None, Sni }                                   // [verify] enum syntax

struct Route {
    listener: u16,
    match: Match,
    action: Action,
}

enum Match {                                                 // [verify] ADT syntax
    Any,                        // every connection on this listener (port routing)
    Sni(name: u8[..253]),       // exact, case-insensitive, trailing dot ignored
    SniSuffix(name: u8[..253]), // "*.example.com" style: any name ending in ".example.com"
    NoSni,                      // a TLS ClientHello without SNI, or not TLS at all
}

enum Action {
    Forward(to: Target),        // the engine connects and copies bytes both ways
    Handle(tag: u16),           // your serve block gets the events, tagged
    Close,                      // close at once
}

struct Target { addrs: Addr[..8] }   // tried in order, round robin across connections (built-in policy)

struct Limits {
    connect_timeout_ms: i64 = 2000,
    idle_timeout_ms: i64 = 300000,
    half_close_timeout_ms: i64 = 30000,
    inspect_timeout_ms: i64 = 5000,    // time allowed for the ClientHello to arrive
    max_conns_per_worker: i64 = 65536,
    buffer_size: i64 = 16384,
    buffers_per_worker: i64 = 4096,
}
```

Routes are checked in order; the first match wins. A listener with `inspect: Sni` waits for the
ClientHello (doc 04), then matches `Sni`, `SniSuffix`, `NoSni`, `Any` rows in config order.
**The ClientHello bytes are not consumed**: a forwarded connection's backend sees the client's
original handshake, byte for byte (RT-3c).

## 3. Running workers

```goose
import tcprouter from "github.com/bhare1985/tcprouter@v0";

thread_fn worker(cfg: tcprouter::Config, index: i64) {           // [verify] thread_fn arguments
    var w = tcprouter::worker(cfg, index);    // binds this worker's listeners (SO_REUSEPORT)
    tcprouter::serve(w) { w, ev => };         // forward-only config: nothing to handle
}

fn main() {
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr("0.0.0.0:5432") });
    cfg.routes.push(tcprouter::Route {
        listener: 1, match: tcprouter::Match.Any,
        action: tcprouter::Action.Forward(tcprouter::target(["10.0.0.5:5432", "10.0.0.6:5432"])),
    });
    tcprouter::check(cfg) or die;             // [verify] error style: rejects bad config with a message
    for i in 4 { thread_spawn(worker, cfg, i); }                     // [verify]
    tcprouter::wait_for_signal_then_drain(30000);   // SIGTERM/SIGINT → drain all workers, 30 s deadline
}
```

- `worker()` binds sockets and returns the worker's state; it fails cleanly (not abort) if a port
  is taken (RT-1d).
- `serve()` runs the loop until the worker is drained or stopped. It calls your block for each
  handler event, on this worker's thread, one event at a time.
- The program decides how many workers; `tcprouter::cpu_count()` is offered as a default.

## 4. Handler mode: your own protocol

```goose
enum Event {
    Opened(conn: Conn, tag: u16, listener: u16, sni: u8[..253]),
    Data(conn: Conn, bytes: const u8[:]),     // valid only inside this call; copy what you keep
    Writable(conn: Conn),                     // your earlier sends have drained below the low mark
    Closed(conn: Conn, why: CloseReason),
    Tick(now_ms: i64),                        // once per loop pass at most every 100 ms: your timers
}

struct Conn { slot: u32, gen: u32 }           // a handle: valid until Closed; stale handles are ignored

// Calls your block may make, on the worker it was called on:
fn send(w: Worker&, c: Conn, bytes: const u8[:]) -> bool   // queues; false if the conn is gone or its
                                                           // queue is full (then wait for Writable)
fn close(w: Worker&, c: Conn)                              // after queued bytes are sent
fn abort(w: Worker&, c: Conn)                              // now, with RST
fn pause_reading(w: Worker&, c: Conn, paused: bool)        // your own backpressure
fn forward(w: Worker&, c: Conn, to: Target)                // hand the conn to the engine's forwarding
                                                           // (only before you consumed any bytes)
```

- **Your per-connection state** lives in your own `slot_pool`, indexed by `c.slot`; check
  `c.gen` to reject a reused slot. tcprouter never stores your state.
- **Output is buffered by the engine** up to a per-connection cap (`limits.buffer_size × 4`);
  `send` returns false at the cap and you get `Writable` when it drains. A server that ignores
  `false` loses data only on that connection, never memory (RT-5e).
- **`Data` is a view** into the engine's buffer. It is gone after your block returns (Goose
  enforces this [D]).

### Example B: the user's draft, rewritten

The draft terminated TLS per SNI with gslib and served HTTP in a blocking loop. The same program
in handler mode (TLS termination is the app's business; gslib's TLS is sans-I/O [D], which is
exactly what an event loop needs: feed it bytes, get bytes back):

```goose
import tcprouter from "github.com/bhare1985/tcprouter@v0";
import gslib from "github.com/SorinS/gslib@main";          // licence unknown: examples only

let API = 1;
let WEB = 2;

struct Session { tls: gslib::tls::Server, inbox: u8[>..], live: bool }  // [verify] gslib types

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var sessions = slot_pool<Session> {};
    var w = tcprouter::worker(cfg, index);
    tcprouter::serve(w) { w, ev =>
        switch ev {                                                       // [verify]
            case Opened(c, tag, _, _):
                sessions.put(c.slot, Session { tls: gslib::tls::server(cert_for(tag)), .. });
            case Data(c, bytes):
                var s .= sessions.items[c.slot];
                s.tls.feed(bytes);                      // ciphertext in
                while let req = next_http_request(s) {  // plaintext requests out
                    tcprouter::send(w, c, s.tls.seal(handle(req)));
                }
            case Closed(c, _):
                sessions.free(c.slot);
            default:
        }
    };
}

fn main() {
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr("0.0.0.0:443"),
                                             inspect: tcprouter::Inspect.Sni });
    cfg.routes.push(tcprouter::sni_route(1, "api.example.com", tcprouter::Action.Handle(API)));
    cfg.routes.push(tcprouter::sni_route(1, "web.example.com", tcprouter::Action.Handle(WEB)));
    cfg.routes.push(tcprouter::Route { listener: 1, match: tcprouter::Match.Any,
                                       action: tcprouter::Action.Close });   // unknown SNI
    for i in 4 { thread_spawn(worker, cfg, i); }
    tcprouter::wait_for_signal_then_drain(30000);
}
```

What changed from the draft, and why: the routes are data, not stored blocks (fact 1); the
handler reacts to `Data` instead of looping on `read` (fact 2); each worker owns its sessions
(fact 3). A plain-HTTP server is the same without the TLS lines, on `inspect: None`.

## 5. Forward mode with a policy (tcpproxy)

The built-in policy behind `Action.Forward(Target)` is deliberately small: round robin across the
target's addresses, retry the next one if a connect fails before any client byte was consumed,
give up after each address was tried once. Anything more (backups, health, deadlines, weights)
is tcpproxy (doc 07), plugged in at compile time:

```goose
var w = tcprouter::worker(cfg, index);
var p = tcpproxy::policy(proxy_cfg, index);
tcprouter::serve(w, p) { w, ev => };          // the engine calls p's functions; see doc 07
```

## 6. Messages to running workers

```goose
tcprouter::post(Message.Drain(deadline_ms: 30000));          // every worker
tcprouter::post(Message.CloseTagged(tag: 7, gen: 3));         // fence: close conns forwarded under tag 7
tcprouter::post(Message.Stats(reply_to: 1));                  // each worker answers with its counters
```

How a message reaches every worker, given one queue per type is shared [V goose-kb], is doc 03 §7.

## 7. Errors

- **Bad config** (`check`): a list of messages, the program decides to exit. Never `abort`.
- **Bind failure**: `worker()` returns an error value naming the address and errno.
- **Peer behaviour** (resets, garbage, timeouts) is never an error to the program: it is a
  `Closed(why)` event and a counter. The engine must never `abort` on anything a peer sends
  (goose-kb rule NEVER-4).
