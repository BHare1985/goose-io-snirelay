// The engine's public face: workers, events, and the calls a handler block may make
// (design/02-api.md sections 3 to 6). Forwarding is real as of M2; handler mode, timeouts, drain,
// tags and messages are still stubs and are marked STUB.
namespace tcprouter;

import .config;
import .policy;

// --- connections and events ---------------------------------------------------------------------

// A handle to one connection. Valid until its Closed event; a stale handle is ignored, never
// reaches the connection that now uses the slot (RT-2b).
struct Conn { slot: u32, gen: u32 }

enum CloseReason {
    PeerClosed, PeerReset, IdleTimeout, HalfCloseTimeout, InspectTimeout, ConnectFailed,
    Fenced, Drained, ByHandler, Error,
    InvalidHello,       // the first bytes were a TLS handshake that breaks the format or exceeds 16 KB (RT-3f)
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
struct TagSessions { tag: u16, open: i64 }

struct Stats {
    accepted: i64,            // connections accepted
    open: i64,                // connections open now
    closed: i64[11],          // connections closed, by CloseReason in declaration order
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
    tags: TagSessions[..64],  // connections open now under each tag (sessions per tag)
}

// A snapshot of this worker's counters. Call it on the worker's thread, e.g. from a Tick.
fn stats(w: Worker&) -> Stats {
    var s = w._stats;
    s.tags.clear();
    for i in w._connection_slots.len {                       // sessions per tag: counted when asked, not kept up to date
        let slot .= w._connection_slots[i];
        if slot.live && slot.tag != 0 {
            var found = false;
            for &t in s.tags { if t.tag == slot.tag { t.open++; found = true; } }
            if !found && s.tags.len < s.tags.cap { s.tags.push(TagSessions { tag: slot.tag, open: 1 }); }
        }
    }
    s
}

// --- the worker ---------------------------------------------------------------------------------

// One event loop and everything it owns. A root struct: create it where it lives, then start it.
//     var w = tcprouter::Worker { .. };
//     if !w.start(cfg, index) { print(w.error); return; }
// Fields starting with `c_` are internal (README: naming rule).
root struct Worker {
    error: u8[..200] = [],             // why start() returned false
    index: i64 = 0,
    cfg: Config = Config { .. },       // this worker's copy of the config
    _epoll_fd: i32 = -1,
    _listen_fds: i32[16] = [-1; 16], // one per cfg.listeners entry
    _round_robin: i64 = 0,                    // rotates the first target of the built-in policy
    _stats: Stats = Stats { .. },
    _connection_slots: _ConnectionSlot[>..] = [],       // one per connection, reused through _free_slots
    _free_slots: u32[>..<] = [],
    _buffer_pool: u8[>..] = [],             // buffers_per_worker buffers of buffer_size bytes, grown lazily
    _free_buffers: i32[>..<] = [],
    _waiting_reads: u64[>..] = [],         // reads waiting for a buffer, oldest first from _waiting_reads_head
    _waiting_reads_head: i64 = 0,
    _inspect_buffer: u8[32768] = [0; 32768],     // where a ClientHello is peeked at: one per worker, one inspect at a time
    _inspect_scratch: u8[16384] = [0; 16384],    // where parse_hello reassembles a hello split over records
    _ready: u64[>..] = [],                       // connections with work left after a pass (edge-triggered: nothing else will wake them)
    _ready_head: i64 = 0,
    _pending: _PendingEvent[>..] = [],           // handler events queued during a batch, drained by serve (handler.goose)
    _pending_head: i64 = 0,
    _override_targets: Target[>..] = [],         // targets given to forward(); a free entry has no addresses
    _message_fd: i32 = -1,                       // this worker's end of its message pipe (messages.goose)
    _draining: bool = false,
    _drain_deadline_ms: i64 = 0,
    _tags: _TagEntry[..64] = [],                 // deadlines per tag (messages.goose)
    _dialing: i64 = 0,                           // dialled connections whose connect is still in progress (handler.goose: dial)
    _dial_due: i64 = 0,                          // the earliest connect deadline among them (0 = none known): the loop wakes then, never earlier for this
    _tags_full: bool = false,                    // a deadline could not be recorded (table full): every tag without an entry is fenced (RT-6g)
    _deadline_scan_at: i64 = 0,                  // the earliest deadline not yet enforced, or 0
    _now_ms: i64 = 0,                            // CLOCK_BOOTTIME at the start of the current pass of the loop
    _listener_resume_at: i64[16] = [0; 16],  // boottime ms when a paused listener goes back into epoll, or 0
    _policy_on: bool = false,                    // serve(policy): forwarded connections ask the policy (policy.goose)
    _policy_requests: _PolicyRequest[>..] = [],  // what the policy has to be told or asked, drained by serve
    _policy_head: i64 = 0,
}

// Binds this worker's listeners (SO_REUSEPORT) and prepares its tables. Returns false and fills
// w.error (naming the address and errno) instead of aborting when it cannot, e.g. the port is
// taken (RT-1d). Never calls abort or exit (RT-1e).
fn start(w: Worker&, cfg: const Config&, index: i64) -> bool {
    w.cfg = cfg;
    w.index = index;
    if _spawn_error.len > 0 {                          // spawn() found a listener it cannot bind
        w.error.append(_spawn_error);
        qput(_DrainReport { drained: 0 });         // a worker that never serves still owes drain() its report
        return false;
    }
    w._epoll_fd = c_epoll_create();
    if w._epoll_fd < 0 { return w._fail_start("epoll_create", "", -w._epoll_fd); }
    if index < _worker_count {                              // spawn() made one pipe per worker
        w._message_fd = _message_read_fds[index];
        c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_ADD, w._message_fd, c_EPOLLIN, _pack_event_data(_EVENT_KIND_MESSAGE, 0, 0));
    }
    for f in cfg.fenced_tags { w._tags.push(_TagEntry { tag: f, until_ms: 0 }); }
    for li in cfg.listeners.len {
        var p = _ParsedAddress { false, [0; 16], 0 };
        let text = cfg.listeners[li].addr.text;
        if !_parse_address(text, p) { return w._fail_start("bad listener address", text, 22); }
        let fd = c_listen(p.v6, p.ip, p.port, true, 1024);
        if fd < 0 { return w._fail_start("cannot listen on", text, -fd); }
        w._listen_fds[li] = fd;
        let rc = c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_ADD, fd, c_EPOLLIN,
                                             _pack_event_data(_EVENT_KIND_LISTENER, li, 0));
        if rc < 0 { return w._fail_start("epoll_ctl", text, -rc); }
    }
    true
}

// Runs the loop until the worker has drained or been stopped (M4), calling your block once per
// Tick, and for handler connections once per event, on this worker's thread, one at a time. The block
// gets the worker so it can call send, close... Forward-only configs pass an empty block. (A `return`
// in the block leaves the function that contains it: call a named function from the block.)
fn serve<F>(w: Worker&) {
    var none = _NoPolicy { };
    w._policy_on = false;
    w._serve_loop(none, F);
}

// As serve, with a policy deciding where forwarded connections go (tcpproxy, design/07; the hooks are in policy.goose).
// The policy is called on this worker's thread, between batches of events, never from inside the epoll dispatch.
fn serve<P, F>(w: Worker&, p: P&) {
    w._policy_on = true;
    w._serve_loop(p, F);
}

fn _serve_loop<P, F>(w: Worker&, p: P&) {
    var events: c_EpollEvent[256] = [c_EpollEvent { 0, 0 }; 256];
    var last_tick: i64 = 0;
    var last_sweep: i64 = 0;
    loop {
        let wait_ms: i32 = if w._ready_head < w._ready.len || w._policy_head < w._policy_requests.len { 0 } else { w._wait_limit() };     // work left over: do not sleep
        let n = c_epoll_wait(w._epoll_fd, events[0], 256, wait_ms);
        w._now_ms = c_boottime_ms();
        // Messages first, then deadlines, then events: a drain or a fence must not be outrun by traffic in the same pass.
        if n > 0 { for k in n { if (events[k].data & 0xff) == _EVENT_KIND_MESSAGE { w._read_messages(); } } }
        w._enforce_deadlines();
        if n < 0 {
            _pause_milliseconds(1);                     // an unexpected epoll error: do not spin
        } else {
            for k in n { if (events[k].data & 0xff) != _EVENT_KIND_MESSAGE { w._dispatch_event(events[k].data, events[k].events); } }
        }
        w._run_ready();
        w._deliver_policy(p);
        w._deliver_events(F);
        if w._drain_finished() {
            w._deliver_events(F);
            qput(_DrainReport { drained: w._stats.closed[_close_reason_index(CloseReason.Drained)] });
            return;
        }
        let now = w._now_ms;
        w._resume_paused_listeners(now);
        if w._dialing > 0 && now >= w._dial_due { w._expire_dials(now); }
        if now - last_sweep >= 250 {
            last_sweep = now;
            w._sweep_timeouts(now);
        }
        if now - last_tick >= 100 {
            last_tick = now;
            let tick: Event = Event.Tick { now_ms: now };
            F(w, tick);
            w._deliver_events(F);
        }
    }
}


// --- running workers and talking to them --------------------------------------------------------

var _signal_fd: i32 = -1;
var _spawn_error: u8[..200] = [];

// Starts `n` workers, each running `worker(cfg, index)`. `worker` is a thread_fn with the signature
// (cfg: Config, index: i64), passed last:
//     tcprouter::spawn(cfg, 4, worker);
// Before it starts anything it blocks SIGTERM and SIGINT (so every worker inherits that and only
// wait_for_signal_then_drain sees them) and checks that every listener address can be bound by a
// plain socket, so a port held by another process is an error and not a silently shared port (RT-1d).
// It also creates one message pipe per worker, before any worker starts (messages.goose). At most 64 workers. Returns the thread ids.
fn spawn<W>(cfg: const Config&, n: i64) -> i64[>..] {
    _signal_fd = c_signals_open();
    _probe_listeners(cfg);
    _worker_count = if n < _MAX_WORKERS { n } else { _MAX_WORKERS };
    for i in _worker_count {
        var fds: i32[2] = [-1, -1];
        c_pipe(fds);
        _message_read_fds[i] = fds[0];
        _message_write_fds[i] = fds[1];
    }
    var ids: i64[>..] = [];
    for i in _worker_count {
        _worker_ids[i] = thread_spawn(W, cfg, i);
        ids.push(_worker_ids[i]);
    }
    ids
}

// A sensible default for the number of workers: the CPUs this process may use.
fn cpu_count() -> i64 { hardware_threads() }

enum Message {
    Drain { deadline_ms: i64 },
    Deadline { tag: u16, until_ms: i64 },     // tag may forward until this CLOCK_BOOTTIME millisecond; the latest deadline wins
    CloseTagged { tag: u16, gen: u32 },       // close every connection of the tag whose target generation is <= gen
    Stats { reply_to: u16 },
    ReplaceDeadline { tag: u16, until_ms: i64 },   // sets the tag's deadline exactly (shorter or longer); 0 = unfenced (RT-6f)
    Policy { body: u8[..48] },                     // handed untouched to the worker's policy: on_message (RT-13g)
    SetAddr { target: u16, slot: u8, addr: Addr }, // sets address `slot` of Config.targets[target] on every worker; empty addr clears it (RT-10c)
}

