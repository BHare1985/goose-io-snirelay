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

let C_CONNECTING: u8 = 1;       // the connect to the server is in progress; the client is not read yet
let C_FORWARDING: u8 = 2;

let C_KIND_LISTENER: u64 = 1;
let C_KIND_CLIENT: u64 = 2;
let C_KIND_SERVER: u64 = 3;

// One direction of a connection.
struct c_Dir {
    buf: i32 = -1,               // pool buffer holding unwritten bytes, or -1
    len: i32 = 0,                // bytes in the buffer
    pos: i32 = 0,                // bytes of them already written
    eof: bool = false,           // the source has ended
    shut: bool = false,          // the destination was told (shutdown of its write side)
    waiting: bool = false,       // queued for a buffer
}

struct c_Slot {
    gen: u32,                    // bumped when the connection closes: stale events and handles are ignored
    live: bool,
    state: u8,
    client_fd: i32,
    server_fd: i32,
    client_mask: u32,            // the epoll interest set now on each fd
    server_mask: u32,
    listener: u16,
    user: u32,
    up: c_Dir,                  // client to server
    down: c_Dir,                // server to client
}

// --- epoll data: what an event is about ---------------------------------------------------------------------

// kind in the low 8 bits, generation in the next 24, slot index in the high 32.
fn c_pack(kind: u64, slot: i64, gen: u32) -> u64 {
    return kind | ((gen as u64) << 8) | ((slot as u64) << 32);
}

// --- small helpers -------------------------------------------------------------------------------------------------

fn c_pause_ms(ms: i64) { sleep_ms(ms); }

// Fills w.error with "<what> <where>: <strerror(err)>" and returns false, for start().
fn c_fail(w: Worker&, what: const u8[:], where: const u8[:], err: i32) -> bool {
    var msg: u8[>..] = [];
    format(msg, what, " ", where, ": ");
    c_strerror(msg, err);
    let n = if msg.len < w.error.cap { msg.len } else { w.error.cap };
    w.error.append(msg[..n]);
    return false;
}

fn c_reason_index(r: CloseReason) -> i64 {
    return match r {
        PeerClosed => 0, PeerReset => 1, IdleTimeout => 2, HalfCloseTimeout => 3, InspectTimeout => 4,
        ConnectFailed => 5, Fenced => 6, Drained => 7, ByHandler => 8, Error => 9,
    };
}

// spawn() asks, before any worker exists, whether each listener address can be bound by a plain socket.
// If another process holds the port this is an error here and now, instead of workers silently sharing
// the port with it through SO_REUSEPORT (RT-1d).
fn c_probe_listeners(cfg: Config) {
    for li in cfg.listeners.len {
        var p = c_Parsed { false, [0; 16], 0 };
        let text = cfg.listeners[li].addr.text;
        if !c_parse_addr(text, p) { continue; }                 // check() reports bad text; start() fails
        let fd = c_listen(p.v6, p.ip, p.port, false, 1);
        if fd < 0 {
            var msg: u8[>..] = [];
            format(msg, "cannot listen on ", text, ": ");
            c_strerror(msg, -fd);
            let n = if msg.len < c_spawn_error.cap { msg.len } else { c_spawn_error.cap };
            c_spawn_error.append(msg[..n]);
            return;
        }
        c_close(fd);
    }
}

// --- the buffer pool -------------------------------------------------------------------------------------------------

// The pool grows lazily, one buffer at a time, up to buffers_per_worker: an idle worker touches no
// buffer memory. Growth only appends, so a buffer the kernel is writing into never moves (design/09 O-3).
// Returns a buffer number, or -1 when all of them are in use.
fn c_take_buf(w: Worker&) -> i32 {
    var id: i32 = -1;
    if w.c_free_bufs.len > 0 {
        id = w.c_free_bufs.pop();
    } else if w.c_st.buffers_total < w.cfg.limits.buffers_per_worker {
        id = w.c_st.buffers_total as i32;
        for k in w.cfg.limits.buffer_size { w.c_pool.push(0); }
        w.c_st.buffers_total++;
    }
    if id >= 0 { w.c_st.buffers_in_use++; }
    return id;
}

fn c_buf(w: Worker&, id: i32) -> u8[:] {
    let size = w.cfg.limits.buffer_size;
    return w.c_pool[id * size..(id + 1) * size];
}

// Returns a buffer to the pool and lets the oldest read that was waiting for one try again.
fn c_give_buf(w: Worker&, id: i32) {
    w.c_free_bufs.push(id);
    w.c_st.buffers_in_use--;
    c_wake_waiter(w);
}

fn c_wake_waiter(w: Worker&) {
    while w.c_waiters_head < w.c_waiters.len {
        let e = w.c_waiters[w.c_waiters_head];
        w.c_waiters_head++;
        let slot = (e >> 32) as i64;
        let gen = ((e >> 8) & 0xffffff) as u32;
        let up = (e & 1) == 1;
        if slot < w.c_slots.len {
            let s .= w.c_slots[slot];
            if s.live && s.gen == gen {
                let dir .= c_dir(s, up);
                if dir.waiting {
                    dir.waiting = false;
                    c_update_interest(w, slot);
                    break;
                }
            }
        }
    }
    if w.c_waiters_head >= w.c_waiters.len {
        w.c_waiters.clear();
        w.c_waiters_head = 0;
    }
}

// --- interest ---------------------------------------------------------------------------------------------------------

// The direction a read or flush works on (`up`: client to server). A function, because `.=` needs a reference
// and an `if` of two fields is not one.
fn c_dir(s: c_Slot&, up: bool) -> c_Dir& {
    if up { return s.up; }
    return s.down;
}

fn c_can_read(d: c_Dir) -> bool { return !d.eof && !d.waiting && d.len == d.pos; }
fn c_has_pending(d: c_Dir) -> bool { return d.len > d.pos; }

// Sets each fd's epoll interest to what the slot's state needs: read a source only when its direction has
// nothing unwritten and is not waiting for a buffer; wait for writability only where bytes are pending.
fn c_update_interest(w: Worker&, i: i64) {
    let s .= w.c_slots[i];
    if !s.live || s.state != C_FORWARDING { return; }
    var cm: u32 = 0;
    var sm: u32 = 0;
    if c_can_read(s.up) { cm |= c_EPOLLIN; }
    if c_has_pending(s.down) { cm |= c_EPOLLOUT; }
    if c_can_read(s.down) { sm |= c_EPOLLIN; }
    if c_has_pending(s.up) { sm |= c_EPOLLOUT; }
    if cm != s.client_mask {
        c_epoll_ctl(w.c_epfd, c_EPOLL_CTL_MOD, s.client_fd, cm, c_pack(C_KIND_CLIENT, i, s.gen));
        s.client_mask = cm;
    }
    if sm != s.server_mask {
        c_epoll_ctl(w.c_epfd, c_EPOLL_CTL_MOD, s.server_fd, sm, c_pack(C_KIND_SERVER, i, s.gen));
        s.server_mask = sm;
    }
}

// --- closing ----------------------------------------------------------------------------------------------------------

// Closes both sockets, returns the connection's buffers, frees the slot and bumps its generation. After this
// the caller must not touch the slot again.
fn c_close_conn(w: Worker&, i: i64, reason: CloseReason) {
    let s .= w.c_slots[i];
    if !s.live { return; }
    if s.client_fd >= 0 { c_close(s.client_fd); }
    if s.server_fd >= 0 { c_close(s.server_fd); }
    s.live = false;
    s.client_fd = -1;
    s.server_fd = -1;
    s.gen = (s.gen + 1) & 0xffffff;
    let up_buf = s.up.buf;
    let down_buf = s.down.buf;
    s.up = c_Dir { .. };
    s.down = c_Dir { .. };
    w.c_free_slots.push(i as u32);
    w.c_st.open--;
    w.c_st.closed[c_reason_index(reason)]++;
    if up_buf >= 0 { c_give_buf(w, up_buf); }
    if down_buf >= 0 { c_give_buf(w, down_buf); }
}

// --- accept and connect -------------------------------------------------------------------------------------------

fn c_accept_ready(w: Worker&, li: i64) {
    for k in 64 {                                        // a bounded batch per wakeup keeps the loop fair
        let fd = c_accept(w.c_listen_fds[li]);
        if fd < 0 { return; }                            // -EAGAIN: none waiting (other errors: M3, RT-1e)
        c_new_conn(w, li, fd);
    }
}

fn c_reject(w: Worker&, fd: i32, reason: CloseReason) {
    c_close(fd);
    w.c_st.closed[c_reason_index(reason)]++;
}

fn c_new_conn(w: Worker&, li: i64, fd: i32) {
    w.c_st.accepted++;
    if w.c_st.open >= w.cfg.limits.max_conns_per_worker { c_reject(w, fd, CloseReason.Error); return; }

    // Port routing: nobody read a hello. NoSni means "no inspection result"; only Any routes can match.
    let nothing: Hello = Hello.NoSni;
    let route = match_route(w.cfg, w.cfg.listeners[li].id, nothing);
    guard route else { c_reject(w, fd, CloseReason.ByHandler); return; }

    // Only forwarding exists so far (handler mode: M3).
    var target = Target { addrs: [] };
    match route.action {
        Forward f => { target = f.to; },
        _ => { c_reject(w, fd, CloseReason.ByHandler); return; },
    }
    if target.addrs.len == 0 { c_reject(w, fd, CloseReason.Error); return; }

    // A slot, reused when one is free.
    var i: i64 = 0;
    if w.c_free_slots.len > 0 {
        i = w.c_free_slots.pop();
    } else {
        i = w.c_slots.len;
        w.c_slots.push(c_Slot { gen: 1, live: false, state: 0, client_fd: -1, server_fd: -1, client_mask: 0,
                                  server_mask: 0, listener: 0, user: 0, up: c_Dir { .. }, down: c_Dir { .. } });
    }
    let s .= w.c_slots[i];
    s.live = true;
    s.state = C_CONNECTING;
    s.client_fd = fd;
    s.server_fd = -1;
    s.client_mask = 0;
    s.server_mask = 0;
    s.listener = w.cfg.listeners[li].id;
    s.user = 0;
    s.up = c_Dir { .. };
    s.down = c_Dir { .. };
    w.c_st.open++;

    // The built-in policy: rotate the first address from one connection to the next (retry: M3).
    let first = w.c_rr % target.addrs.len;
    w.c_rr++;
    c_connect(w, i, target.addrs[first].text);
}

fn c_connect(w: Worker&, i: i64, text: const u8[:]) {
    let s .= w.c_slots[i];
    var p = c_Parsed { false, [0; 16], 0 };
    if !c_parse_addr(text, p) { w.c_st.connect_failures++; c_close_conn(w, i, CloseReason.ConnectFailed); return; }
    let sfd = c_connect_start(p.v6, p.ip, p.port);
    if sfd < 0 { w.c_st.connect_failures++; c_close_conn(w, i, CloseReason.ConnectFailed); return; }
    s.server_fd = sfd;
    // The client is registered with no interest: nothing of it is read before the server answers, so a
    // failed connect can still be retried with the client's bytes untouched (RT-4c).
    c_epoll_ctl(w.c_epfd, c_EPOLL_CTL_ADD, s.client_fd, 0, c_pack(C_KIND_CLIENT, i, s.gen));
    s.server_mask = c_EPOLLOUT;
    c_epoll_ctl(w.c_epfd, c_EPOLL_CTL_ADD, sfd, s.server_mask, c_pack(C_KIND_SERVER, i, s.gen));
}

fn c_connect_done(w: Worker&, i: i64) {
    let s .= w.c_slots[i];
    let err = c_connect_result(s.server_fd);
    if err != 0 {
        w.c_st.connect_failures++;
        c_close_conn(w, i, CloseReason.ConnectFailed);
        return;
    }
    s.state = C_FORWARDING;
    c_update_interest(w, i);
}

// --- moving bytes -------------------------------------------------------------------------------------------------

// One read from the source of a direction (`up`: the client), then as much of it written as the destination takes.
fn c_read(w: Worker&, i: i64, up: bool) {
    let s .= w.c_slots[i];
    let dir .= c_dir(s, up);
    let src = if up { s.client_fd } else { s.server_fd };
    let dst = if up { s.server_fd } else { s.client_fd };
    if !c_can_read(dir) { return; }                      // a stale readiness: nothing to do

    if dir.buf < 0 {
        let b = c_take_buf(w);
        if b < 0 {                                        // pool empty: wait, do not read
            dir.waiting = true;
            w.c_waiters.push(c_pack(if up { 1 } else { 0 }, i, s.gen));
            w.c_st.buffer_waits++;
            c_update_interest(w, i);
            return;
        }
        dir.buf = b;
    }
    let buf = c_buf(w, dir.buf);
    let n = c_recv(src, buf[0], buf.len);
    if n > 0 {
        dir.len = n as i32;
        dir.pos = 0;
        c_flush(w, i, up);
        return;
    }
    // Nothing to keep: give the buffer back before anything else.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    c_give_buf(w, held);
    if n == 0 {                                           // the source ended: tell the destination, stop reading
        dir.eof = true;
        c_shutdown_wr(dst);
        dir.shut = true;
        c_finish_or_update(w, i);
        return;
    }
    if n == -(c_EAGAIN as i64) || n == -(c_EINTR as i64) {
        c_update_interest(w, i);
        return;
    }
    c_close_conn(w, i, CloseReason.PeerReset);
}

// Writes the bytes a direction holds to its destination. Whatever the destination does not take stays in
// the buffer and EPOLLOUT is switched on; reading from the source stays off until it is all written.
fn c_flush(w: Worker&, i: i64, up: bool) {
    let s .= w.c_slots[i];
    let dir .= c_dir(s, up);
    let dst = if up { s.server_fd } else { s.client_fd };
    while dir.pos < dir.len {
        let buf = c_buf(w, dir.buf);
        let rest = buf[dir.pos..dir.len];
        let n = c_send(dst, rest[0], rest.len);
        if n > 0 {
            dir.pos += n as i32;
            if up { w.c_st.bytes_in += n; } else { w.c_st.bytes_out += n; }
        } else if n == -(c_EAGAIN as i64) || n == -(c_EINTR as i64) {
            c_update_interest(w, i);                     // wait for EPOLLOUT
            return;
        } else {
            c_close_conn(w, i, CloseReason.PeerReset);
            return;
        }
    }
    // Everything written: the buffer goes back, so an idle connection holds none.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    c_give_buf(w, held);
    if dir.eof && !dir.shut {
        c_shutdown_wr(dst);
        dir.shut = true;
    }
    c_finish_or_update(w, i);
}

// Both directions ended and told their destinations: the connection is over. Otherwise re-evaluate interest.
fn c_finish_or_update(w: Worker&, i: i64) {
    let s .= w.c_slots[i];
    if !s.live { return; }
    if s.up.eof && s.up.shut && s.down.eof && s.down.shut {
        c_close_conn(w, i, CloseReason.PeerClosed);
        return;
    }
    c_update_interest(w, i);
}

// --- the event loop's dispatch ---------------------------------------------------------------------------------

fn c_dispatch(w: Worker&, data: u64, events: u32) {
    let kind = data & 0xff;
    let gen = ((data >> 8) & 0xffffff) as u32;
    let slot = (data >> 32) as i64;

    if kind == C_KIND_LISTENER {
        if slot < w.cfg.listeners.len { c_accept_ready(w, slot); } else { w.c_st.bad_events++; }
        return;
    }
    // A slot number comes from the kernel's event data: check it, never trust it (RT-2c). A generation that
    // no longer matches is an event for a connection that has closed (RT-2b).
    if slot >= w.c_slots.len { w.c_st.bad_events++; return; }
    let s .= w.c_slots[slot];
    if !s.live || s.gen != gen { w.c_st.stale_events++; return; }

    let failed = (events & (c_EPOLLERR | c_EPOLLHUP)) != 0;
    if s.state == C_CONNECTING {
        if kind == C_KIND_SERVER { c_connect_done(w, slot); }
        else if failed { c_close_conn(w, slot, CloseReason.PeerReset); }
        return;
    }
    let from_client = kind == C_KIND_CLIENT;
    if (events & c_EPOLLERR) != 0 { c_close_conn(w, slot, CloseReason.PeerReset); return; }
    if (events & c_EPOLLOUT) != 0 {
        c_flush(w, slot, !from_client);                  // client writable: finish `down`; server writable: `up`
        if !s.live { return; }
    }
    if (events & (c_EPOLLIN | c_EPOLLHUP)) != 0 {
        let dir .= c_dir(s, from_client);
        if (events & c_EPOLLIN) == 0 && !c_can_read(dir) {
            c_close_conn(w, slot, CloseReason.PeerReset);    // hung up while we were not reading it
            return;
        }
        c_read(w, slot, from_client);
    }
}
