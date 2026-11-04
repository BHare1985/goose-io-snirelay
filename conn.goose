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

let ROUTER_STATE_CONNECTING: u8 = 1;       // the connect to the server is in progress; the client is not read yet
let ROUTER_STATE_FORWARDING: u8 = 2;

let ROUTER_EVENT_KIND_LISTENER: u64 = 1;
let ROUTER_EVENT_KIND_CLIENT: u64 = 2;
let ROUTER_EVENT_KIND_SERVER: u64 = 3;

// One direction of a connection.
struct router_Direction {
    buf: i32 = -1,               // pool buffer holding unwritten bytes, or -1
    len: i32 = 0,                // bytes in the buffer
    pos: i32 = 0,                // bytes of them already written
    eof: bool = false,           // the source has ended
    shut: bool = false,          // the destination was told (shutdown of its write side)
    waiting: bool = false,       // queued for a buffer
}

struct router_ConnectionSlot {
    gen: u32,                    // bumped when the connection closes: stale events and handles are ignored
    live: bool,
    state: u8,
    client_fd: i32,
    server_fd: i32,
    client_mask: u32,            // the epoll interest set now on each fd
    server_mask: u32,
    listener: u16,
    user: u32,
    up: router_Direction,                  // client to server
    down: router_Direction,                // server to client
}

// --- epoll data: what an event is about ---------------------------------------------------------------------

// kind in the low 8 bits, generation in the next 24, slot index in the high 32.
fn router_pack_event_data(kind: u64, slot: i64, gen: u32) -> u64 {
    return kind | ((gen as u64) << 8) | ((slot as u64) << 32);
}

// --- small helpers -------------------------------------------------------------------------------------------------

fn router_pause_milliseconds(ms: i64) { sleep_ms(ms); }

// Fills w.error with "<what> <where>: <strerror(err)>" and returns false, for start().
fn router_fail_start(w: Worker&, what: const u8[:], where: const u8[:], err: i32) -> bool {
    var msg: u8[>..] = [];
    format(msg, what, " ", where, ": ");
    router_error_text(msg, err);
    let n = if msg.len < w.error.cap { msg.len } else { w.error.cap };
    w.error.append(msg[..n]);
    return false;
}

fn router_close_reason_index(r: CloseReason) -> i64 {
    return match r {
        PeerClosed => 0, PeerReset => 1, IdleTimeout => 2, HalfCloseTimeout => 3, InspectTimeout => 4,
        ConnectFailed => 5, Fenced => 6, Drained => 7, ByHandler => 8, Error => 9,
    };
}

// spawn() asks, before any worker exists, whether each listener address can be bound by a plain socket.
// If another process holds the port this is an error here and now, instead of workers silently sharing
// the port with it through SO_REUSEPORT (RT-1d).
fn router_probe_listeners(cfg: Config) {
    for li in cfg.listeners.len {
        var p = router_ParsedAddress { false, [0; 16], 0 };
        let text = cfg.listeners[li].addr.text;
        if !router_parse_address(text, p) { continue; }                 // check() reports bad text; start() fails
        let fd = router_socket_listen(p.v6, p.ip, p.port, false, 1);
        if fd < 0 {
            var msg: u8[>..] = [];
            format(msg, "cannot listen on ", text, ": ");
            router_error_text(msg, -fd);
            let n = if msg.len < router_spawn_error.cap { msg.len } else { router_spawn_error.cap };
            router_spawn_error.append(msg[..n]);
            return;
        }
        router_socket_close(fd);
    }
}

// --- the buffer pool -------------------------------------------------------------------------------------------------

// The pool grows lazily, one buffer at a time, up to buffers_per_worker: an idle worker touches no
// buffer memory. Growth only appends, so a buffer the kernel is writing into never moves (design/09 O-3).
// Returns a buffer number, or -1 when all of them are in use.
fn router_take_buffer(w: Worker&) -> i32 {
    var id: i32 = -1;
    if w.router_free_buffers.len > 0 {
        id = w.router_free_buffers.pop();
    } else if w.router_stats.buffers_total < w.cfg.limits.buffers_per_worker {
        id = w.router_stats.buffers_total as i32;
        for k in w.cfg.limits.buffer_size { w.router_buffer_pool.push(0); }
        w.router_stats.buffers_total++;
    }
    if id >= 0 { w.router_stats.buffers_in_use++; }
    return id;
}

fn router_buffer_slice(w: Worker&, id: i32) -> u8[:] {
    let size = w.cfg.limits.buffer_size;
    return w.router_buffer_pool[id * size..(id + 1) * size];
}

// Returns a buffer to the pool and lets the oldest read that was waiting for one try again.
fn router_give_back_buffer(w: Worker&, id: i32) {
    w.router_free_buffers.push(id);
    w.router_stats.buffers_in_use--;
    router_wake_waiting_read(w);
}

fn router_wake_waiting_read(w: Worker&) {
    while w.router_waiting_reads_head < w.router_waiting_reads.len {
        let e = w.router_waiting_reads[w.router_waiting_reads_head];
        w.router_waiting_reads_head++;
        let slot = (e >> 32) as i64;
        let gen = ((e >> 8) & 0xffffff) as u32;
        let up = (e & 1) == 1;
        if slot < w.router_connection_slots.len {
            let s .= w.router_connection_slots[slot];
            if s.live && s.gen == gen {
                let dir .= router_direction_of(s, up);
                if dir.waiting {
                    dir.waiting = false;
                    router_update_epoll_interest(w, slot);
                    break;
                }
            }
        }
    }
    if w.router_waiting_reads_head >= w.router_waiting_reads.len {
        w.router_waiting_reads.clear();
        w.router_waiting_reads_head = 0;
    }
}

// --- interest ---------------------------------------------------------------------------------------------------------

// The direction a read or flush works on (`up`: client to server). A function, because `.=` needs a reference
// and an `if` of two fields is not one.
fn router_direction_of(s: router_ConnectionSlot&, up: bool) -> router_Direction& {
    if up { return s.up; }
    return s.down;
}

fn router_direction_can_read(d: router_Direction) -> bool { return !d.eof && !d.waiting && d.len == d.pos; }
fn router_direction_has_pending_bytes(d: router_Direction) -> bool { return d.len > d.pos; }

// Sets each fd's epoll interest to what the slot's state needs: read a source only when its direction has
// nothing unwritten and is not waiting for a buffer; wait for writability only where bytes are pending.
fn router_update_epoll_interest(w: Worker&, i: i64) {
    let s .= w.router_connection_slots[i];
    if !s.live || s.state != ROUTER_STATE_FORWARDING { return; }
    var cm: u32 = 0;
    var sm: u32 = 0;
    if router_direction_can_read(s.up) { cm |= ROUTER_EPOLL_IN; }
    if router_direction_has_pending_bytes(s.down) { cm |= ROUTER_EPOLL_OUT; }
    if router_direction_can_read(s.down) { sm |= ROUTER_EPOLL_IN; }
    if router_direction_has_pending_bytes(s.up) { sm |= ROUTER_EPOLL_OUT; }
    if cm != s.client_mask {
        router_epoll_control(w.router_epoll_fd, ROUTER_EPOLL_CTL_MOD, s.client_fd, cm, router_pack_event_data(ROUTER_EVENT_KIND_CLIENT, i, s.gen));
        s.client_mask = cm;
    }
    if sm != s.server_mask {
        router_epoll_control(w.router_epoll_fd, ROUTER_EPOLL_CTL_MOD, s.server_fd, sm, router_pack_event_data(ROUTER_EVENT_KIND_SERVER, i, s.gen));
        s.server_mask = sm;
    }
}

// --- closing ----------------------------------------------------------------------------------------------------------

// Closes both sockets, returns the connection's buffers, frees the slot and bumps its generation. After this
// the caller must not touch the slot again.
fn router_close_connection(w: Worker&, i: i64, reason: CloseReason) {
    let s .= w.router_connection_slots[i];
    if !s.live { return; }
    if s.client_fd >= 0 { router_socket_close(s.client_fd); }
    if s.server_fd >= 0 { router_socket_close(s.server_fd); }
    s.live = false;
    s.client_fd = -1;
    s.server_fd = -1;
    s.gen = (s.gen + 1) & 0xffffff;
    let up_buf = s.up.buf;
    let down_buf = s.down.buf;
    s.up = router_Direction { .. };
    s.down = router_Direction { .. };
    w.router_free_slots.push(i as u32);
    w.router_stats.open--;
    w.router_stats.closed[router_close_reason_index(reason)]++;
    if up_buf >= 0 { router_give_back_buffer(w, up_buf); }
    if down_buf >= 0 { router_give_back_buffer(w, down_buf); }
}

// --- accept and connect -------------------------------------------------------------------------------------------

// How long a listener is left alone after accept failed for lack of a resource (descriptors, memory, buffers).
let ROUTER_ACCEPT_PAUSE_MILLISECONDS: i64 = 100;

fn router_accept_ready_connections(w: Worker&, li: i64) {
    for k in 64 {                                        // a bounded batch per wakeup keeps the loop fair
        let fd = router_socket_accept(w.router_listen_fds[li]);
        if fd >= 0 { router_new_connection(w, li, fd); continue; }
        let error = -fd;
        if error == ROUTER_ERRNO_AGAIN || error == ROUTER_ERRNO_INTERRUPTED { return; }       // nobody is waiting
        if error == ROUTER_ERRNO_CONNECTION_ABORTED || error == ROUTER_ERRNO_PROTOCOL { continue; }   // that client left
        // Out of descriptors, memory or socket buffers (EMFILE, ENFILE, ENOMEM, ENOBUFS...): nothing we do right now
        // can fix it, and epoll is level-triggered, so the pending connection would wake us again at once and we
        // would spin. Leave this listener out of epoll for a moment; the clients wait in the kernel's backlog
        // and are served when descriptors come back (RT-1e).
        w.router_stats.accept_failures++;
        router_pause_listener(w, li);
        return;
    }
}

fn router_pause_listener(w: Worker&, li: i64) {
    router_epoll_control(w.router_epoll_fd, ROUTER_EPOLL_CTL_MOD, w.router_listen_fds[li], 0,
                         router_pack_event_data(ROUTER_EVENT_KIND_LISTENER, li, 0));
    w.router_listener_resume_at[li] = router_boottime_milliseconds() + ROUTER_ACCEPT_PAUSE_MILLISECONDS;
}

// Puts back into epoll the listeners whose pause is over. Called once per pass of the loop.
fn router_resume_paused_listeners(w: Worker&, now: i64) {
    for li in w.cfg.listeners.len {
        if w.router_listener_resume_at[li] != 0 && now >= w.router_listener_resume_at[li] {
            w.router_listener_resume_at[li] = 0;
            router_epoll_control(w.router_epoll_fd, ROUTER_EPOLL_CTL_MOD, w.router_listen_fds[li], ROUTER_EPOLL_IN,
                                 router_pack_event_data(ROUTER_EVENT_KIND_LISTENER, li, 0));
        }
    }
}

fn router_reject_connection(w: Worker&, fd: i32, reason: CloseReason) {
    router_socket_close(fd);
    w.router_stats.closed[router_close_reason_index(reason)]++;
}

fn router_new_connection(w: Worker&, li: i64, fd: i32) {
    w.router_stats.accepted++;
    if w.router_stats.open >= w.cfg.limits.max_conns_per_worker { router_reject_connection(w, fd, CloseReason.Error); return; }

    // Port routing: nobody read a hello. NoSni means "no inspection result"; only Any routes can match.
    let nothing: Hello = Hello.NoSni;
    let route = match_route(w.cfg, w.cfg.listeners[li].id, nothing);
    guard route else { router_reject_connection(w, fd, CloseReason.ByHandler); return; }

    // Only forwarding exists so far (handler mode: M3).
    var target = Target { addrs: [] };
    match route.action {
        Forward f => { target = f.to; },
        _ => { router_reject_connection(w, fd, CloseReason.ByHandler); return; },
    }
    if target.addrs.len == 0 { router_reject_connection(w, fd, CloseReason.Error); return; }

    // A slot, reused when one is free.
    var i: i64 = 0;
    if w.router_free_slots.len > 0 {
        i = w.router_free_slots.pop();
    } else {
        i = w.router_connection_slots.len;
        w.router_connection_slots.push(router_ConnectionSlot { gen: 1, live: false, state: 0, client_fd: -1, server_fd: -1, client_mask: 0,
                                  server_mask: 0, listener: 0, user: 0, up: router_Direction { .. }, down: router_Direction { .. } });
    }
    let s .= w.router_connection_slots[i];
    s.live = true;
    s.state = ROUTER_STATE_CONNECTING;
    s.client_fd = fd;
    s.server_fd = -1;
    s.client_mask = 0;
    s.server_mask = 0;
    s.listener = w.cfg.listeners[li].id;
    s.user = 0;
    s.up = router_Direction { .. };
    s.down = router_Direction { .. };
    w.router_stats.open++;

    // The built-in policy: rotate the first address from one connection to the next (retry: M3).
    let first = w.router_round_robin % target.addrs.len;
    w.router_round_robin++;
    router_connect_to_target(w, i, target.addrs[first].text);
}

fn router_connect_to_target(w: Worker&, i: i64, text: const u8[:]) {
    let s .= w.router_connection_slots[i];
    var p = router_ParsedAddress { false, [0; 16], 0 };
    if !router_parse_address(text, p) { w.router_stats.connect_failures++; router_close_connection(w, i, CloseReason.ConnectFailed); return; }
    let sfd = router_socket_connect_start(p.v6, p.ip, p.port);
    if sfd < 0 { w.router_stats.connect_failures++; router_close_connection(w, i, CloseReason.ConnectFailed); return; }
    s.server_fd = sfd;
    // The client is registered with no interest: nothing of it is read before the server answers, so a
    // failed connect can still be retried with the client's bytes untouched (RT-4c).
    router_epoll_control(w.router_epoll_fd, ROUTER_EPOLL_CTL_ADD, s.client_fd, 0, router_pack_event_data(ROUTER_EVENT_KIND_CLIENT, i, s.gen));
    s.server_mask = ROUTER_EPOLL_OUT;
    router_epoll_control(w.router_epoll_fd, ROUTER_EPOLL_CTL_ADD, sfd, s.server_mask, router_pack_event_data(ROUTER_EVENT_KIND_SERVER, i, s.gen));
}

fn router_connect_finished(w: Worker&, i: i64) {
    let s .= w.router_connection_slots[i];
    let err = router_socket_connect_result(s.server_fd);
    if err != 0 {
        w.router_stats.connect_failures++;
        router_close_connection(w, i, CloseReason.ConnectFailed);
        return;
    }
    s.state = ROUTER_STATE_FORWARDING;
    router_update_epoll_interest(w, i);
}

// --- moving bytes -------------------------------------------------------------------------------------------------

// One read from the source of a direction (`up`: the client), then as much of it written as the destination takes.
fn router_read_direction(w: Worker&, i: i64, up: bool) {
    let s .= w.router_connection_slots[i];
    let dir .= router_direction_of(s, up);
    let src = if up { s.client_fd } else { s.server_fd };
    let dst = if up { s.server_fd } else { s.client_fd };
    if !router_direction_can_read(dir) { return; }                      // a stale readiness: nothing to do

    if dir.buf < 0 {
        let b = router_take_buffer(w);
        if b < 0 {                                        // pool empty: wait, do not read
            dir.waiting = true;
            w.router_waiting_reads.push(router_pack_event_data(if up { 1 } else { 0 }, i, s.gen));
            w.router_stats.buffer_waits++;
            router_update_epoll_interest(w, i);
            return;
        }
        dir.buf = b;
    }
    let buf = router_buffer_slice(w, dir.buf);
    let n = router_socket_receive(src, buf[0], buf.len);
    if n > 0 {
        dir.len = n as i32;
        dir.pos = 0;
        router_flush_direction(w, i, up);
        return;
    }
    // Nothing to keep: give the buffer back before anything else.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    router_give_back_buffer(w, held);
    if n == 0 {                                           // the source ended: tell the destination, stop reading
        dir.eof = true;
        router_socket_shutdown_write(dst);
        dir.shut = true;
        router_finish_or_update_interest(w, i);
        return;
    }
    if n == -(ROUTER_ERRNO_AGAIN as i64) || n == -(ROUTER_ERRNO_INTERRUPTED as i64) {
        router_update_epoll_interest(w, i);
        return;
    }
    router_close_connection(w, i, CloseReason.PeerReset);
}

// Writes the bytes a direction holds to its destination. Whatever the destination does not take stays in
// the buffer and EPOLLOUT is switched on; reading from the source stays off until it is all written.
fn router_flush_direction(w: Worker&, i: i64, up: bool) {
    let s .= w.router_connection_slots[i];
    let dir .= router_direction_of(s, up);
    let dst = if up { s.server_fd } else { s.client_fd };
    while dir.pos < dir.len {
        let buf = router_buffer_slice(w, dir.buf);
        let rest = buf[dir.pos..dir.len];
        let n = router_socket_send(dst, rest[0], rest.len);
        if n > 0 {
            dir.pos += n as i32;
            if up { w.router_stats.bytes_in += n; } else { w.router_stats.bytes_out += n; }
        } else if n == -(ROUTER_ERRNO_AGAIN as i64) || n == -(ROUTER_ERRNO_INTERRUPTED as i64) {
            router_update_epoll_interest(w, i);                     // wait for EPOLLOUT
            return;
        } else {
            router_close_connection(w, i, CloseReason.PeerReset);
            return;
        }
    }
    // Everything written: the buffer goes back, so an idle connection holds none.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    router_give_back_buffer(w, held);
    if dir.eof && !dir.shut {
        router_socket_shutdown_write(dst);
        dir.shut = true;
    }
    router_finish_or_update_interest(w, i);
}

// Both directions ended and told their destinations: the connection is over. Otherwise re-evaluate interest.
fn router_finish_or_update_interest(w: Worker&, i: i64) {
    let s .= w.router_connection_slots[i];
    if !s.live { return; }
    if s.up.eof && s.up.shut && s.down.eof && s.down.shut {
        router_close_connection(w, i, CloseReason.PeerClosed);
        return;
    }
    router_update_epoll_interest(w, i);
}

// --- the event loop's dispatch ---------------------------------------------------------------------------------

fn router_dispatch_event(w: Worker&, data: u64, events: u32) {
    let kind = data & 0xff;
    let gen = ((data >> 8) & 0xffffff) as u32;
    let slot = (data >> 32) as i64;

    // The kind comes from the kernel's event data too: anything but the three we hand out is bad (RT-2c).
    if kind == ROUTER_EVENT_KIND_LISTENER {
        if slot < w.cfg.listeners.len { router_accept_ready_connections(w, slot); } else { w.router_stats.bad_events++; }
        return;
    }
    if kind != ROUTER_EVENT_KIND_CLIENT && kind != ROUTER_EVENT_KIND_SERVER { w.router_stats.bad_events++; return; }
    // A slot number comes from the kernel's event data: check it, never trust it (RT-2c). A generation that
    // no longer matches is an event for a connection that has closed (RT-2b).
    if slot >= w.router_connection_slots.len { w.router_stats.bad_events++; return; }
    let s .= w.router_connection_slots[slot];
    if !s.live || s.gen != gen { w.router_stats.stale_events++; return; }

    let failed = (events & (ROUTER_EPOLL_ERROR | ROUTER_EPOLL_HANGUP)) != 0;
    if s.state == ROUTER_STATE_CONNECTING {
        if kind == ROUTER_EVENT_KIND_SERVER { router_connect_finished(w, slot); }
        else if failed { router_close_connection(w, slot, CloseReason.PeerReset); }
        return;
    }
    let from_client = kind == ROUTER_EVENT_KIND_CLIENT;
    if (events & ROUTER_EPOLL_ERROR) != 0 { router_close_connection(w, slot, CloseReason.PeerReset); return; }
    if (events & ROUTER_EPOLL_OUT) != 0 {
        router_flush_direction(w, slot, !from_client);                  // client writable: finish `down`; server writable: `up`
        if !s.live { return; }
    }
    if (events & (ROUTER_EPOLL_IN | ROUTER_EPOLL_HANGUP)) != 0 {
        let dir .= router_direction_of(s, from_client);
        if (events & ROUTER_EPOLL_IN) == 0 && !router_direction_can_read(dir) {
            router_close_connection(w, slot, CloseReason.PeerReset);    // hung up while we were not reading it
            return;
        }
        router_read_direction(w, slot, from_client);
    }
}
