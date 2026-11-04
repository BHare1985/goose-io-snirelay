# 02 — Public API

The code below is the **shape** of the API, written as Goose as far as we know it. Syntax that
nobody has compiled is marked `// [verify]`; Brian fixes syntax freely, but a change to the
*shape* (what the caller writes, who owns what, when a call may block) goes back to Charlie.

**Status (Brian, 2026-11-04):** the types and signatures below now compile: they are in `config.goose`
and `engine.goose` (engine functions are stubs), and the three programs in `examples/` build against
them. Syntax differences from draft 1, all verified: enum payloads are struct-like (`Sni { name: … }`)
and read with `match ev { Opened o => o.conn, … }`; there is no `switch`, `while let` or `or die`;
`match` is a keyword, so `Route.match` is `Route.on`; a root struct cannot be returned, so
`worker()` became `Worker { .. }` plus `start()`; thread workers are started by `spawn`.

## 1. Three Goose facts that decide the shape

1. **No stored callbacks.** Function values are compile-time only; a block passed to a function
   can't be kept for later [D]. So `router.add_sni_route("api") { conn => … }` from the user's
   draft can't register a handler. Instead, **routes are data**, and your code runs inside one
   block that the worker loop calls for every event: `serve(w) { w, ev => … }`.
2. **No coroutines.** A read loop per connection (`while stream.is_open() { stream.read(…) }`)
   needs a thread per connection, capped near 8k by Goose's per-thread stacks [V, goose-kb].
   So handler code is **event-driven**: it is called on open, on data, when writable, on close.
3. **Threads share no memory.** Each `thread_fn` is its own program; values cross only as flat
   messages [D][V]. So each worker builds its own router state from the same config value, and
   changes reach workers as messages (doc 03 §7).

## 2. The pieces (config.goose)

Plain data. Build it by hand or from a file, `check()` it, pass the same value to every worker.
It is flat (no references), so it travels as a `thread_fn` argument: a config with 256 routes is
about 66 KB and copies fine [V m0/o24].

```goose
struct Addr { text: u8[..64] }          // "0.0.0.0:443", "[::]:8080"; parsed at start(), checked by check()
fn addr(text: const u8[:]) -> Addr
struct Target { addrs: Addr[..8] }      // tried in order, first choice rotating (built-in policy)
fn target(names: const u8[:][:]) -> Target

enum Inspect { None, Sni }              // None: route by listener only. Sni: read the ClientHello first
struct Listener { id: u16, addr: Addr, inspect: Inspect = Inspect.None }

enum Match {
    Any,                                // every connection on the listener (port routing)
    Sni { name: u8[..253] },            // exact, case-insensitive, trailing dot ignored
    SniSuffix { name: u8[..253] },      // "example.com": any name ending in ".example.com"
    NoSni,                              // a ClientHello without server_name, or not TLS at all
}
enum Action {
    Forward { to: Target },             // the engine connects and copies bytes both ways
    Handle { tag: u16 },                // your serve block gets the events, with this tag
    Close,                              // close at once
}
struct Route { listener: u16, on: Match, action: Action }     // `match` is a Goose keyword

struct Limits {
    connect_timeout_ms: i64 = 2000,   idle_timeout_ms: i64 = 300000,
    half_close_timeout_ms: i64 = 30000,   inspect_timeout_ms: i64 = 5000,
    max_conns_per_worker: i64 = 65536,    buffer_size: i64 = 16384,    buffers_per_worker: i64 = 4096,
}
struct Config { listeners: Listener[..16], routes: Route[..256], limits: Limits = Limits { .. } }

fn sni_route(listener: u16, name: const u8[:], action: Action) -> Route    // table-like constructors
fn any_route(listener: u16, action: Action) -> Route
fn check(cfg: Config, problems: u8[>..]&) -> bool   // appends one line per problem, naming the field
```

Routes are checked in order; the first match wins. A listener with `inspect: Sni` waits for the
ClientHello (doc 04), then matches `Sni`, `SniSuffix`, `NoSni`, `Any` rows in config order.
**The ClientHello bytes are not consumed**: a forwarded connection's backend sees the client's
original handshake, byte for byte (RT-3c).

## 3. Running workers (engine.goose, examples/forward_port.goose)

```goose
import tcprouter from "github.com/bhare1985/tcprouter@v0";

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var w = tcprouter::Worker { .. };               // a root struct: created where it lives
    if !tcprouter::start(w, cfg, index) {           // binds this worker's listeners (SO_REUSEPORT)
        print("worker ", index, ": ", w.error);     // names the address and errno; never an abort
        return;
    }
    tcprouter::serve(w) { w, ev => };               // forward-only config: nothing to handle
}

fn main() {
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr("0.0.0.0:5432") });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward {
        to: tcprouter::target(["10.0.0.5:5432", "10.0.0.6:5432"]),
    }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { print(problems); exit(2); }

    tcprouter::spawn(cfg, tcprouter::cpu_count(), worker);       // creates the message pipes, then the workers
    tcprouter::wait_for_signal_then_drain(30000);   // SIGTERM/SIGINT → drain all workers, 30 s deadline
}
```

- `Worker` is a **root struct** because it owns several growable tables; Goose cannot return a
  root from a function [V], hence `Worker { .. }` plus `start()`. A root also cannot contain a
  `slot_pool`, so the engine keeps its own slot table inside it.
- `start()` returns false and fills `w.error` if a port is taken (RT-1d). It never calls `abort`.
- `serve()` runs the loop until the worker is drained or stopped. It calls your block for each
  handler event, on this worker's thread, one event at a time. The block receives the worker.
- `spawn(cfg, n, worker)` takes the `thread_fn` as its last argument (a function value, compile
  time only [V]). It creates one pipe per worker **before** spawning, because globals set in `main`
  are copied into each worker at spawn and `start()` picks its own pipe end from that copy [V,
  m0 O-2]. The user never touches a pipe.
- The program decides how many workers; `tcprouter::cpu_count()` is offered as a default.
- **A `return` inside a serve block returns from the enclosing function** (here: the whole
  worker), not from the block [D]. Put real handler code in a function of its own (as
  `examples/http_hello.goose` does) and call it from the block.

## 4. Handler mode: your own protocol (examples/http_hello.goose)

```goose
struct Conn { slot: u32, gen: u32 }           // a handle: valid until Closed; stale handles are ignored

enum Event {
    Opened { conn: Conn, tag: u16, listener: u16, sni: u8[..253] },
    Data { conn: Conn, user: u32, bytes: const u8[:] },    // bytes valid only inside this call; copy what you keep
    Writable { conn: Conn, user: u32 },       // your earlier sends have drained below the low-water mark
    Closed { conn: Conn, user: u32, why: CloseReason },    // always last, exactly once
    Tick { now_ms: i64 },                     // at least every 100 ms: your timers
}

// Calls your block may make, on the worker it was called on:
fn send(w: Worker&, c: Conn, bytes: const u8[:]) -> bool   // queues; false if the conn is gone or its
                                                           // queue is full (then wait for Writable)
fn close(w: Worker&, c: Conn)                              // after queued bytes are sent
fn reset(w: Worker&, c: Conn)                              // now, with RST (not `abort`: that name
                                                           // would hide Goose's builtin inside the namespace)
fn set_user(w: Worker&, c: Conn, user: u32)                // your own id for this conn, returned in later events
fn user(w: Worker&, c: Conn) -> u32
fn pause_reading(w: Worker&, c: Conn, paused: bool)        // your own backpressure
fn forward(w: Worker&, c: Conn, to: Target) -> bool        // hand the conn to the engine's forwarding;
                                                           // false (nothing done) once a byte was consumed
```

- **Your per-connection state** lives in your own `slot_pool`. On `Opened`, allocate from it and
  `set_user(w, c, index)`; every later event carries that `user` (a `slot_pool` picks its own index,
  so the engine's `c.slot` can't key yours). tcprouter never stores your state, only the u32.
  Per-connection growable state can't be a pool element (resizable elements are rejected [V]): use
  `u8[..N]` or a `slice_pool` run. Check a `user` id against the pool's length before indexing.
- **Output is buffered by the engine** up to a per-connection cap (`limits.buffer_size × 4`);
  `send` returns false at the cap and you get `Writable` when it drains. A server that ignores
  `false` loses data only on that connection, never memory (RT-5e).
- **`Data` is a view** into the engine's buffer. It is gone after your block returns (Goose
  enforces this [D]).

### Example B: the user's draft, rewritten

`examples/http_hello.goose` is a complete, building plain-HTTP keep-alive server in handler mode;
it is the program RT-9b measures. The user's draft added TLS termination per SNI with gslib. In
handler mode that is the same program with a sans-I/O TLS session per connection (gslib's TLS is
sans-I/O [D]: feed it bytes, get bytes back), and `Inspect.Sni` plus one `sni_route(…, Action.Handle
{ tag })` per name so that the tag selects the certificate. gslib's licence is unknown (O-9) and its
types are unverified, so the TLS variant is described here and not built; the shape it needs is
exactly what `http_hello` already uses: `set_user` for the session, `Data` in, `send` out, `Closed`
to free.

What changed from the draft, and why: the routes are data, not stored blocks (fact 1); the
handler reacts to `Data` instead of looping on `read` (fact 2); each worker owns its sessions
(fact 3). A plain-HTTP server is the same without the TLS lines, on `inspect: None`.

## 5. Forward mode with a policy (tcpproxy)

The built-in policy behind `Action.Forward { to }` is deliberately small: round robin across the
target's addresses, retry the next one if a connect fails before any client byte was consumed,
give up after each address was tried once. Anything more (backups, health, deadlines, weights)
is tcpproxy (doc 07), plugged in at compile time. Verified to work [V m0 O-1]: the engine calls
`p.pick(…)` on its generic parameter, resolved in the policy type's namespace.

```goose
var w = tcprouter::Worker { .. };
var p = tcpproxy::policy(proxy_cfg, index);        // a root struct too, if it owns several tables
if !tcprouter::start(w, cfg, index) { return; }
tcprouter::serve(w, p) { w, ev => };               // the engine calls p's functions; see doc 07
```

## 6. Messages to running workers

```goose
enum Message {
    Drain { deadline_ms: i64 },
    CloseTagged { tag: u16, gen: u32 },    // fence: close conns forwarded under tag, route generation <= gen
    Stats { reply_to: u16 },
}
fn post(m: Message)                        // every worker receives it once
```

How a message reaches every worker, given one queue per type is shared [V]: a pipe per worker
(doc 03 §7; verified, m0 O-2). `post` is called from `main` or from a thread that was started after
`spawn`; its pipe ends are globals copied at spawn.

## 7. Errors

- **Bad config** (`check`): one line per problem appended to your buffer, naming the field; the
  program decides to exit. Never `abort`.
- **Bind failure**: `start()` returns false and `w.error` names the address and errno.
- **Peer behaviour** (resets, garbage, timeouts) is never an error to the program: it is a
  `Closed { why }` event and a counter. The engine must never `abort` on anything a peer sends
  (goose-kb rule NEVER-4).
