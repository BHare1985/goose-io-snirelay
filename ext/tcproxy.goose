// tcprouter's forwarding as an extension of the goose-io epoll event loop. This is the forward pump of tcprouter's conn.goose (`_pump`,
// `_pump_direction`, `_write_buffer`, `_run_ready`, `_connect_finished` and the forwarding arm of `_dispatch_event`), kept as it was, but
// living in the application's own type and called through the loop's seam (examples/loops/epoll/seam.goose) instead of inside a worker of
// its own. The loop owns the epoll instance, the accept, the slot table, the buffer pool and the timers; this file owns what happens to
// the bytes of a forwarded connection. Nothing of tcprouter's engine is used.
//
// Stage 1 (this file): a listener forwards to one fixed target. Routes, SNI inspection, retry, policy, tags and deadlines are the next
// stages; each is state that this extension keeps per slot, as the seam's text says.
//
//     var fwd = tcproxy::Forwarder { .. };
//     tcproxy::route(fwd, listener, "127.0.0.1:9100");
//     io.serve(fwd) { io, ev => };
//
// Forwarded sockets are registered with epoll ONCE, edge-triggered (EPOLLIN|OUT|RDHUP|ET), and never modified again: an event only sets a
// readiness flag, and `_pump` moves bytes until a flag runs out (recv or send says EAGAIN, or a short read drained the socket). A pump that
// stops because of its byte budget puts the connection on the ready list, because an edge will not be reported again.
namespace tcproxy;

import std;
import goose_io;
import epoll;

let CONNECTING: u8 = 1;              // the connect to the target is in progress; the client is not read yet
let FORWARDING: u8 = 2;

let READY_CLIENT_IN: u8 = 1;
let READY_CLIENT_OUT: u8 = 2;
let READY_SERVER_IN: u8 = 4;
let READY_SERVER_OUT: u8 = 8;
let READY_CLIENT_ENDED: u8 = 16;
let READY_SERVER_ENDED: u8 = 32;

let WAKEUP_BUDGET: i64 = 65536;      // bytes one direction may move per wakeup before others get a turn

let EPOLLIN: u32 = 0x001;
let EPOLLOUT: u32 = 0x004;
let EPOLLERR: u32 = 0x008;
let EPOLLHUP: u32 = 0x010;
let EPOLLRDHUP: u32 = 0x2000;

// One direction of a forwarded connection. It owns at most ONE pool buffer, and only while it holds bytes it has read but not yet written.
struct Direction {
    buf: i32 = -1,
    len: i32 = 0,
    pos: i32 = 0,
    eof: bool = false,
    shut: bool = false,
    waiting: bool = false,
}

struct PSlot {
    gen: u32 = 0,
    live: bool = false,
    state: u8 = 0,
    client_fd: i32 = -1,
    server_fd: i32 = -1,
    ready: u8 = 0,
    queued: bool = false,
    started_ms: i64 = 0,
    last_active_ms: i64 = 0,
    half_closed_at_ms: i64 = 0,
    up: Direction = Direction { .. },
    down: Direction = Direction { .. },
}

root struct Forwarder {
    listener: u32 = 0,                       // the listener whose connections are forwarded
    target: u8[..56] = [],                   // where they go
    slots: PSlot[>..] = [],                  // indexed by the loop's slot
    ready: u64[>..<] = [],                   // connections with work left after a pass
    ready_head: i64 = 0,
}

// Forwards every connection the listener accepts to `target`.
fn route(f: Forwarder&, l: goose_io::Listener, target: const u8[:]) {
    f.listener = l.id;
    f.target.append(target);
}

fn pack(slot: i64, gen: u32) -> u64 { return ((gen as u64) << 8) | ((slot as u64) << 32); }

// --- the hooks of the seam ------------------------------------------------------------------------

fn on_accept(f: Forwarder&, io: epoll::Loop&, listener: u32, fd: i32) -> bool {
    if f.listener == 0 || listener != f.listener { return false; }
    let slot = io.ext_open(fd, listener);
    while f.slots.len <= slot { f.slots.push(PSlot { .. }); }
    let s .= f.slots[slot];
    s.gen = io.ext_gen(slot);
    s.live = true;
    s.state = CONNECTING;
    s.client_fd = fd;
    s.server_fd = -1;
    s.ready = 0;
    s.queued = false;
    s.started_ms = io.ext_now();
    s.last_active_ms = s.started_ms;
    s.half_closed_at_ms = 0;
    s.up = Direction { .. };
    s.down = Direction { .. };
    if !io.ext_register(slot, fd, false, EPOLLIN | EPOLLOUT | EPOLLRDHUP, true) { f.end(io, slot, goose_io::CloseReason.Error); return true; }
    let sfd = io.ext_connect(f.target[..]);
    if sfd < 0 {
        io.ext_stats().connect_failures++;
        f.end(io, slot, goose_io::CloseReason.ConnectFailed { kind: epoll::ext_connect_kind(-sfd) });
        return true;
    }
    s.server_fd = sfd;
    if !io.ext_register(slot, sfd, true, EPOLLIN | EPOLLOUT | EPOLLRDHUP, true) { f.end(io, slot, goose_io::CloseReason.Error); }
    return true;
}

fn has_work(f: Forwarder&) -> bool { return f.ready_head < f.ready.len; }

// The forwarding arm of the dispatch: the event only says what the sockets can do now.
fn on_event(f: Forwarder&, io: epoll::Loop&, slot: i64, second: bool, events: u32) {
    let s .= f.slots[slot];
    let from_client = !second;
    let in_flag = if from_client { READY_CLIENT_IN } else { READY_SERVER_IN };
    let out_flag = if from_client { READY_CLIENT_OUT } else { READY_SERVER_OUT };
    let ended_flag = if from_client { READY_CLIENT_ENDED } else { READY_SERVER_ENDED };
    if (events & (EPOLLIN | EPOLLHUP | EPOLLRDHUP)) != 0 { s.ready |= in_flag; }
    if (events & (EPOLLOUT | EPOLLHUP)) != 0 { s.ready |= out_flag; }       // a hung-up socket "can write": the write fails and says so
    if (events & (EPOLLRDHUP | EPOLLHUP)) != 0 { s.ready |= ended_flag; }
    if s.state == CONNECTING {
        // A client that hangs up while we connect is only noted (its flags): the connect finishes or fails first.
        if !from_client { f.connect_finished(io, slot); }
        return;
    }
    if (events & EPOLLERR) != 0 {
        if from_client { f.end(io, slot, goose_io::CloseReason.PeerReset); return; }
        // The backend reset the connection. Bytes it sent before the RST are still readable (Linux), and "answer, then reset" is what a server does
        // when it closes with unread request bytes: deliver them first. The next read says ECONNRESET and closes.
        s.ready |= in_flag | out_flag;
        f.pump(io, slot);
        if s.live && s.state == FORWARDING && !s.queued && s.up.len <= s.up.pos && s.down.len <= s.down.pos { f.end(io, slot, goose_io::CloseReason.PeerReset); }
        return;
    }
    f.pump(io, slot);
}

// Once per pass, after the events: buffers that came back wake the reads that waited for them, then the queued connections run.
fn on_ready(f: Forwarder&, io: epoll::Loop&) {
    f.wake_waiters(io);
    f.run_ready(io);
    f.wake_waiters(io);
}

// The idle, half-close and connect limits of the forwarded connections.
fn on_sweep(f: Forwarder&, io: epoll::Loop&, now: i64) {
    let limits = io.limits;
    for i in f.slots.len {
        let s .= f.slots[i];
        if !s.live { continue; }
        if s.state == CONNECTING {
            if s.server_fd >= 0 && now - s.started_ms >= limits.connect_timeout_ms {
                io.ext_stats().connect_failures++;
                f.end(io, i, goose_io::CloseReason.ConnectFailed { kind: goose_io::ConnectFailure.TimedOut });
            }
        } else if s.half_closed_at_ms != 0 {
            let since = if s.last_active_ms > s.half_closed_at_ms { s.last_active_ms } else { s.half_closed_at_ms };
            if now - since >= limits.half_close_timeout_ms { f.end(io, i, goose_io::CloseReason.HalfCloseTimeout); }
        } else if now - s.last_active_ms >= limits.idle_timeout_ms {
            f.end(io, i, goose_io::CloseReason.IdleTimeout);
        }
    }
}

// The grace period ended: every forwarded connection still open ends.
fn on_stop(f: Forwarder&, io: epoll::Loop&) {
    for i in f.slots.len { if f.slots[i].live { f.end(io, i, goose_io::CloseReason.Shutdown); } }
}

// --- the pump (tcprouter's conn.goose) -----------------------------------------------------------

// Closes both sockets, returns the buffers and frees the slot at once (a forwarded connection has no Closed to wait for).
fn end(f: Forwarder&, io: epoll::Loop&, slot: i64, reason: goose_io::CloseReason) {
    let s .= f.slots[slot];
    if !s.live { return; }
    s.live = false;
    if s.server_fd >= 0 { epoll::c_close(s.server_fd); s.server_fd = -1; }
    let up_buf = s.up.buf;
    let down_buf = s.down.buf;
    s.up = Direction { .. };
    s.down = Direction { .. };
    io.ext_free(slot, reason);                  // closes the client socket and frees the slot
    if up_buf >= 0 { io.ext_give_buffer(up_buf); }
    if down_buf >= 0 { io.ext_give_buffer(down_buf); }
}

fn connect_finished(f: Forwarder&, io: epoll::Loop&, slot: i64) {
    let s .= f.slots[slot];
    let err = epoll::c_connect_result(s.server_fd);
    if err != 0 {
        io.ext_stats().connect_failures++;
        f.end(io, slot, goose_io::CloseReason.ConnectFailed { kind: epoll::ext_connect_kind(err) });
        return;
    }
    s.state = FORWARDING;
    s.ready |= READY_SERVER_OUT;                 // a finished connect is writable; its edge was this event
    f.pump(io, slot);
}

fn wake_waiters(f: Forwarder&, io: epoll::Loop&) {
    var slot: i64 = 0;
    var gen: u32 = 0;
    var kind: i64 = 0;
    while io.ext_pop_woken(slot, gen, kind) {
        if slot < f.slots.len && f.slots[slot].live && f.slots[slot].gen == gen {
            let d .= f.direction_of(slot, kind == 0);
            if d.waiting { d.waiting = false; f.queue_ready(slot); }
        }
    }
}

fn direction_of(f: Forwarder&, slot: i64, up: bool) -> Direction& {
    if up { return f.slots[slot].up; }
    f.slots[slot].down
}

// Adds a connection to the ready list: it has work left that no event will announce.
fn queue_ready(f: Forwarder&, slot: i64) {
    let s .= f.slots[slot];
    if !s.live || s.queued { return; }
    s.queued = true;
    f.ready.push(pack(slot, s.gen));
}

// Runs the connections queued so far (those queued meanwhile wait for the next pass, so nobody is starved).
fn run_ready(f: Forwarder&, io: epoll::Loop&) {
    let end = f.ready.len;
    while f.ready_head < end {
        let e = f.ready[f.ready_head];
        f.ready_head++;
        let slot = (e >> 32) as i64;
        let gen = ((e >> 8) & 0xffffff) as u32;
        let s .= f.slots[slot];
        if s.live && s.gen == gen {
            s.queued = false;
            if s.state == FORWARDING { f.pump(io, slot); }
        }
    }
    let left = f.ready.len - f.ready_head;
    if left == 0 {
        f.ready.clear();
        f.ready_head = 0;
    } else if f.ready_head > 0 {
        for k in left { f.ready[k] = f.ready[f.ready_head + k]; }
        f.ready.pop_n(f.ready_head);
        f.ready_head = 0;
    }
}

// Moves bytes in both directions as far as the readiness flags allow.
fn pump(f: Forwarder&, io: epoll::Loop&, slot: i64) {
    let s .= f.slots[slot];
    let more_up = f.pump_direction(io, slot, true);
    if !s.live { return; }
    let more_down = f.pump_direction(io, slot, false);
    if !s.live { return; }
    if more_up || more_down { f.queue_ready(slot); }
}

fn flag_readable(up: bool) -> u8 { if up { READY_CLIENT_IN } else { READY_SERVER_IN } }
fn flag_writable(up: bool) -> u8 { if up { READY_SERVER_OUT } else { READY_CLIENT_OUT } }
fn flag_ended(up: bool) -> u8 { if up { READY_CLIENT_ENDED } else { READY_SERVER_ENDED } }

// Reads from the source and writes to the destination of one direction (`up`: client to server) until one of them has nothing more to
// give or take. True when it stopped only because it moved WAKEUP_BUDGET bytes (the connection is queued to go on).
fn pump_direction(f: Forwarder&, io: epoll::Loop&, slot: i64, up: bool) -> bool {
    let s .= f.slots[slot];
    let dir .= f.direction_of(slot, up);
    let src = if up { s.client_fd } else { s.server_fd };
    let dst = if up { s.server_fd } else { s.client_fd };
    let readable = flag_readable(up);
    let writable = flag_writable(up);
    var moved: i64 = 0;
    loop {
        if dir.len > dir.pos {                                        // bytes read but not written yet
            if (s.ready & writable) == 0 { return false; }            // destination full: its writable edge restarts us
            if !f.write_buffer(io, slot, up, dst) { return false; }
        }
        if dir.eof || dir.waiting { return false; }
        if (s.ready & readable) == 0 { return false; }
        if moved >= WAKEUP_BUDGET { return true; }

        let b = io.ext_take_buffer();
        if b < 0 {                                                    // pool empty: wait, do not read
            dir.waiting = true;
            io.ext_wait_buffer(slot, if up { 0 } else { 1 });
            return false;
        }
        dir.buf = b;
        let buf = io.ext_buffer(b);
        let n = epoll::c_recv(src, buf[0], buf.len);
        if n > 0 {
            dir.len = n as i32;
            dir.pos = 0;
            moved += n;
            s.last_active_ms = io.ext_now();
            // A short read means the socket is drained, unless its peer already ended: then the next read says so.
            if n < buf.len && (s.ready & flag_ended(up)) == 0 { s.ready = s.ready & (255 - readable); }
            continue;
        }
        // Nothing to keep: give the buffer back before anything else.
        let held = dir.buf;
        dir.buf = -1;
        dir.len = 0;
        dir.pos = 0;
        io.ext_give_buffer(held);
        if n == 0 {                                                   // the source ended: tell the destination, stop reading
            dir.eof = true;
            if s.half_closed_at_ms == 0 { s.half_closed_at_ms = io.ext_now(); }
            let other .= f.direction_of(slot, !up);
            if !(other.eof && other.shut) { epoll::c_shutdown_wr(dst); }   // else the close itself sends the FIN
            dir.shut = true;
            if s.up.eof && s.up.shut && s.down.eof && s.down.shut { f.end(io, slot, goose_io::CloseReason.PeerClosed); }
            return false;
        }
        if n == -(epoll::c_EAGAIN as i64) { s.ready = s.ready & (255 - readable); return false; }
        if n == -(epoll::c_EINTR as i64) { return true; }             // interrupted: try again on the next pass
        f.end(io, slot, goose_io::CloseReason.PeerReset);
        return false;
    }
}

// Writes what a direction holds. True when all of it went out (the buffer is back in the pool); false when the destination is full
// (its writable flag is cleared) or the connection ended.
fn write_buffer(f: Forwarder&, io: epoll::Loop&, slot: i64, up: bool, dst: i32) -> bool {
    let s .= f.slots[slot];
    let dir .= f.direction_of(slot, up);
    while dir.pos < dir.len {
        let buf = io.ext_buffer(dir.buf);
        let rest = buf[dir.pos..dir.len];
        let n = epoll::c_send(dst, rest[0], rest.len);
        if n > 0 {
            dir.pos += n as i32;
            s.last_active_ms = io.ext_now();
            if up { io.ext_stats().bytes_in += n; } else { io.ext_stats().bytes_out += n; }
        } else if n == -(epoll::c_EAGAIN as i64) {
            s.ready = s.ready & (255 - flag_writable(up));
            return false;
        } else if n != -(epoll::c_EINTR as i64) {
            f.end(io, slot, goose_io::CloseReason.PeerReset);
            return false;
        }
    }
    // Everything written: the buffer goes back, so an idle connection holds none.
    let held = dir.buf;
    dir.buf = -1;
    dir.len = 0;
    dir.pos = 0;
    io.ext_give_buffer(held);
    return true;
}
