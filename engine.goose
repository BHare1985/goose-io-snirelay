// The engine's public face: workers, events, and the calls a handler block may make
// (design/02-api.md sections 3 to 6). STUBS: every function has its final signature and no
// behaviour yet; the tests that prove each row make them real.
namespace tcprouter;

import .config;

// --- connections and events ---------------------------------------------------------------------

// A handle to one connection. Valid until its Closed event; a stale handle is ignored, never
// reaches the connection that now uses the slot (RT-2b).
struct Conn { slot: u32, gen: u32 }

enum CloseReason {
    PeerClosed, PeerReset, IdleTimeout, HalfCloseTimeout, InspectTimeout, ConnectFailed,
    Fenced, Drained, ByHandler, Error,
}

// What your serve block is called with. Read it with `match`.
enum Event {
    // A connection routed to Action.Handle(tag). `user` is 0 until you set_user.
    Opened { conn: Conn, tag: u16, listener: u16, sni: u8[..253] },
    // Bytes from the peer. `bytes` is a view into the engine's buffer: valid only inside this call.
    Data { conn: Conn, user: u32, bytes: const u8[:] },
    // Your earlier sends have drained below the low-water mark; send again.
    Writable { conn: Conn, user: u32 },
    // Always the last event of a connection, exactly once.
    Closed { conn: Conn, user: u32, why: CloseReason },
    // At least every 100 ms while the worker runs: your timers.
    Tick { now_ms: i64 },
}

// --- the worker ---------------------------------------------------------------------------------

// One event loop and everything it owns. A root struct: create it where it lives, then start it.
//     var w = tcprouter::Worker { .. };
//     if !tcprouter::start(w, cfg, index) { print(w.error); return; }
root struct Worker {
    error: u8[..200] = [],             // why start() returned false
    index: i64 = 0,
    tr_slots: tr_Slot[>..] = [],
    tr_free: u32[>..<] = [],
}

struct tr_Slot { gen: u32, live: bool }

// Binds this worker's listeners (SO_REUSEPORT) and prepares its tables. Returns false and fills
// w.error (naming the address and errno) instead of aborting when it cannot, e.g. the port is
// taken (RT-1d). Never calls abort or exit (RT-1e).
fn start(w: Worker&, cfg: Config, index: i64) -> bool {
    return true;
}

// Runs the loop until the worker has drained or been stopped, calling your block once per event,
// on this worker's thread, one at a time. The block gets the worker so it can call send, close...
// Forward-only configs pass an empty block.
fn serve<F>(w: Worker&) {
    let e: Event = Event.Tick { now_ms: 0 };    // STUB: one event, so the block is type-checked
    F(w, e);
}

// As serve, with a policy deciding where forwarded connections go (tcpproxy, design/07).
fn serve<P, F>(w: Worker&, p: P&) {
    let e: Event = Event.Tick { now_ms: 0 };
    F(w, e);
}

// --- calls a handler block may make (on the worker it was called on) -----------------------------

// Queues bytes to the peer. False if the connection is gone or its output queue is full; in the
// second case wait for Writable. Never blocks, never grows memory past the per-connection cap (RT-5e).
fn send(w: Worker&, c: Conn, bytes: const u8[:]) -> bool { return false; }

// Closes after the queued bytes are sent.
fn close(w: Worker&, c: Conn) {}

// Closes now with an RST. (Named `reset`, not `abort`, which would hide Goose's builtin here.)
fn reset(w: Worker&, c: Conn) {}

// Your own id for this connection, returned in every later event. tcprouter stores only the u32.
fn set_user(w: Worker&, c: Conn, user: u32) {}
fn user(w: Worker&, c: Conn) -> u32 { return 0; }

// Stops or resumes reading from the peer: your own backpressure.
fn pause_reading(w: Worker&, c: Conn, paused: bool) {}

// Hands the connection to the engine's forwarding. Only before any byte was consumed; returns
// false (and does nothing) afterwards (RT-4e).
fn forward(w: Worker&, c: Conn, to: Target) -> bool { return false; }

// --- running workers and talking to them --------------------------------------------------------

// Starts `n` workers, each running `worker(cfg, index)`. It first creates one message pipe per
// worker; each worker's start() finds its own end in a global copied to it at spawn.
//     tcprouter::spawn(cfg, 4, worker);
// `worker` is a thread_fn with the signature (cfg: Config, index: i64). Returns the thread ids.
fn spawn<W>(cfg: Config, n: i64) -> i64[>..] {
    var ids: i64[>..] = [];
    for i in n { ids.push(thread_spawn(W, cfg, i)); }
    return ids;
}

// A sensible default for the number of workers: the CPUs this process may use.
fn cpu_count() -> i64 { return hardware_threads(); }

enum Message {
    Drain { deadline_ms: i64 },
    CloseTagged { tag: u16, gen: u32 },
    Stats { reply_to: u16 },
}

// Sends a message to every worker; each receives it once (RT-10a).
fn post(m: Message) {}

// Blocks the calling thread until SIGTERM or SIGINT, then drains every worker with a deadline
// (RT-8c). Call it from main, after spawn.
fn wait_for_signal_then_drain(deadline_ms: i64) {}

// --- checking a config --------------------------------------------------------------------------

// Appends one line per problem, naming the field, to `problems`; returns true when there is none
// (RT-1c). Never aborts.
fn check(cfg: Config, problems: u8[>..]&) -> bool { return true; }
