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
// reading its source (EPOLLIN off) and waits for the destination to become writable (EPOLLOUT on): that
// is the whole of backpressure (RT-5c). When the pool is empty a read waits in a queue until a buffer
// comes back (RT-5d). epoll is level-triggered, so "interest" is simply what the slot's state needs.
namespace tcprouter;

import .config;
import .engine;
import .address;
import .route;
import .sni;
import os;

let _STATE_INSPECTING: u8 = 3;       // an inspect: Sni listener: waiting for the ClientHello, which stays queued in the kernel
let _STATE_CONNECTING: u8 = 1;       // the connect to the server is in progress; the client is not read yet
let _STATE_FORWARDING: u8 = 2;

let _EVENT_KIND_LISTENER: u64 = 1;
let _EVENT_KIND_CLIENT: u64 = 2;
let _EVENT_KIND_SERVER: u64 = 3;

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
    server_mask: u32,
    listener: u16,
    user: u32,
    started_ms: i64,             // when the connection was accepted (inspect timeout)
    inspect_seen: i32,           // bytes of the hello seen at the last peek
    rcvlowat_raised: bool,       // SO_RCVLOWAT was raised while waiting for a short hello; put back before forwarding
    route_index: u16,            // the route the connection took (an index into cfg.routes)
    first_target: u8,            // the address the built-in policy starts with
    attempts: u8,                // addresses tried so far
    up: _Direction,                  // client to server
    down: _Direction,                // server to client
}

// --- epoll data: what an event is about ---------------------------------------------------------------------

// kind in the low 8 bits, generation in the next 24, slot index in the high 32.
fn _pack_event_data(kind: u64, slot: i64, gen: u32) -> u64 {
    return kind | ((gen as u64) << 8) | ((slot as u64) << 32);
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
    return false;
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
fn _probe_listeners(cfg: Config) {
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
    return id;
}

fn _buffer_slice(w: Worker&, id: i32) -> u8[:] {
    let size = w.cfg.limits.buffer_size;
    return w._buffer_pool[id * size..(id + 1) * size];
}

// Returns a buffer to the pool and lets the oldest read that was waiting for one try again.
fn _give_back_buffer(w: Worker&, id: i32) {
    w._free_buffers.push(id);
    w._stats.buffers_in_use--;
    _wake_waiting_read(w);
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
                let dir .= _direction_of(s, up);
                if dir.waiting {
                    dir.waiting = false;
                    _update_epoll_interest(w, slot);
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
    return s.down;
}

fn _direction_can_read(d: _Direction) -> bool { return !d.eof && !d.waiting && d.len == d.pos; }
fn _direction_has_pending_bytes(d: _Direction) -> bool { return d.len > d.pos; }

// Sets each fd's epoll interest to what the slot's state needs: read a source only when its direction has
// nothing unwritten and is not waiting for a buffer; wait for writability only where bytes are pending.
fn _update_epoll_interest(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    if !s.live || s.state != _STATE_FORWARDING { return; }
    var cm: u32 = 0;
    var sm: u32 = 0;
    if _direction_can_read(s.up) { cm |= c_EPOLLIN; }
    if _direction_has_pending_bytes(s.down) { cm |= c_EPOLLOUT; }
    if _direction_can_read(s.down) { sm |= c_EPOLLIN; }
    if _direction_has_pending_bytes(s.up) { sm |= c_EPOLLOUT; }
    if cm != s.client_mask {
        c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_MOD, s.client_fd, cm, _pack_event_data(_EVENT_KIND_CLIENT, i, s.gen));
        s.client_mask = cm;
    }
    if sm != s.server_mask {
        c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_MOD, s.server_fd, sm, _pack_event_data(_EVENT_KIND_SERVER, i, s.gen));
        s.server_mask = sm;
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
    s.live = false;
    s.client_fd = -1;
    s.server_fd = -1;
    s.gen = (s.gen + 1) & 0xffffff;
    let up_buf = s.up.buf;
    let down_buf = s.down.buf;
    s.up = _Direction { .. };
    s.down = _Direction { .. };
    w._free_slots.push(i as u32);
    w._stats.open--;
    w._stats.closed[_close_reason_index(reason)]++;
    if up_buf >= 0 { _give_back_buffer(w, up_buf); }
    if down_buf >= 0 { _give_back_buffer(w, down_buf); }
}

// --- accept and connect -------------------------------------------------------------------------------------------

// How long a listener is left alone after accept failed for lack of a resource (descriptors, memory, buffers).
let _ACCEPT_PAUSE_MILLISECONDS: i64 = 100;

fn _accept_ready_connections(w: Worker&, li: i64) {
    for k in 64 {                                        // a bounded batch per wakeup keeps the loop fair
        let fd = c_accept(w._listen_fds[li]);
        if fd >= 0 { _new_connection(w, li, fd); continue; }
        let error = -fd;
        if error == c_EAGAIN || error == c_EINTR { return; }       // nobody is waiting
        if error == c_ECONNABORTED || error == c_EPROTO { continue; }   // that client left
        // Out of descriptors, memory or socket buffers (EMFILE, ENFILE, ENOMEM, ENOBUFS...): nothing we do right now
        // can fix it, and epoll is level-triggered, so the pending connection would wake us again at once and we
        // would spin. Leave this listener out of epoll for a moment; the clients wait in the kernel's backlog
        // and are served when descriptors come back (RT-1e).
        w._stats.accept_failures++;
        _pause_listener(w, li);
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

fn _new_connection(w: Worker&, li: i64, fd: i32) {
    w._stats.accepted++;
    if w._stats.open >= w.cfg.limits.max_conns_per_worker { _reject_connection(w, fd, CloseReason.Error); return; }
    let inspect = w.cfg.listeners[li].inspect == Inspect.Sni;

    // A slot, reused when one is free.
    var i: i64 = 0;
    if w._free_slots.len > 0 {
        i = w._free_slots.pop();
    } else {
        i = w._connection_slots.len;
        w._connection_slots.push(_ConnectionSlot { gen: 1, live: false, state: 0, client_fd: -1, server_fd: -1, client_mask: 0,
                                                   server_mask: 0, listener: 0, user: 0, started_ms: 0, inspect_seen: 0,
                                                   rcvlowat_raised: false, route_index: 0, first_target: 0, attempts: 0,
                                                   up: _Direction { .. }, down: _Direction { .. } });
    }
    let s .= w._connection_slots[i];
    s.live = true;
    s.state = if inspect { _STATE_INSPECTING } else { _STATE_CONNECTING };
    s.client_fd = fd;
    s.server_fd = -1;
    s.server_mask = 0;
    s.listener = w.cfg.listeners[li].id;
    s.user = 0;
    s.started_ms = c_boottime_ms();
    s.inspect_seen = 0;
    s.rcvlowat_raised = false;
    s.route_index = 0;
    s.first_target = 0;
    s.attempts = 0;
    s.up = _Direction { .. };
    s.down = _Direction { .. };
    w._stats.open++;

    // The client is registered at once. While a hello is awaited it is watched for input; otherwise it has no
    // interest at all until the server answers, so a failed connect can be retried with its bytes untouched.
    s.client_mask = if inspect { c_EPOLLIN } else { 0 };
    let rc = c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_ADD, fd, s.client_mask, _pack_event_data(_EVENT_KIND_CLIENT, i, s.gen));
    if rc < 0 { _close_connection(w, i, CloseReason.Error); return; }
    if !inspect {
        let nothing: Hello = Hello.NoSni;          // nobody read a hello: only Any routes can match
        _route_and_connect(w, i, nothing);
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
    if n == 0 { _close_connection(w, i, CloseReason.PeerClosed); return; }          // ended before any hello
    if n < 0 {
        if n == -(c_EAGAIN as i64) || n == -(c_EINTR as i64) { return; }
        _close_connection(w, i, CloseReason.PeerReset);
        return;
    }
    // Woken with no new bytes: with SO_RCVLOWAT raised the only thing that wakes us is the peer ending.
    if n <= s.inspect_seen { _close_connection(w, i, CloseReason.PeerClosed); return; }
    s.inspect_seen = n as i32;

    let hello = parse_hello(w._inspect_buffer[..n], w._inspect_scratch);
    match hello {
        NeedMore more => {
            if more.total > w._inspect_buffer.len { _close_connection(w, i, CloseReason.InvalidHello); return; }
            c_set_rcvlowat(s.client_fd, more.total as i32);
            s.rcvlowat_raised = true;
            return;
        },
        Invalid => { _close_connection(w, i, CloseReason.InvalidHello); return; },
        _ => {},
    }
    _route_and_connect(w, i, hello);
}

// Closes the connections that have waited too long for their ClientHello. Called every 250 ms (design/03 section 5);
// there is no timer per connection.
fn _sweep_timeouts(w: Worker&, now: i64) {
    let inspect_limit = w.cfg.limits.inspect_timeout_ms;
    for i in w._connection_slots.len {
        let s .= w._connection_slots[i];
        if s.live && s.state == _STATE_INSPECTING && now - s.started_ms >= inspect_limit {
            _close_connection(w, i, CloseReason.InspectTimeout);
        }
    }
}

// --- choosing the target and connecting, with retry (RT-4c, RT-4d) -----------------------------------------------

// The connection's first bytes are `hello` (NoSni when nobody looked): find its route and start connecting.
fn _route_and_connect(w: Worker&, i: i64, hello: Hello) {
    let s .= w._connection_slots[i];
    let route = match_route(w.cfg, s.listener, hello);
    guard route else { _close_connection(w, i, CloseReason.ByHandler); return; }
    s.route_index = w.cfg.routes.index_of(route) as u16;

    // Only forwarding exists so far (handler mode: M3 group C).
    var count = 0;
    match route.action {
        Forward f => { count = f.to.addrs.len; },
        _ => {},
    }
    if count == 0 { _close_connection(w, i, CloseReason.ByHandler); return; }

    // The built-in policy: connection k starts at address k mod n and moves on, wrapping, after each failure.
    s.first_target = (w._round_robin % count) as u8;
    w._round_robin++;
    s.attempts = 0;

    // Done with the hello: the client is left alone until the server answers, and its low-water mark goes back to 1.
    if s.rcvlowat_raised { c_set_rcvlowat(s.client_fd, 1); s.rcvlowat_raised = false; }
    if s.client_mask != 0 {
        c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_MOD, s.client_fd, 0, _pack_event_data(_EVENT_KIND_CLIENT, i, s.gen));
        s.client_mask = 0;
    }
    s.state = _STATE_CONNECTING;
    _attempt_connect(w, i);
}

fn _target_of(w: Worker&, s: _ConnectionSlot&) -> Target {
    var target = Target { addrs: [] };
    match w.cfg.routes[s.route_index as i64].action {
        Forward f => { target = f.to; },
        _ => {},
    }
    return target;
}

// A connect that failed: count it, and count a retry when another address is still to be tried.
fn _count_connect_failure(w: Worker&, attempts: i64, addresses: i64) {
    w._stats.connect_failures++;
    if attempts < addresses { w._stats.retries++; }
}

// Starts a connect to the next address not yet tried, or closes the connection when every address has failed. An
// address that fails at once is counted and the next is tried in the same call; one that is merely in progress ends
// the call and _connect_finished decides later.
fn _attempt_connect(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    let target = _target_of(w, s);
    let count = target.addrs.len;
    loop {
        if s.attempts >= count { _close_connection(w, i, CloseReason.ConnectFailed); return; }
        let index = (s.first_target + s.attempts) % count;
        s.attempts++;
        var p = _ParsedAddress { false, [0; 16], 0 };
        var sfd: i32 = -1;
        if _parse_address(target.addrs[index].text, p) { sfd = c_connect_start(p.v6, p.ip, p.port); }
        if sfd >= 0 {
            s.server_fd = sfd;
            s.server_mask = c_EPOLLOUT;
            c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_ADD, sfd, s.server_mask, _pack_event_data(_EVENT_KIND_SERVER, i, s.gen));
            return;
        }
        _count_connect_failure(w, s.attempts, count);
    }
}

fn _connect_finished(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    let err = c_connect_result(s.server_fd);
    if err != 0 {
        c_close(s.server_fd);                              // closing removes it from epoll
        s.server_fd = -1;
        s.server_mask = 0;
        _count_connect_failure(w, s.attempts, _target_of(w, s).addrs.len);
        _attempt_connect(w, i);                            // the next address, or close
        return;
    }
    s.state = _STATE_FORWARDING;
    _update_epoll_interest(w, i);
}

// --- moving bytes -------------------------------------------------------------------------------------------------

// One read from the source of a direction (`up`: the client), then as much of it written as the destination takes.
fn _read_direction(w: Worker&, i: i64, up: bool) {
    let s .= w._connection_slots[i];
    let dir .= _direction_of(s, up);
    let src = if up { s.client_fd } else { s.server_fd };
    let dst = if up { s.server_fd } else { s.client_fd };
    if !_direction_can_read(dir) { return; }                      // a stale readiness: nothing to do

    if dir.buf < 0 {
        let b = _take_buffer(w);
        if b < 0 {                                        // pool empty: wait, do not read
            dir.waiting = true;
            w._waiting_reads.push(_pack_event_data(if up { 1 } else { 0 }, i, s.gen));
            w._stats.buffer_waits++;
            _update_epoll_interest(w, i);
            return;
        }
        dir.buf = b;
    }
    let buf = _buffer_slice(w, dir.buf);
    let n = c_recv(src, buf[0], buf.len);
    if n > 0 {
        dir.len = n as i32;
        dir.pos = 0;
        _flush_direction(w, i, up);
        return;
    }
    // Nothing to keep: give the buffer back before anything else.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    _give_back_buffer(w, held);
    if n == 0 {                                           // the source ended: tell the destination, stop reading
        dir.eof = true;
        c_shutdown_wr(dst);
        dir.shut = true;
        _finish_or_update_interest(w, i);
        return;
    }
    if n == -(c_EAGAIN as i64) || n == -(c_EINTR as i64) {
        _update_epoll_interest(w, i);
        return;
    }
    _close_connection(w, i, CloseReason.PeerReset);
}

// Writes the bytes a direction holds to its destination. Whatever the destination does not take stays in
// the buffer and EPOLLOUT is switched on; reading from the source stays off until it is all written.
fn _flush_direction(w: Worker&, i: i64, up: bool) {
    let s .= w._connection_slots[i];
    let dir .= _direction_of(s, up);
    let dst = if up { s.server_fd } else { s.client_fd };
    while dir.pos < dir.len {
        let buf = _buffer_slice(w, dir.buf);
        let rest = buf[dir.pos..dir.len];
        let n = c_send(dst, rest[0], rest.len);
        if n > 0 {
            dir.pos += n as i32;
            if up { w._stats.bytes_in += n; } else { w._stats.bytes_out += n; }
        } else if n == -(c_EAGAIN as i64) || n == -(c_EINTR as i64) {
            _update_epoll_interest(w, i);                     // wait for EPOLLOUT
            return;
        } else {
            _close_connection(w, i, CloseReason.PeerReset);
            return;
        }
    }
    // Everything written: the buffer goes back, so an idle connection holds none.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    _give_back_buffer(w, held);
    if dir.eof && !dir.shut {
        c_shutdown_wr(dst);
        dir.shut = true;
    }
    _finish_or_update_interest(w, i);
}

// Both directions ended and told their destinations: the connection is over. Otherwise re-evaluate interest.
fn _finish_or_update_interest(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    if !s.live { return; }
    if s.up.eof && s.up.shut && s.down.eof && s.down.shut {
        _close_connection(w, i, CloseReason.PeerClosed);
        return;
    }
    _update_epoll_interest(w, i);
}

// --- the event loop's dispatch ---------------------------------------------------------------------------------

fn _dispatch_event(w: Worker&, data: u64, events: u32) {
    let kind = data & 0xff;
    let gen = ((data >> 8) & 0xffffff) as u32;
    let slot = (data >> 32) as i64;

    // The kind comes from the kernel's event data too: anything but the three we hand out is bad (RT-2c).
    if kind == _EVENT_KIND_LISTENER {
        if slot < w.cfg.listeners.len { _accept_ready_connections(w, slot); } else { w._stats.bad_events++; }
        return;
    }
    if kind != _EVENT_KIND_CLIENT && kind != _EVENT_KIND_SERVER { w._stats.bad_events++; return; }
    // A slot number comes from the kernel's event data: check it, never trust it (RT-2c). A generation that
    // no longer matches is an event for a connection that has closed (RT-2b).
    if slot >= w._connection_slots.len { w._stats.bad_events++; return; }
    let s .= w._connection_slots[slot];
    if !s.live || s.gen != gen { w._stats.stale_events++; return; }

    let failed = (events & (c_EPOLLERR | c_EPOLLHUP)) != 0;
    if s.state == _STATE_INSPECTING {
        if (events & c_EPOLLERR) != 0 { _close_connection(w, slot, CloseReason.PeerReset); return; }
        if kind == _EVENT_KIND_CLIENT { _inspect_connection(w, slot); }           // input, or the peer ended
        return;
    }
    if s.state == _STATE_CONNECTING {
        if kind == _EVENT_KIND_SERVER { _connect_finished(w, slot); }
        else if failed { _close_connection(w, slot, CloseReason.PeerReset); }
        return;
    }
    let from_client = kind == _EVENT_KIND_CLIENT;
    if (events & c_EPOLLERR) != 0 { _close_connection(w, slot, CloseReason.PeerReset); return; }
    if (events & c_EPOLLOUT) != 0 {
        _flush_direction(w, slot, !from_client);                  // client writable: finish `down`; server writable: `up`
        if !s.live { return; }
    }
    if (events & (c_EPOLLIN | c_EPOLLHUP)) != 0 {
        let dir .= _direction_of(s, from_client);
        if (events & c_EPOLLIN) == 0 && !_direction_can_read(dir) {
            _close_connection(w, slot, CloseReason.PeerReset);    // hung up while we were not reading it
            return;
        }
        _read_direction(w, slot, from_client);
    }
}
