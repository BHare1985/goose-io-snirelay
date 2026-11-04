// Connections inside a worker: accept, connect, move bytes both ways, half-close, backpressure, close.
// Internal (every name here starts with `tr_`); the public face is engine.goose. design/03-engine.md.
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

let TR_CONNECTING: u8 = 1;       // the connect to the server is in progress; the client is not read yet
let TR_FORWARDING: u8 = 2;

let TR_KIND_LISTENER: u64 = 1;
let TR_KIND_CLIENT: u64 = 2;
let TR_KIND_SERVER: u64 = 3;

// One direction of a connection.
struct tr_Dir {
    buf: i32 = -1,               // pool buffer holding unwritten bytes, or -1
    len: i32 = 0,                // bytes in the buffer
    pos: i32 = 0,                // bytes of them already written
    eof: bool = false,           // the source has ended
    shut: bool = false,          // the destination was told (shutdown of its write side)
    waiting: bool = false,       // queued for a buffer
}

struct tr_Slot {
    gen: u32,                    // bumped when the connection closes: stale events and handles are ignored
    live: bool,
    state: u8,
    client_fd: i32,
    server_fd: i32,
    client_mask: u32,            // the epoll interest set now on each fd
    server_mask: u32,
    listener: u16,
    user: u32,
    up: tr_Dir,                  // client to server
    down: tr_Dir,                // server to client
}

// --- epoll data: what an event is about ---------------------------------------------------------------------

// kind in the low 8 bits, generation in the next 24, slot index in the high 32.
fn tr_pack(kind: u64, slot: i64, gen: u32) -> u64 {
    return kind | ((gen as u64) << 8) | ((slot as u64) << 32);
}

// --- small helpers -------------------------------------------------------------------------------------------------

fn tr_pause_ms(ms: i64) { sleep_ms(ms); }

// Fills w.error with "<what> <where>: <strerror(err)>" and returns false, for start().
fn tr_fail(w: Worker&, what: const u8[:], where: const u8[:], err: i32) -> bool {
    var msg: u8[>..] = [];
    format(msg, what, " ", where, ": ");
    tcprouter_sys::tr_strerror(msg, err);
    let n = if msg.len < w.error.cap { msg.len } else { w.error.cap };
    w.error.append(msg[..n]);
    return false;
}

fn tr_reason_index(r: CloseReason) -> i64 {
    return match r {
        PeerClosed => 0, PeerReset => 1, IdleTimeout => 2, HalfCloseTimeout => 3, InspectTimeout => 4,
        ConnectFailed => 5, Fenced => 6, Drained => 7, ByHandler => 8, Error => 9,
    };
}

// spawn() asks, before any worker exists, whether each listener address can be bound by a plain socket.
// If another process holds the port this is an error here and now, instead of workers silently sharing
// the port with it through SO_REUSEPORT (RT-1d).
fn tr_probe_listeners(cfg: Config) {
    for li in cfg.listeners.len {
        var p = tr_Parsed { false, [0; 16], 0 };
        let text = cfg.listeners[li].addr.text;
        if !tr_parse_addr(text, p) { continue; }                 // check() reports bad text; start() fails
        let fd = tcprouter_sys::tr_listen(p.v6, p.ip, p.port, false, 1);
        if fd < 0 {
            var msg: u8[>..] = [];
            format(msg, "cannot listen on ", text, ": ");
            tcprouter_sys::tr_strerror(msg, -fd);
            let n = if msg.len < tr_spawn_error.cap { msg.len } else { tr_spawn_error.cap };
            tr_spawn_error.append(msg[..n]);
            return;
        }
        tcprouter_sys::tr_close(fd);
    }
}

// --- the buffer pool -------------------------------------------------------------------------------------------------

// The pool grows lazily, one buffer at a time, up to buffers_per_worker: an idle worker touches no
// buffer memory. Growth only appends, so a buffer the kernel is writing into never moves (design/09 O-3).
// Returns a buffer number, or -1 when all of them are in use.
fn tr_take_buf(w: Worker&) -> i32 {
    var id: i32 = -1;
    if w.tr_free_bufs.len > 0 {
        id = w.tr_free_bufs.pop();
    } else if w.tr_st.buffers_total < w.cfg.limits.buffers_per_worker {
        id = w.tr_st.buffers_total as i32;
        for k in w.cfg.limits.buffer_size { w.tr_pool.push(0); }
        w.tr_st.buffers_total++;
    }
    if id >= 0 { w.tr_st.buffers_in_use++; }
    return id;
}

fn tr_buf(w: Worker&, id: i32) -> u8[:] {
    let size = w.cfg.limits.buffer_size;
    return w.tr_pool[id * size..(id + 1) * size];
}

// Returns a buffer to the pool and lets the oldest read that was waiting for one try again.
fn tr_give_buf(w: Worker&, id: i32) {
    w.tr_free_bufs.push(id);
    w.tr_st.buffers_in_use--;
    tr_wake_waiter(w);
}

fn tr_wake_waiter(w: Worker&) {
    while w.tr_waiters_head < w.tr_waiters.len {
        let e = w.tr_waiters[w.tr_waiters_head];
        w.tr_waiters_head++;
        let slot = (e >> 32) as i64;
        let gen = ((e >> 8) & 0xffffff) as u32;
        let up = (e & 1) == 1;
        if slot < w.tr_slots.len {
            let s .= w.tr_slots[slot];
            if s.live && s.gen == gen {
                let dir .= tr_dir(s, up);
                if dir.waiting {
                    dir.waiting = false;
                    tr_update_interest(w, slot);
                    break;
                }
            }
        }
    }
    if w.tr_waiters_head >= w.tr_waiters.len {
        w.tr_waiters.clear();
        w.tr_waiters_head = 0;
    }
}

// --- interest ---------------------------------------------------------------------------------------------------------

// The direction a read or flush works on (`up`: client to server). A function, because `.=` needs a reference
// and an `if` of two fields is not one.
fn tr_dir(s: tr_Slot&, up: bool) -> tr_Dir& {
    if up { return s.up; }
    return s.down;
}

fn tr_can_read(d: tr_Dir) -> bool { return !d.eof && !d.waiting && d.len == d.pos; }
fn tr_has_pending(d: tr_Dir) -> bool { return d.len > d.pos; }

// Sets each fd's epoll interest to what the slot's state needs: read a source only when its direction has
// nothing unwritten and is not waiting for a buffer; wait for writability only where bytes are pending.
fn tr_update_interest(w: Worker&, i: i64) {
    let s .= w.tr_slots[i];
    if !s.live || s.state != TR_FORWARDING { return; }
    var cm: u32 = 0;
    var sm: u32 = 0;
    if tr_can_read(s.up) { cm |= tcprouter_sys::EPOLLIN; }
    if tr_has_pending(s.down) { cm |= tcprouter_sys::EPOLLOUT; }
    if tr_can_read(s.down) { sm |= tcprouter_sys::EPOLLIN; }
    if tr_has_pending(s.up) { sm |= tcprouter_sys::EPOLLOUT; }
    if cm != s.client_mask {
        tcprouter_sys::tr_epoll_ctl(w.tr_epfd, tcprouter_sys::EPOLL_CTL_MOD, s.client_fd, cm, tr_pack(TR_KIND_CLIENT, i, s.gen));
        s.client_mask = cm;
    }
    if sm != s.server_mask {
        tcprouter_sys::tr_epoll_ctl(w.tr_epfd, tcprouter_sys::EPOLL_CTL_MOD, s.server_fd, sm, tr_pack(TR_KIND_SERVER, i, s.gen));
        s.server_mask = sm;
    }
}

// --- closing ----------------------------------------------------------------------------------------------------------

// Closes both sockets, returns the connection's buffers, frees the slot and bumps its generation. After this
// the caller must not touch the slot again.
fn tr_close_conn(w: Worker&, i: i64, reason: CloseReason) {
    let s .= w.tr_slots[i];
    if !s.live { return; }
    if s.client_fd >= 0 { tcprouter_sys::tr_close(s.client_fd); }
    if s.server_fd >= 0 { tcprouter_sys::tr_close(s.server_fd); }
    s.live = false;
    s.client_fd = -1;
    s.server_fd = -1;
    s.gen = (s.gen + 1) & 0xffffff;
    let up_buf = s.up.buf;
    let down_buf = s.down.buf;
    s.up = tr_Dir { .. };
    s.down = tr_Dir { .. };
    w.tr_free_slots.push(i as u32);
    w.tr_st.open--;
    w.tr_st.closed[tr_reason_index(reason)]++;
    if up_buf >= 0 { tr_give_buf(w, up_buf); }
    if down_buf >= 0 { tr_give_buf(w, down_buf); }
}

// --- accept and connect -------------------------------------------------------------------------------------------

fn tr_accept_ready(w: Worker&, li: i64) {
    for k in 64 {                                        // a bounded batch per wakeup keeps the loop fair
        let fd = tcprouter_sys::tr_accept(w.tr_listen_fds[li]);
        if fd < 0 { return; }                            // -EAGAIN: none waiting (other errors: M3, RT-1e)
        tr_new_conn(w, li, fd);
    }
}

fn tr_reject(w: Worker&, fd: i32, reason: CloseReason) {
    tcprouter_sys::tr_close(fd);
    w.tr_st.closed[tr_reason_index(reason)]++;
}

fn tr_new_conn(w: Worker&, li: i64, fd: i32) {
    w.tr_st.accepted++;
    if w.tr_st.open >= w.cfg.limits.max_conns_per_worker { tr_reject(w, fd, CloseReason.Error); return; }

    // Port routing: nobody read a hello. NoSni means "no inspection result"; only Any routes can match.
    let nothing: Hello = Hello.NoSni;
    let route = match_route(w.cfg, w.cfg.listeners[li].id, nothing);
    guard route else { tr_reject(w, fd, CloseReason.ByHandler); return; }

    // Only forwarding exists so far (handler mode: M3).
    var target = Target { addrs: [] };
    match route.action {
        Forward f => { target = f.to; },
        _ => { tr_reject(w, fd, CloseReason.ByHandler); return; },
    }
    if target.addrs.len == 0 { tr_reject(w, fd, CloseReason.Error); return; }

    // A slot, reused when one is free.
    var i: i64 = 0;
    if w.tr_free_slots.len > 0 {
        i = w.tr_free_slots.pop();
    } else {
        i = w.tr_slots.len;
        w.tr_slots.push(tr_Slot { gen: 1, live: false, state: 0, client_fd: -1, server_fd: -1, client_mask: 0,
                                  server_mask: 0, listener: 0, user: 0, up: tr_Dir { .. }, down: tr_Dir { .. } });
    }
    let s .= w.tr_slots[i];
    s.live = true;
    s.state = TR_CONNECTING;
    s.client_fd = fd;
    s.server_fd = -1;
    s.client_mask = 0;
    s.server_mask = 0;
    s.listener = w.cfg.listeners[li].id;
    s.user = 0;
    s.up = tr_Dir { .. };
    s.down = tr_Dir { .. };
    w.tr_st.open++;

    // The built-in policy: rotate the first address from one connection to the next (retry: M3).
    let first = w.tr_rr % target.addrs.len;
    w.tr_rr++;
    tr_connect(w, i, target.addrs[first].text);
}

fn tr_connect(w: Worker&, i: i64, text: const u8[:]) {
    let s .= w.tr_slots[i];
    var p = tr_Parsed { false, [0; 16], 0 };
    if !tr_parse_addr(text, p) { w.tr_st.connect_failures++; tr_close_conn(w, i, CloseReason.ConnectFailed); return; }
    let sfd = tcprouter_sys::tr_connect_start(p.v6, p.ip, p.port);
    if sfd < 0 { w.tr_st.connect_failures++; tr_close_conn(w, i, CloseReason.ConnectFailed); return; }
    s.server_fd = sfd;
    // The client is registered with no interest: nothing of it is read before the server answers, so a
    // failed connect can still be retried with the client's bytes untouched (RT-4c).
    tcprouter_sys::tr_epoll_ctl(w.tr_epfd, tcprouter_sys::EPOLL_CTL_ADD, s.client_fd, 0, tr_pack(TR_KIND_CLIENT, i, s.gen));
    s.server_mask = tcprouter_sys::EPOLLOUT;
    tcprouter_sys::tr_epoll_ctl(w.tr_epfd, tcprouter_sys::EPOLL_CTL_ADD, sfd, s.server_mask, tr_pack(TR_KIND_SERVER, i, s.gen));
}

fn tr_connect_done(w: Worker&, i: i64) {
    let s .= w.tr_slots[i];
    let err = tcprouter_sys::tr_connect_result(s.server_fd);
    if err != 0 {
        w.tr_st.connect_failures++;
        tr_close_conn(w, i, CloseReason.ConnectFailed);
        return;
    }
    s.state = TR_FORWARDING;
    tr_update_interest(w, i);
}

// --- moving bytes -------------------------------------------------------------------------------------------------

// One read from the source of a direction (`up`: the client), then as much of it written as the destination takes.
fn tr_read(w: Worker&, i: i64, up: bool) {
    let s .= w.tr_slots[i];
    let dir .= tr_dir(s, up);
    let src = if up { s.client_fd } else { s.server_fd };
    let dst = if up { s.server_fd } else { s.client_fd };
    if !tr_can_read(dir) { return; }                      // a stale readiness: nothing to do

    if dir.buf < 0 {
        let b = tr_take_buf(w);
        if b < 0 {                                        // pool empty: wait, do not read
            dir.waiting = true;
            w.tr_waiters.push(tr_pack(if up { 1 } else { 0 }, i, s.gen));
            w.tr_st.buffer_waits++;
            tr_update_interest(w, i);
            return;
        }
        dir.buf = b;
    }
    let buf = tr_buf(w, dir.buf);
    let n = tcprouter_sys::tr_recv(src, buf[0], buf.len);
    if n > 0 {
        dir.len = n as i32;
        dir.pos = 0;
        tr_flush(w, i, up);
        return;
    }
    // Nothing to keep: give the buffer back before anything else.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    tr_give_buf(w, held);
    if n == 0 {                                           // the source ended: tell the destination, stop reading
        dir.eof = true;
        tcprouter_sys::tr_shutdown_wr(dst);
        dir.shut = true;
        tr_finish_or_update(w, i);
        return;
    }
    if n == -(tcprouter_sys::EAGAIN as i64) || n == -(tcprouter_sys::EINTR as i64) {
        tr_update_interest(w, i);
        return;
    }
    tr_close_conn(w, i, CloseReason.PeerReset);
}

// Writes the bytes a direction holds to its destination. Whatever the destination does not take stays in
// the buffer and EPOLLOUT is switched on; reading from the source stays off until it is all written.
fn tr_flush(w: Worker&, i: i64, up: bool) {
    let s .= w.tr_slots[i];
    let dir .= tr_dir(s, up);
    let dst = if up { s.server_fd } else { s.client_fd };
    while dir.pos < dir.len {
        let buf = tr_buf(w, dir.buf);
        let rest = buf[dir.pos..dir.len];
        let n = tcprouter_sys::tr_send(dst, rest[0], rest.len);
        if n > 0 {
            dir.pos += n as i32;
            if up { w.tr_st.bytes_in += n; } else { w.tr_st.bytes_out += n; }
        } else if n == -(tcprouter_sys::EAGAIN as i64) || n == -(tcprouter_sys::EINTR as i64) {
            tr_update_interest(w, i);                     // wait for EPOLLOUT
            return;
        } else {
            tr_close_conn(w, i, CloseReason.PeerReset);
            return;
        }
    }
    // Everything written: the buffer goes back, so an idle connection holds none.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    tr_give_buf(w, held);
    if dir.eof && !dir.shut {
        tcprouter_sys::tr_shutdown_wr(dst);
        dir.shut = true;
    }
    tr_finish_or_update(w, i);
}

// Both directions ended and told their destinations: the connection is over. Otherwise re-evaluate interest.
fn tr_finish_or_update(w: Worker&, i: i64) {
    let s .= w.tr_slots[i];
    if !s.live { return; }
    if s.up.eof && s.up.shut && s.down.eof && s.down.shut {
        tr_close_conn(w, i, CloseReason.PeerClosed);
        return;
    }
    tr_update_interest(w, i);
}

// --- the event loop's dispatch ---------------------------------------------------------------------------------

fn tr_dispatch(w: Worker&, data: u64, events: u32) {
    let kind = data & 0xff;
    let gen = ((data >> 8) & 0xffffff) as u32;
    let slot = (data >> 32) as i64;

    if kind == TR_KIND_LISTENER {
        if slot < w.cfg.listeners.len { tr_accept_ready(w, slot); } else { w.tr_st.bad_events++; }
        return;
    }
    // A slot number comes from the kernel's event data: check it, never trust it (RT-2c). A generation that
    // no longer matches is an event for a connection that has closed (RT-2b).
    if slot >= w.tr_slots.len { w.tr_st.bad_events++; return; }
    let s .= w.tr_slots[slot];
    if !s.live || s.gen != gen { w.tr_st.stale_events++; return; }

    let failed = (events & (tcprouter_sys::EPOLLERR | tcprouter_sys::EPOLLHUP)) != 0;
    if s.state == TR_CONNECTING {
        if kind == TR_KIND_SERVER { tr_connect_done(w, slot); }
        else if failed { tr_close_conn(w, slot, CloseReason.PeerReset); }
        return;
    }
    let from_client = kind == TR_KIND_CLIENT;
    if (events & tcprouter_sys::EPOLLERR) != 0 { tr_close_conn(w, slot, CloseReason.PeerReset); return; }
    if (events & tcprouter_sys::EPOLLOUT) != 0 {
        tr_flush(w, slot, !from_client);                  // client writable: finish `down`; server writable: `up`
        if !s.live { return; }
    }
    if (events & (tcprouter_sys::EPOLLIN | tcprouter_sys::EPOLLHUP)) != 0 {
        let dir .= tr_dir(s, from_client);
        if (events & tcprouter_sys::EPOLLIN) == 0 && !tr_can_read(dir) {
            tr_close_conn(w, slot, CloseReason.PeerReset);    // hung up while we were not reading it
            return;
        }
        tr_read(w, slot, from_client);
    }
}
