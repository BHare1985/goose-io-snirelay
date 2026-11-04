// The engine's public face: workers, events, and the calls a handler block may make
// (design/02-api.md sections 3 to 6). Forwarding is real as of M2; handler mode, timeouts, drain,
// tags and messages are still stubs and are marked STUB.
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

// --- stats ---------------------------------------------------------------------------------------

// A snapshot of one worker's counters (design/03-engine.md section 9). Flat. Read it on the worker's
// own thread, for example from a Tick event; nothing is shared between workers, so there is no lock.
// (Sessions per tag arrive with tags in M4.)
struct Stats {
    accepted: i64,            // connections accepted
    open: i64,                // connections open now
    closed: i64[10],          // connections closed, by CloseReason in declaration order
    bytes_in: i64,            // client to server, forwarded
    bytes_out: i64,           // server to client, forwarded
    connect_failures: i64,    // outgoing connects that failed
    retries: i64,             // of those, the ones retried on another address
    buffers_total: i64,       // buffers in this worker's pool
    buffers_in_use: i64,      // buffers borrowed right now
    buffer_waits: i64,        // times a read had to wait for a free buffer
    stale_events: i64,        // events for a connection that was already closed and its slot reused (RT-2b)
    bad_events: i64,          // events whose slot index or kind was out of range (RT-2c)
    accept_failures: i64,     // accepts that failed for lack of a resource; the listener rests briefly (RT-1e)
}

// A snapshot of this worker's counters. Call it on the worker's thread, e.g. from a Tick.
fn stats(w: Worker&) -> Stats {
    return w.router_stats;
}

// --- the worker ---------------------------------------------------------------------------------

// One event loop and everything it owns. A root struct: create it where it lives, then start it.
//     var w = tcprouter::Worker { .. };
//     if !tcprouter::start(w, cfg, index) { print(w.error); return; }
// Fields starting with `c_` are internal (README: naming rule).
root struct Worker {
    error: u8[..200] = [],             // why start() returned false
    index: i64 = 0,
    cfg: Config = Config { .. },       // this worker's copy of the config
    router_epoll_fd: i32 = -1,
    router_listen_fds: i32[16] = [-1; 16], // one per cfg.listeners entry
    router_round_robin: i64 = 0,                    // rotates the first target of the built-in policy
    router_stats: Stats = Stats { .. },
    router_connection_slots: router_ConnectionSlot[>..] = [],       // one per connection, reused through router_free_slots
    router_free_slots: u32[>..<] = [],
    router_buffer_pool: u8[>..] = [],             // buffers_per_worker buffers of buffer_size bytes, grown lazily
    router_free_buffers: i32[>..<] = [],
    router_waiting_reads: u64[>..] = [],         // reads waiting for a buffer, oldest first from router_waiting_reads_head
    router_waiting_reads_head: i64 = 0,
    router_listener_resume_at: i64[16] = [0; 16],  // boottime ms when a paused listener goes back into epoll, or 0
}

// Binds this worker's listeners (SO_REUSEPORT) and prepares its tables. Returns false and fills
// w.error (naming the address and errno) instead of aborting when it cannot, e.g. the port is
// taken (RT-1d). Never calls abort or exit (RT-1e).
fn start(w: Worker&, cfg: Config, index: i64) -> bool {
    w.cfg = cfg;
    w.index = index;
    if router_spawn_error.len > 0 {                          // spawn() found a listener it cannot bind
        w.error.append(router_spawn_error);
        return false;
    }
    w.router_epoll_fd = router_epoll_create();
    if w.router_epoll_fd < 0 { return router_fail_start(w, "epoll_create", "", -w.router_epoll_fd); }
    for li in cfg.listeners.len {
        var p = router_ParsedAddress { false, [0; 16], 0 };
        let text = cfg.listeners[li].addr.text;
        if !router_parse_address(text, p) { return router_fail_start(w, "bad listener address", text, 22); }
        let fd = router_socket_listen(p.v6, p.ip, p.port, true, 1024);
        if fd < 0 { return router_fail_start(w, "cannot listen on", text, -fd); }
        w.router_listen_fds[li] = fd;
        let rc = router_epoll_control(w.router_epoll_fd, ROUTER_EPOLL_CTL_ADD, fd, ROUTER_EPOLL_IN,
                                             router_pack_event_data(ROUTER_EVENT_KIND_LISTENER, li, 0));
        if rc < 0 { return router_fail_start(w, "epoll_ctl", text, -rc); }
    }
    return true;
}

// Runs the loop until the worker has drained or been stopped (M4), calling your block once per
// Tick, and for handler connections once per event, on this worker's thread, one at a time. The block
// gets the worker so it can call send, close... Forward-only configs pass an empty block. (A `return`
// in the block leaves the function that contains it: call a named function from the block.)
fn serve<F>(w: Worker&) {
    var events: router_EpollEvent[256] = [router_EpollEvent { 0, 0 }; 256];
    var last_tick: i64 = 0;
    loop {
        let n = router_epoll_wait(w.router_epoll_fd, events[0], 256, 100);
        if n < 0 {
            router_pause_milliseconds(1);                     // an unexpected epoll error: do not spin
        } else {
            for k in n { router_dispatch_event(w, events[k].data, events[k].events); }
        }
        let now = router_boottime_milliseconds();
        router_resume_paused_listeners(w, now);
        if now - last_tick >= 100 {
            last_tick = now;
            let tick: Event = Event.Tick { now_ms: now };
            F(w, tick);
        }
    }
}

// As serve, with a policy deciding where forwarded connections go (tcpproxy, design/07).
fn serve<P, F>(w: Worker&, p: P&) {
    let e: Event = Event.Tick { now_ms: 0 };    // STUB until M3
    F(w, e);
}

// --- calls a handler block may make (on the worker it was called on) -----------------------------

// Queues bytes to the peer. False if the connection is gone or its output queue is full; in the
// second case wait for Writable. Never blocks, never grows memory past the per-connection cap (RT-5e).
fn send(w: Worker&, c: Conn, bytes: const u8[:]) -> bool { return false; }    // STUB

// Closes after the queued bytes are sent.
fn close(w: Worker&, c: Conn) {}                                                // STUB

// Closes now with an RST. (Named `reset`, not `abort`, which would hide Goose's builtin here.)
fn reset(w: Worker&, c: Conn) {}                                                // STUB

// Your own id for this connection, returned in every later event. tcprouter stores only the u32.
fn set_user(w: Worker&, c: Conn, user: u32) {}                                  // STUB
fn user(w: Worker&, c: Conn) -> u32 { return 0; }                               // STUB

// Stops or resumes reading from the peer: your own backpressure.
fn pause_reading(w: Worker&, c: Conn, paused: bool) {}                          // STUB

// Hands the connection to the engine's forwarding. Only before any byte was consumed; returns
// false (and does nothing) afterwards (RT-4e).
fn forward(w: Worker&, c: Conn, to: Target) -> bool { return false; }           // STUB

// --- running workers and talking to them --------------------------------------------------------

var router_signal_fd: i32 = -1;
var router_spawn_error: u8[..200] = [];

// Starts `n` workers, each running `worker(cfg, index)`. `worker` is a thread_fn with the signature
// (cfg: Config, index: i64), passed last:
//     tcprouter::spawn(cfg, 4, worker);
// Before it starts anything it blocks SIGTERM and SIGINT (so every worker inherits that and only
// wait_for_signal_then_drain sees them) and checks that every listener address can be bound by a
// plain socket, so a port held by another process is an error and not a silently shared port (RT-1d).
// (Message pipes per worker join here in M4.) Returns the thread ids.
fn spawn<W>(cfg: Config, n: i64) -> i64[>..] {
    router_signal_fd = router_signals_block_and_open();
    router_probe_listeners(cfg);
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
fn post(m: Message) {}                                                          // STUB

// Blocks the calling thread until SIGTERM or SIGINT, then drains every worker with a deadline
// (RT-8c). The drain itself arrives in M4: for now it returns, which ends the process. Call it from
// main, after spawn.
fn wait_for_signal_then_drain(deadline_ms: i64) {
    if router_signal_fd >= 0 { router_signal_wait(router_signal_fd); }
}
