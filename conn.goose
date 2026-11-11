// Connections inside a worker: accept, connect, move bytes both ways, half-close, backpressure, close.
// Internal (every name here starts with `c_`); the public face is engine.goose. design/03-engine.md.
//
// The shape of one forwarded connection (a "slot"):
//
//     client fd  --- up:   read into a buffer, write to the server --->  server fd
//     client fd  <-- down: write from a buffer, read from the server ---  server fd
//
// A direction owns at most ONE pool buffer, and only while it holds bytes it has read but not yet written.
// An idle connection therefore holds none (RT-5a). While a direction has unwritten bytes the engine stops
// reading its source and waits for the destination to become writable: that is the whole of backpressure
// (RT-5c). When the pool is empty a read waits in a queue until a buffer comes back (RT-5d).
//
// Forwarded sockets are registered with epoll ONCE, edge-triggered (EPOLLIN|OUT|RDHUP|ET), and never modified
// again: an event only sets a readiness flag in the slot (`ready`), and _pump moves bytes until a flag runs out
// (recv or send says EAGAIN, or a short read drained the socket). A pump that stops because of its byte budget
// puts the connection on the worker's ready list, because an edge will not be reported again. Listeners, inspecting
// connections and handler connections stay level-triggered (their interest changes with their state).
namespace tcprouter;

import .config;
import .engine;
import .address;
import .route;
import .sni;
import os;

let _STATE_HANDLING: u8 = 4;         // Action.Handle: the user's code owns the connection through events
let _STATE_INSPECTING: u8 = 3;       // an inspect: Sni listener: waiting for the ClientHello, which stays queued in the kernel
let _STATE_CONNECTING: u8 = 1;       // the connect to the server is in progress; the client is not read yet
let _WAKEUP_BUDGET: i64 = 65536;      // bytes one connection direction may move per epoll wakeup before others get a turn (RT-5f)
let _STATE_FORWARDING: u8 = 2;

// Readiness flags of a forwarded connection: for each socket, readable, writable, and "the peer ended its sending"
// (so a short read does not mean the end of the data: the next read tells).
let _READY_CLIENT_IN: u8 = 1;
let _READY_CLIENT_OUT: u8 = 2;
let _READY_SERVER_IN: u8 = 4;
let _READY_SERVER_OUT: u8 = 8;
let _READY_CLIENT_ENDED: u8 = 16;
let _READY_SERVER_ENDED: u8 = 32;
let _READY_SERVER_BITS: u8 = 44;      // everything about the server socket (kept apart so a retry can forget it)

let _EVENT_KIND_LISTENER: u64 = 1;
let _EVENT_KIND_CLIENT: u64 = 2;
let _EVENT_KIND_SERVER: u64 = 3;
let _EVENT_KIND_MESSAGE: u64 = 4;

// One direction of a connection.
struct _Direction {
    buf: i32 = -1,               // pool buffer holding unwritten bytes, or -1
    len: i32 = 0,                // bytes in the buffer
    pos: i32 = 0,                // bytes of them already written
    eof: bool = false,           // the source has ended
    shut: bool = false,          // the destination was told (shutdown of its write side)
    waiting: bool = false,       // queued for a buffer
}

struct _ConnectionSlot {
    gen: u32,                    // bumped when the connection closes: stale events and handles are ignored
    live: bool,
    state: u8,
    client_fd: i32,
    server_fd: i32,
    client_mask: u32,            // the epoll interest set now on each fd
    client_registered: bool,     // the client is in epoll
    server_mask: u32,
    ready: u8,                   // edge-triggered readiness, see _READY_*: set by events, cleared when recv/send says there is no more
    queued: bool,                // on the worker's ready list
    listener: u16,
    user: u32,
    started_ms: i64,             // when the connection was accepted, or the current connect attempt began (their timeouts)
    last_active_ms: i64,         // when bytes last moved in either direction (idle and half-close timeouts)
    half_closed_at_ms: i64,      // when the first direction ended, or 0
    inspect_seen: i32,           // bytes of the hello seen at the last peek
    rcvlowat_raised: bool,       // SO_RCVLOWAT was raised while waiting for a short hello; put back before forwarding
    route_index: u16,            // the route the connection took (an index into cfg.routes)
    first_target: u8,            // the address the built-in policy starts with
    attempts: u8,                // addresses tried so far
    tried: u32,                  // policy mode: the slots tried so far, one bit each (policy.goose)
    pick_slot: u8,               // policy mode: the slot of the pick being connected
    connect_ms: i64,             // policy mode: the pick's own connect timeout, 0 = Limits.connect_timeout_ms
    policied: bool,              // policy mode: the policy decides this connection's server
    policy_connected: bool,      // the policy was told it connected, so it is told when it closes
    tag: u16,                    // the tag of the Handle route or of the forward target (0: untagged)
    target_gen: u32,             // the generation of that target (close-by-tag)
    override_target: i32,        // a connection the handler forwarded: its target's index in w._override_targets, else -1
    out_buffers: i32[4],         // handler mode: the output queue, oldest first, at most 4 pool buffers
    out_lengths: i32[4],
    out_count: u8,
    out_pos: i32,                // bytes of the oldest queued buffer already written
    consumed: bool,              // a byte was handed to the handler or sent: forward() is no longer allowed
    paused: bool,                // pause_reading
    data_pending: bool,          // a Data event is queued and holds this connection's read buffer
    want_writable: bool,         // a send was refused: tell the handler when it would fit
    closing: bool,               // flush the queue, then close with closing_reason
    closing_reason: CloseReason,
    up: _Direction,                  // client to server
    down: _Direction,                // server to client
}

// --- epoll data: what an event is about ---------------------------------------------------------------------

// kind in the low 8 bits, generation in the next 24, slot index in the high 32.
fn _pack_event_data(kind: u64, slot: i64, gen: u32) -> u64 {
    kind | ((gen as u64) << 8) | ((slot as u64) << 32)
}

// --- small helpers -------------------------------------------------------------------------------------------------

fn _pause_milliseconds(ms: i64) { sleep_ms(ms); }

// Fills w.error with "<what> <where>: <strerror(err)>" and returns false, for start().
fn _fail_start(w: Worker&, what: const u8[:], where: const u8[:], err: i32) -> bool {
    var msg: u8[>..] = [];
    format(msg, what, " ", where, ": ");
    c_strerror(msg, err);
    let n = if msg.len < w.error.cap { msg.len } else { w.error.cap };
    w.error.append(msg[..n]);
    false
}

fn _close_reason_index(r: CloseReason) -> i64 {
    return match r {
        PeerClosed => 0, PeerReset => 1, IdleTimeout => 2, HalfCloseTimeout => 3, InspectTimeout => 4,
        ConnectFailed => 5, Fenced => 6, Drained => 7, ByHandler => 8, Error => 9, InvalidHello => 10,
    };
}

// spawn() asks, before any worker exists, whether each listener address can be bound by a plain socket.
// If another process holds the port this is an error here and now, instead of workers silently sharing
// the port with it through SO_REUSEPORT (RT-1d).
fn _probe_listeners(cfg: const Config&) {
    for li in cfg.listeners.len {
        var p = _ParsedAddress { false, [0; 16], 0 };
        let text = cfg.listeners[li].addr.text;
        if !_parse_address(text, p) { continue; }                 // check() reports bad text; start() fails
        let fd = c_listen(p.v6, p.ip, p.port, false, 1);
        if fd < 0 {
            var msg: u8[>..] = [];
            format(msg, "cannot listen on ", text, ": ");
            c_strerror(msg, -fd);
            let n = if msg.len < _spawn_error.cap { msg.len } else { _spawn_error.cap };
            _spawn_error.append(msg[..n]);
            return;
        }
        c_close(fd);
    }
}

// --- the buffer pool -------------------------------------------------------------------------------------------------

// The pool grows lazily, one buffer at a time, up to buffers_per_worker: an idle worker touches no
// buffer memory. Growth only appends, so a buffer the kernel is writing into never moves (design/09 O-3).
// Returns a buffer number, or -1 when all of them are in use.
fn _take_buffer(w: Worker&) -> i32 {
    var id: i32 = -1;
    if w._free_buffers.len > 0 {
        id = w._free_buffers.pop();
    } else if w._stats.buffers_total < w.cfg.limits.buffers_per_worker {
        id = w._stats.buffers_total as i32;
        for k in w.cfg.limits.buffer_size { w._buffer_pool.push(0); }
        w._stats.buffers_total++;
    }
    if id >= 0 { w._stats.buffers_in_use++; }
    id
}

fn _buffer_slice(w: Worker&, id: i32) -> u8[:] {
    let size = w.cfg.limits.buffer_size;
    w._buffer_pool[id * size..(id + 1) * size]
}

// Returns a buffer to the pool and lets the oldest read that was waiting for one try again.
fn _give_back_buffer(w: Worker&, id: i32) {
    w._free_buffers.push(id);
    w._stats.buffers_in_use--;
    w._wake_waiting_read();
}

fn _wake_waiting_read(w: Worker&) {
    while w._waiting_reads_head < w._waiting_reads.len {
        let e = w._waiting_reads[w._waiting_reads_head];
        w._waiting_reads_head++;
        let slot = (e >> 32) as i64;
        let gen = ((e >> 8) & 0xffffff) as u32;
        let up = (e & 1) == 1;
        if slot < w._connection_slots.len {
            let s .= w._connection_slots[slot];
            if s.live && s.gen == gen {
                let dir .= s._direction_of(up);
                if dir.waiting {
                    dir.waiting = false;
                    if s.state == _STATE_HANDLING { w._update_epoll_interest(slot); } else { w._queue_ready(slot); }
                    break;
                }
            }
        }
    }
    if w._waiting_reads_head >= w._waiting_reads.len {
        w._waiting_reads.clear();
        w._waiting_reads_head = 0;
    }
}

// --- interest ---------------------------------------------------------------------------------------------------------

// The direction a read or flush works on (`up`: client to server). A function, because `.=` needs a reference
// and an `if` of two fields is not one.
fn _direction_of(s: _ConnectionSlot&, up: bool) -> _Direction& {
    if up { return s.up; }
    s.down
}


// Sets each fd's epoll interest to what the slot's state needs: read a source only when its direction has
// nothing unwritten and is not waiting for a buffer; wait for writability only where bytes are pending.
// Sets the client's epoll interest: the first non-empty interest adds it, later changes modify it.
fn _set_client_interest(w: Worker&, i: i64, mask: u32) {
    let s .= w._connection_slots[i];
    if s.client_registered {
        if mask == s.client_mask { return; }
        c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_MOD, s.client_fd, mask, _pack_event_data(_EVENT_KIND_CLIENT, i, s.gen));
    } else {
        if mask == 0 { return; }
        let rc = c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_ADD, s.client_fd, mask, _pack_event_data(_EVENT_KIND_CLIENT, i, s.gen));
        if rc < 0 { return; }                               // out of epoll memory: like a failed MOD, the idle timeout ends it
        s.client_registered = true;
    }
    s.client_mask = mask;
}

fn _update_epoll_interest(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    if !s.live { return; }
    if s.state == _STATE_HANDLING {
        var m: u32 = 0;
        // A pending Data event does not clear EPOLLIN: serve delivers every queued event before the next epoll_wait, and
        // _read_for_handler will not read while one is pending, so the mask change (an epoll_ctl per request, twice) would be for nothing.
        if s._handler_wants_read() { m |= c_EPOLLIN; }
        if s.out_count > 0 { m |= c_EPOLLOUT; }
        w._set_client_interest(i, m);
        return;
    }
}

// --- closing ----------------------------------------------------------------------------------------------------------

// Closes both sockets, returns the connection's buffers, frees the slot and bumps its generation. After this
// the caller must not touch the slot again.
fn _close_connection(w: Worker&, i: i64, reason: CloseReason) {
    let s .= w._connection_slots[i];
    if !s.live { return; }
    if s.client_fd >= 0 { c_close(s.client_fd); }
    if s.server_fd >= 0 { c_close(s.server_fd); }
    if s.state == _STATE_HANDLING { w._queue_closed(i, reason); }
    if s.policy_connected { w._queue_policy_closed(i, reason); }
    for k in s.out_count { w._give_back_buffer(s.out_buffers[k]); }
    if s.override_target >= 0 { w._override_targets[s.override_target].addrs.clear(); }
    s.live = false;
    s.client_fd = -1;
    s.server_fd = -1;
    s.gen = (s.gen + 1) & 0xffffff;
    let up_buf = if s.data_pending { -1 } else { s.up.buf };       // a queued Data event still owns that buffer
    let down_buf = s.down.buf;
    s.up = _Direction { .. };
    s.down = _Direction { .. };
    w._free_slots.push(i as u32);
    w._stats.open--;
    w._stats.closed[_close_reason_index(reason)]++;
    if up_buf >= 0 { w._give_back_buffer(up_buf); }
    if down_buf >= 0 { w._give_back_buffer(down_buf); }
}

// --- accept and connect -------------------------------------------------------------------------------------------

// How long a listener is left alone after accept failed for lack of a resource (descriptors, memory, buffers).
let _ACCEPT_PAUSE_MILLISECONDS: i64 = 100;

fn _accept_ready_connections(w: Worker&, li: i64) {
    for k in 64 {                                        // a bounded batch per wakeup keeps the loop fair
        let fd = c_accept(w._listen_fds[li]);
        if fd >= 0 { w._new_connection(li, fd); continue; }
        let error = -fd;
        if error == c_EAGAIN || error == c_EINTR { return; }       // nobody is waiting
        if error == c_ECONNABORTED || error == c_EPROTO { continue; }   // that client left
        // Out of descriptors, memory or socket buffers (EMFILE, ENFILE, ENOMEM, ENOBUFS...): nothing we do right now
        // can fix it, and epoll is level-triggered, so the pending connection would wake us again at once and we
        // would spin. Leave this listener out of epoll for a moment; the clients wait in the kernel's backlog
        // and are served when descriptors come back (RT-1e).
        w._stats.accept_failures++;
        w._pause_listener(li);
        return;
    }
}

fn _pause_listener(w: Worker&, li: i64) {
    c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_MOD, w._listen_fds[li], 0,
                         _pack_event_data(_EVENT_KIND_LISTENER, li, 0));
    w._listener_resume_at[li] = c_boottime_ms() + _ACCEPT_PAUSE_MILLISECONDS;
}

// Puts back into epoll the listeners whose pause is over. Called once per pass of the loop.
fn _resume_paused_listeners(w: Worker&, now: i64) {
    for li in w.cfg.listeners.len {
        if w._listener_resume_at[li] != 0 && now >= w._listener_resume_at[li] {
            w._listener_resume_at[li] = 0;
            c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_MOD, w._listen_fds[li], c_EPOLLIN,
                                 _pack_event_data(_EVENT_KIND_LISTENER, li, 0));
        }
    }
}

fn _reject_connection(w: Worker&, fd: i32, reason: CloseReason) {
    c_close(fd);
    w._stats.closed[_close_reason_index(reason)]++;
}

fn _fresh_slot(gen: u32, fd: i32, listener: u16, inspect: bool, now: i64) -> _ConnectionSlot {
    return _ConnectionSlot {
        gen: gen, live: true, state: if inspect { _STATE_INSPECTING } else { _STATE_CONNECTING }, client_fd: fd, server_fd: -1,
        client_mask: if inspect { c_EPOLLIN } else { 0 }, client_registered: false, server_mask: 0, ready: 0, queued: false, listener: listener, user: 0, started_ms: now, last_active_ms: now, half_closed_at_ms: 0,
        inspect_seen: 0, rcvlowat_raised: false, route_index: 0, first_target: 0, attempts: 0, tried: 0, pick_slot: 0, connect_ms: 0, policied: false, policy_connected: false, tag: 0, target_gen: 0, override_target: -1,
        out_buffers: [-1; 4], out_lengths: [0; 4], out_count: 0, out_pos: 0, consumed: false, paused: false,
        data_pending: false, want_writable: false, closing: false, closing_reason: CloseReason.PeerClosed,
        up: _Direction { .. }, down: _Direction { .. },
    };
}

fn _new_connection(w: Worker&, li: i64, fd: i32) {
    w._stats.accepted++;
    if w._stats.open >= w.cfg.limits.max_conns_per_worker { w._reject_connection(fd, CloseReason.Error); return; }
    let inspect = w.cfg.listeners[li].inspect == Inspect.Sni;

    // A slot, reused when one is free; a reused slot keeps its generation (bumped when it was freed).
    var i: i64 = 0;
    var gen: u32 = 1;
    if w._free_slots.len > 0 {
        i = w._free_slots.pop();
        gen = w._connection_slots[i].gen;
        w._connection_slots[i] = _fresh_slot(gen, fd, w.cfg.listeners[li].id, inspect, w._now_ms);
    } else {
        i = w._connection_slots.len;
        w._connection_slots.push(_fresh_slot(gen, fd, w.cfg.listeners[li].id, inspect, w._now_ms));
    }
    let s .= w._connection_slots[i];
    w._stats.open++;

    // While a hello is awaited the client is watched for input at once. Otherwise it joins epoll only when the server
    // answers (_set_client_interest), so a failed connect can be retried with its bytes untouched; a client that hangs
    // up in the meantime is noticed then, at the latest when the connect timeout ends.
    if inspect {
        let rc = c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_ADD, fd, s.client_mask, _pack_event_data(_EVENT_KIND_CLIENT, i, s.gen));
        if rc < 0 { w._close_connection(i, CloseReason.Error); return; }
        s.client_registered = true;
    }
    if !inspect {
        let nothing: Hello = Hello.NoSni;          // nobody read a hello: only Any routes can match
        w._route_and_connect(i, nothing);
    }
}

// --- reading the ClientHello without consuming it (RT-3c, RT-3d, RT-3f, RT-3g) -------------------------------

// The client sent something on an inspect: Sni listener. Peek at everything queued, ask parse_hello what it is, and
// route. The bytes stay in the kernel, so the backend later receives them from byte 0.
//
// A hello that is not complete yet is NOT peeked at again on a timer, and the same short hello is never looked at
// twice: SO_RCVLOWAT is raised to the byte count the parser asked for, so epoll reports the socket again only when
// that many bytes are queued (or the peer ended). The inspect buffer is one per worker, because a worker handles
// one event at a time; a connection holds nothing between events except the bytes the kernel queued.
fn _inspect_connection(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    let n = c_peek(s.client_fd, w._inspect_buffer[0], w._inspect_buffer.len);
    if n == 0 { w._close_connection(i, CloseReason.PeerClosed); return; }          // ended before any hello
    if n < 0 {
        if n == -(c_EAGAIN as i64) || n == -(c_EINTR as i64) { return; }
        w._close_connection(i, CloseReason.PeerReset);
        return;
    }
    // Woken with no new bytes: with SO_RCVLOWAT raised the only thing that wakes us is the peer ending.
    if n <= s.inspect_seen { w._close_connection(i, CloseReason.PeerClosed); return; }
    s.inspect_seen = n as i32;

    let hello = parse_hello(w._inspect_buffer[..n], w._inspect_scratch);
    match hello {
        NeedMore more => {
            if more.total > w._inspect_buffer.len { w._close_connection(i, CloseReason.InvalidHello); return; }
            c_set_rcvlowat(s.client_fd, more.total as i32);
            s.rcvlowat_raised = true;
            return;
        },
        Invalid => { w._close_connection(i, CloseReason.InvalidHello); return; },
        _ => {},
    }
    w._route_and_connect(i, hello);
}

// One pass over the slot table, every 250 ms (design/03 section 5): there is no timer per connection. It gives up on
// a hello that is too slow (inspect), on a connect that does not complete (then tries the next address), on a
// connection with no bytes either way (idle) and on one left half-open (half-close). A byte in the direction still open
// restarts the half-close clock.
fn _sweep_timeouts(w: Worker&, now: i64) {
    let limits = w.cfg.limits;
    for i in w._connection_slots.len {
        let s .= w._connection_slots[i];
        if !s.live { continue; }
        if s.state == _STATE_INSPECTING {
            if now - s.started_ms >= limits.inspect_timeout_ms { w._close_connection(i, CloseReason.InspectTimeout); }
        } else if s.state == _STATE_CONNECTING {
            let allowed = if s.connect_ms > 0 { s.connect_ms } else { limits.connect_timeout_ms };
            if s.server_fd >= 0 && now - s.started_ms >= allowed { w._connect_failed(i); }
        } else if s.half_closed_at_ms != 0 {
            let since = if s.last_active_ms > s.half_closed_at_ms { s.last_active_ms } else { s.half_closed_at_ms };
            if now - since >= limits.half_close_timeout_ms { w._close_connection(i, CloseReason.HalfCloseTimeout); }
        } else if now - s.last_active_ms >= limits.idle_timeout_ms {
            w._close_connection(i, CloseReason.IdleTimeout);
        }
    }
}

// --- choosing the target and connecting, with retry (RT-4c, RT-4d) -----------------------------------------------

// The connection's first bytes are `hello` (NoSni when nobody looked): find its route and start connecting.
fn _route_and_connect(w: Worker&, i: i64, hello: Hello) {
    let s .= w._connection_slots[i];
    let route = match_route(w.cfg, s.listener, hello);
    guard route else { w._close_connection(i, CloseReason.ByHandler); return; }
    s.route_index = w.cfg.routes.index_of(route) as u16;

    var count = 0;
    var handle = false;
    var forward = false;
    var tag: u16 = 0;
    match route.action {
        Forward f => {
            forward = true;
            if f.to < w.cfg.targets.len {
                let t .= w.cfg.targets[f.to as i64];
                count = t.addrs.len; tag = t.tag; s.target_gen = t.gen;
            }
        },
        Handle h => { handle = true; tag = h.tag; },
        _ => {},
    }
    s.tag = tag;
    if w._policy_on && forward { w._start_deciding(i); return; }   // the policy picks, and its tag is fenced then
    if !w._tag_allows(tag) { w._close_connection(i, CloseReason.Fenced); return; }   // fenced, or past its deadline
    if handle { w._start_handling(i, tag, hello); return; }
    if count == 0 { w._close_connection(i, CloseReason.ByHandler); return; }
    w._start_connecting(i, count);
}

// Done with the hello: the client's low-water mark goes back to 1.
fn _end_inspection(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    if s.rcvlowat_raised { c_set_rcvlowat(s.client_fd, 1); s.rcvlowat_raised = false; }
}

// Puts the client into epoll for good, edge-triggered. A client that was watched level-triggered (it was inspected, or a
// handler had it) is modified instead, and counts as readable and writable until a recv or send says otherwise.
fn _register_client_edge(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    let mask = c_EPOLLIN | c_EPOLLOUT | c_EPOLLRDHUP | c_EPOLLET;
    let data = _pack_event_data(_EVENT_KIND_CLIENT, i, s.gen);
    if s.client_registered {
        c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_MOD, s.client_fd, mask, data);
        s.ready |= _READY_CLIENT_IN | _READY_CLIENT_OUT;
    } else {
        if c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_ADD, s.client_fd, mask, data) < 0 { w._close_connection(i, CloseReason.Error); return; }
        s.client_registered = true;
    }
    s.client_mask = mask;
}

// Forwarding: the client is left alone until the server answers. The built-in policy: connection k starts at
// address k mod n and moves on, wrapping, after each failure.
fn _start_connecting(w: Worker&, i: i64, count: i64) {
    let s .= w._connection_slots[i];
    s.first_target = (w._round_robin % count) as u8;
    w._round_robin++;
    s.attempts = 0;
    w._end_inspection(i);
    w._register_client_edge(i);
    if !s.live { return; }
    s.state = _STATE_CONNECTING;
    w._attempt_connect(i);
}

// Handler mode: the user's code gets the connection as events. Opened goes first; reading starts once it is queued.
fn _start_handling(w: Worker&, i: i64, tag: u16, hello: Hello) {
    let s .= w._connection_slots[i];
    w._end_inspection(i);
    s.state = _STATE_HANDLING;
    s.tag = tag;
    let opened .= w._queue_event(_PENDING_OPENED, i);
    match hello {
        Found f => { opened.sni.append(f.name); },
        _ => {},
    }
    w._update_epoll_interest(i);
}

fn _target_of(w: Worker&, s: _ConnectionSlot&) -> Target {
    if s.override_target >= 0 { return w._override_targets[s.override_target]; }
    var target = Target { addrs: [] };
    match w.cfg.routes[s.route_index as i64].action {
        Forward f => { if f.to < w.cfg.targets.len { target = w.cfg.targets[f.to as i64]; } },
        _ => {},
    }
    target
}

// A connect that failed: count it, and count a retry when another address is still to be tried.
fn _count_connect_failure(w: Worker&, attempts: i64, addresses: i64) {
    w._stats.connect_failures++;
    if attempts < addresses { w._stats.retries++; }
}

// Starts a connect to `addr` and puts the new socket into epoll. false when the socket could not even be started.
fn _connect_to(w: Worker&, i: i64, addr: Addr) -> bool {
    let s .= w._connection_slots[i];
    s.started_ms = w._now_ms;                          // the connect timeout runs from here
    var p = _ParsedAddress { false, [0; 16], 0 };
    var sfd: i32 = -1;
    if _parse_address(addr.text, p) { sfd = c_connect_start(p.v6, p.ip, p.port); }
    if sfd < 0 { return false; }
    s.server_fd = sfd;
    s.server_mask = c_EPOLLIN | c_EPOLLOUT | c_EPOLLRDHUP | c_EPOLLET;
    c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_ADD, sfd, s.server_mask, _pack_event_data(_EVENT_KIND_SERVER, i, s.gen));
    true
}

// Starts a connect to the next address not yet tried, or closes the connection when every address has failed. An
// address that fails at once is counted and the next is tried in the same call; one that is merely in progress ends
// the call and _connect_finished decides later.
fn _attempt_connect(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    let target = w._target_of(s);
    let count = target.addrs.len;
    loop {
        if s.attempts >= count { w._close_connection(i, CloseReason.ConnectFailed); return; }
        let index = (s.first_target + s.attempts) % count;
        s.attempts++;
        if target.addrs[index].text.len == 0 { continue; }          // a slot cleared by SetAddr: never picked, not a failure
        if w._connect_to(i, target.addrs[index]) { return; }
        w._count_connect_failure(s.attempts, count);
    }
}

// The attempt failed (refused, or timed out): count it and try the next address, or close when none is left.
fn _connect_failed(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    c_close(s.server_fd);                                  // closing removes it from epoll
    s.server_fd = -1;
    s.server_mask = 0;
    s.ready = s.ready & (255 - _READY_SERVER_BITS);        // whatever the failed attempt reported is void
    if s.policied { w._policy_connect_failed(i); return; }      // the policy decides what next
    w._count_connect_failure(s.attempts, w._target_of(s).addrs.len);
    w._attempt_connect(i);
}

fn _connect_finished(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    if c_connect_result(s.server_fd) != 0 { w._connect_failed(i); return; }
    s.state = _STATE_FORWARDING;
    if s.policied { s.policy_connected = true; w._queue_policy(_POLICY_CONNECTED, i); }
    s.ready |= _READY_SERVER_OUT;                          // a finished connect is writable; its edge was this event
    w._pump(i);
}

// --- moving bytes -------------------------------------------------------------------------------------------------

fn _flag_readable(up: bool) -> u8 { if up { _READY_CLIENT_IN } else { _READY_SERVER_IN } }        // the source of the direction
fn _flag_writable(up: bool) -> u8 { if up { _READY_SERVER_OUT } else { _READY_CLIENT_OUT } }      // its destination
fn _flag_ended(up: bool) -> u8 { if up { _READY_CLIENT_ENDED } else { _READY_SERVER_ENDED } }    // its source's peer ended

fn _forget(s: _ConnectionSlot&, flag: u8) { s.ready = s.ready & (255 - flag); }

// Adds a connection to the ready list: it has work left that no event will announce.
fn _queue_ready(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    if !s.live || s.queued { return; }
    s.queued = true;
    w._ready.push(_pack_event_data(0, i, s.gen));
}

// Runs the connections queued so far (those queued meanwhile wait for the next pass, so nobody is starved).
fn _run_ready(w: Worker&) {
    let end = w._ready.len;
    while w._ready_head < end {
        let e = w._ready[w._ready_head];
        w._ready_head++;
        let slot = (e >> 32) as i64;
        let gen = ((e >> 8) & 0xffffff) as u32;
        let s .= w._connection_slots[slot];
        if s.live && s.gen == gen {
            s.queued = false;
            if s.state == _STATE_FORWARDING { w._pump(slot); }
        }
    }
    if w._ready_head >= w._ready.len {
        w._ready.clear();
        w._ready_head = 0;
    }
}

// Moves bytes in both directions as far as the readiness flags allow.
fn _pump(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    let more_up = w._pump_direction(i, true);
    if !s.live { return; }
    let more_down = w._pump_direction(i, false);
    if !s.live { return; }
    if more_up || more_down { w._queue_ready(i); }
}

// Reads from the source and writes to the destination of one direction (`up`: client to server) until one of them has
// nothing more to give or take. Returns true when it stopped only because it moved _WAKEUP_BUDGET bytes (the others get
// a turn; the connection is queued to go on), false when it is blocked, finished or closed.
fn _pump_direction(w: Worker&, i: i64, up: bool) -> bool {
    let s .= w._connection_slots[i];
    let dir .= s._direction_of(up);
    let src = if up { s.client_fd } else { s.server_fd };
    let dst = if up { s.server_fd } else { s.client_fd };
    let readable = _flag_readable(up);
    let writable = _flag_writable(up);
    var moved: i64 = 0;
    loop {
        if dir.len > dir.pos {                                        // bytes read but not written yet
            if (s.ready & writable) == 0 { return false; }            // destination full: its writable edge restarts us
            if !w._write_buffer(i, up, dst) { return false; }
        }
        if dir.eof || dir.waiting { return false; }
        if (s.ready & readable) == 0 { return false; }
        if moved >= _WAKEUP_BUDGET { return true; }

        let b = w._take_buffer();
        if b < 0 {                                                    // pool empty: wait, do not read
            dir.waiting = true;
            w._waiting_reads.push(_pack_event_data(if up { 1 } else { 0 }, i, s.gen));
            w._stats.buffer_waits++;
            return false;
        }
        dir.buf = b;
        let buf = w._buffer_slice(b);
        let n = c_recv(src, buf[0], buf.len);
        if n > 0 {
            dir.len = n as i32;
            dir.pos = 0;
            moved += n;
            s.last_active_ms = w._now_ms;
            // A short read means the socket is drained, unless its peer already ended: then the next read says so.
            if n < buf.len && (s.ready & _flag_ended(up)) == 0 { s._forget(readable); }
            continue;
        }
        // Nothing to keep: give the buffer back before anything else.
        let held = dir.buf;
        dir.buf = -1;
        dir.len = 0;
        dir.pos = 0;
        w._give_back_buffer(held);
        if n == 0 {                                                   // the source ended: tell the destination, stop reading
            dir.eof = true;
            if s.half_closed_at_ms == 0 { s.half_closed_at_ms = w._now_ms; }
            s._shutdown_unless_closing(up, dst);
            dir.shut = true;
            if s.up.eof && s.up.shut && s.down.eof && s.down.shut { w._close_connection(i, CloseReason.PeerClosed); }
            return false;
        }
        if n == -(c_EAGAIN as i64) { s._forget(readable); return false; }
        if n == -(c_EINTR as i64) { return true; }                    // interrupted: try again on the next pass
        w._close_connection(i, CloseReason.PeerReset);
        return false;
    }
}

// Writes what a direction holds. True when all of it went out (the buffer is back in the pool); false when the destination
// is full (its writable flag is cleared) or the connection was closed.
fn _write_buffer(w: Worker&, i: i64, up: bool, dst: i32) -> bool {
    let s .= w._connection_slots[i];
    // Under a tag nothing is written, in either direction, once its deadline has passed (RT-6a): the bytes just read are dropped.
    if !w._tag_allows(s.tag) { w._close_connection(i, CloseReason.Fenced); return false; }
    let dir .= s._direction_of(up);
    while dir.pos < dir.len {
        let buf = w._buffer_slice(dir.buf);
        let rest = buf[dir.pos..dir.len];
        let n = c_send(dst, rest[0], rest.len);
        if n > 0 {
            dir.pos += n as i32;
            s.last_active_ms = w._now_ms;
            if up { w._stats.bytes_in += n; } else { w._stats.bytes_out += n; }
        } else if n == -(c_EAGAIN as i64) {
            s._forget(_flag_writable(up));
            return false;
        } else if n != -(c_EINTR as i64) {
            w._close_connection(i, CloseReason.PeerReset);
            return false;
        }
    }
    // Everything written: the buffer goes back, so an idle connection holds none.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    w._give_back_buffer(held);
    true
}

// Tells the destination that this direction ended, unless the other direction has already ended too: then the
// connection closes right away and the close itself sends the FIN (one syscall less per connection).
fn _shutdown_unless_closing(s: _ConnectionSlot&, up: bool, dst: i32) {
    let other .= s._direction_of(!up);
    if other.eof && other.shut { return; }
    c_shutdown_wr(dst);
}

// --- the event loop's dispatch ---------------------------------------------------------------------------------

fn _dispatch_event(w: Worker&, data: u64, events: u32) {
    let kind = data & 0xff;
    let gen = ((data >> 8) & 0xffffff) as u32;
    let slot = (data >> 32) as i64;

    // The kind comes from the kernel's event data too: anything but the three we hand out is bad (RT-2c).
    if kind == _EVENT_KIND_LISTENER {
        if slot < w.cfg.listeners.len { w._accept_ready_connections(slot); } else { w._stats.bad_events++; }
        return;
    }
    if kind != _EVENT_KIND_CLIENT && kind != _EVENT_KIND_SERVER { w._stats.bad_events++; return; }
    // A slot number comes from the kernel's event data: check it, never trust it (RT-2c). A generation that
    // no longer matches is an event for a connection that has closed (RT-2b).
    if slot >= w._connection_slots.len { w._stats.bad_events++; return; }
    let s .= w._connection_slots[slot];
    if !s.live || s.gen != gen { w._stats.stale_events++; return; }

    if s.state == _STATE_INSPECTING {
        if (events & c_EPOLLERR) != 0 { w._close_connection(slot, CloseReason.PeerReset); return; }
        if kind == _EVENT_KIND_CLIENT { w._inspect_connection(slot); }           // input, or the peer ended
        return;
    }
    if s.state == _STATE_HANDLING {
        if kind != _EVENT_KIND_CLIENT { return; }
        if (events & c_EPOLLERR) != 0 { w._close_connection(slot, CloseReason.PeerReset); return; }
        if (events & c_EPOLLOUT) != 0 {
            w._flush_output(slot);
            if !s.live { return; }
        }
        if (events & (c_EPOLLIN | c_EPOLLHUP)) != 0 {
            if (events & c_EPOLLIN) == 0 && !s._handler_can_read() { w._close_connection(slot, CloseReason.PeerReset); return; }
            w._read_for_handler(slot);
        }
        return;
    }
    // A forwarded connection (connecting or forwarding): the event only says what the sockets can do now.
    let from_client = kind == _EVENT_KIND_CLIENT;
    let in_flag = if from_client { _READY_CLIENT_IN } else { _READY_SERVER_IN };
    let out_flag = if from_client { _READY_CLIENT_OUT } else { _READY_SERVER_OUT };
    let ended_flag = if from_client { _READY_CLIENT_ENDED } else { _READY_SERVER_ENDED };
    if (events & (c_EPOLLIN | c_EPOLLHUP | c_EPOLLRDHUP)) != 0 { s.ready |= in_flag; }
    if (events & (c_EPOLLOUT | c_EPOLLHUP)) != 0 { s.ready |= out_flag; }       // a hung-up socket "can write": the write fails and says so
    if (events & (c_EPOLLRDHUP | c_EPOLLHUP)) != 0 { s.ready |= ended_flag; }
    if s.state == _STATE_CONNECTING {
        // A client that hangs up while we connect is only noted (its flags): the connect finishes or fails first, and a
        // finished one finds the hang-up on its first read or write. That costs at most one wasted backend connect.
        if !from_client { w._connect_finished(slot); }                          // success, refusal or error: the socket says which
        return;
    }
    if (events & c_EPOLLERR) != 0 { w._close_connection(slot, CloseReason.PeerReset); return; }
    w._pump(slot);
}
