// Handler mode: the user's code gets a connection as events and answers with send, close, reset, forward...
// (design/02-api.md section 4; design/03-engine.md). The public functions are at the top, the machinery below.
//
// Events are not delivered from inside the epoll dispatch. The engine appends flat records to a queue and `serve`
// drains it after each batch, calling the user's block once per record: no engine function has to be generic over the
// block, events of one connection stay in order, and a Data event keeps its pool buffer until the block returns.
namespace tcprouter;

import .config;
import .engine;
import .conn;

// --- the calls a handler block may make --------------------------------------------------------------------

// Queues bytes to the peer and writes what the socket takes at once. All or nothing: false (and nothing queued) if the
// connection is gone or closing, or if the bytes do not fit the queue. The queue holds at most 4 pool buffers
// (buffer_size x 4, 64 KB at the default size), so a larger response must be sent in pieces, the next one when Writable
// arrives. After a false you get exactly one Writable once there is room.
fn send(w: Worker&, c: Conn, bytes: const u8[:]) -> bool {
    let i = w._handler_slot(c);
    if i < 0 { return false; }
    let s .= w._connection_slots[i];
    if s.closing { return false; }
    // Under a tag nothing is sent once its deadline has passed (RT-6a-H). The clock is read here, not taken from the start of
    // the pass: the block may have run for a long time since the pass began.
    if !w._tag_allows(s.tag) { w._close_connection(i, CloseReason.Fenced); return false; }
    if bytes.len == 0 { return true; }
    let size = w.cfg.limits.buffer_size;
    // How many new buffers does it need, and can the queue and the pool supply them? Decide before copying anything.
    let tail_room = if s.out_count > 0 { size - s.out_lengths[s.out_count - 1] } else { 0 };
    let extra = bytes.len - tail_room;
    let new_buffers = if extra > 0 { (extra + size - 1) / size } else { 0 };
    let available = w._free_buffers.len + (w.cfg.limits.buffers_per_worker - w._stats.buffers_total);
    if s.out_count + new_buffers > 4 || new_buffers > available { s.want_writable = true; return false; }

    var offset = 0;
    while offset < bytes.len {
        if s.out_count == 0 || s.out_lengths[s.out_count - 1] == size {
            s.out_buffers[s.out_count] = w._take_buffer();
            s.out_lengths[s.out_count] = 0;
            s.out_count++;
        }
        let k = s.out_count - 1;
        let used = s.out_lengths[k];
        let n = if size - used < bytes.len - offset { size - used } else { bytes.len - offset };
        let target = w._buffer_slice(s.out_buffers[k])[used..used + n];
        target.move_from(bytes[offset..offset + n]);
        s.out_lengths[k] += n as i32;
        offset += n;
    }
    s.consumed = true;
    s.last_active_ms = w._now_ms;
    w._flush_output(i);
    true
}

// Closes after the queued bytes are sent.
fn close(w: Worker&, c: Conn) {
    let i = w._handler_slot(c);
    if i >= 0 { w._begin_close(i, CloseReason.ByHandler); }
}

// Closes now with an RST. (Named `reset`, not `abort`, which would hide Goose's builtin here.)
fn reset(w: Worker&, c: Conn) {
    let i = w._handler_slot(c);
    if i < 0 { return; }
    c_reset(w._connection_slots[i].client_fd);
    w._connection_slots[i].client_fd = -1;              // already closed, with an RST
    w._close_connection(i, CloseReason.ByHandler);
}

// Your own id for this connection, returned in every later event. tcprouter stores only the u32.
fn set_user(w: Worker&, c: Conn, user: u32) {
    let i = w._handler_slot(c);
    if i >= 0 { w._connection_slots[i].user = user; }
}

// The id set with set_user, or 0 if none was set or the connection is gone.
fn user(w: Worker&, c: Conn) -> u32 {
    let i = w._handler_slot(c);
    if i >= 0 { w._connection_slots[i].user } else { 0 }
}

// Stops or resumes reading from the peer: your own backpressure.
fn pause_reading(w: Worker&, c: Conn, paused: bool) {
    let i = w._handler_slot(c);
    if i < 0 { return; }
    w._connection_slots[i].paused = paused;
    w._update_epoll_interest(i);
}

// Hands the connection to the engine's forwarding. Only before any byte was consumed or sent; false (and nothing
// done) afterwards. When it returns true the handler's ownership ENDS: no Closed event follows, so free your
// per-connection state now.
fn forward(w: Worker&, c: Conn, to: Target) -> bool {
    let i = w._handler_slot(c);
    if i < 0 { return false; }
    let s .= w._connection_slots[i];
    if s.consumed || s.out_count > 0 || s.data_pending || to.addrs.len == 0 { return false; }
    var at = -1;                                         // an unused entry of the side table, else a new one
    for k in w._override_targets.len { if at < 0 && w._override_targets[k].addrs.len == 0 { at = k; } }
    if at < 0 { at = w._override_targets.len; w._override_targets.push(to); } else { w._override_targets[at] = to; }
    s.override_target = at as i32;
    s.state = _STATE_CONNECTING;
    w._start_connecting(i, to.addrs.len);
    true
}

// --- the queue of events ---------------------------------------------------------------------------------------

let _PENDING_OPENED: u8 = 1;
let _PENDING_DATA: u8 = 2;
let _PENDING_WRITABLE: u8 = 3;
let _PENDING_CLOSED: u8 = 4;

struct _PendingEvent {
    kind: u8,
    slot: u32,
    gen: u32,
    tag: u16,
    listener: u16,
    user: u32,                   // the user id when the event was queued (what a Closed event reports)
    buf: i32,                    // Data: the pool buffer holding the bytes, and how many
    len: i32,
    why: CloseReason,
    sni: u8[..253],              // Opened
}

fn _queue_event(w: Worker&, kind: u8, i: i64) -> _PendingEvent& {
    let s .= w._connection_slots[i];
    return w._pending.push(_PendingEvent { kind: kind, slot: i as u32, gen: s.gen, tag: s.tag, listener: s.listener, user: s.user,
                                           buf: -1, len: 0, why: CloseReason.PeerClosed, sni: [] });
}

fn _queue_closed(w: Worker&, i: i64, reason: CloseReason) {
    let closed .= w._queue_event(_PENDING_CLOSED, i);
    closed.why = reason;
}

// The connection a handle names, or -1 when it is stale, not a handler connection or already gone (RT-2b).
fn _handler_slot(w: Worker&, c: Conn) -> i64 {
    if c.slot >= w._connection_slots.len { return -1; }
    let s .= w._connection_slots[c.slot];
    if !s.live || s.gen != c.gen || s.state != _STATE_HANDLING { return -1; }
    c.slot
}

// Calls the user's block for every queued event, in order, including those the block itself causes.
fn _deliver_events<F>(w: Worker&) {
    while w._pending_head < w._pending.len {
        let r = w._pending[w._pending_head];
        w._pending_head++;
        let conn = Conn { slot: r.slot, gen: r.gen };
        var user = r.user;                               // the current id if it is still the same connection
        if r.slot < w._connection_slots.len {
            let s .= w._connection_slots[r.slot];
            if s.live && s.gen == r.gen { user = s.user; }
        }
        if r.kind == _PENDING_OPENED {
            let e: Event = Event.Opened { conn: conn, tag: r.tag, listener: r.listener, sni: r.sni };
            F(w, e);
        } else if r.kind == _PENDING_DATA {
            let e: Event = Event.Data { conn: conn, user: user, bytes: w._buffer_slice(r.buf)[..r.len] };
            F(w, e);
            w._data_delivered(r);
        } else if r.kind == _PENDING_WRITABLE {
            let e: Event = Event.Writable { conn: conn, user: user };
            F(w, e);
        } else {
            let e: Event = Event.Closed { conn: conn, user: user, why: r.why };
            F(w, e);
        }
    }
    w._pending.clear();
    w._pending_head = 0;
}

// The block has seen the bytes: the buffer goes back and the connection may be read again.
fn _data_delivered(w: Worker&, r: _PendingEvent) {
    if r.slot < w._connection_slots.len {
        let s .= w._connection_slots[r.slot];
        if s.live && s.gen == r.gen {
            s.data_pending = false;
            s.up = _Direction { .. };
        }
    }
    w._give_back_buffer(r.buf);
    if r.slot < w._connection_slots.len && w._connection_slots[r.slot].gen == r.gen { w._update_epoll_interest(r.slot); }
}

// --- reading and writing for a handler connection ------------------------------------------------------------

fn _handler_can_read(s: _ConnectionSlot&) -> bool {
    s._handler_wants_read() && !s.data_pending
}

// Whether the socket should be watched for input (see _update_epoll_interest).
fn _handler_wants_read(s: _ConnectionSlot&) -> bool {
    !s.closing && !s.paused && !s.up.eof && !s.up.waiting
}

// One read; the bytes become a Data event that keeps the buffer until the block has seen them.
fn _read_for_handler(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    if !s._handler_can_read() { return; }
    let b = w._take_buffer();
    if b < 0 {                                           // pool empty: wait for a buffer, do not read
        s.up.waiting = true;
        w._waiting_reads.push(_pack_event_data(1, i, s.gen));
        w._stats.buffer_waits++;
        w._update_epoll_interest(i);
        return;
    }
    let buffer = w._buffer_slice(b);
    let n = c_recv(s.client_fd, buffer[0], buffer.len);
    if n > 0 {
        s.up.buf = b;
        s.last_active_ms = w._now_ms;
        s.data_pending = true;
        s.consumed = true;
        w._stats.bytes_in += n;
        let data .= w._queue_event(_PENDING_DATA, i);
        data.buf = b;
        data.len = n as i32;
        w._update_epoll_interest(i);
        return;
    }
    w._give_back_buffer(b);
    if n == 0 { s.up.eof = true; w._begin_close(i, CloseReason.PeerClosed); return; }
    if n == -(c_EAGAIN as i64) || n == -(c_EINTR as i64) { w._update_epoll_interest(i); return; }
    w._close_connection(i, CloseReason.PeerReset);
}

fn _output_bytes(s: _ConnectionSlot&) -> i64 {
    var total = 0;
    for k in s.out_count { total += s.out_lengths[k]; }
    total - s.out_pos
}

// Writes the queue as far as the socket takes it. When it is empty: close if a close is waiting for it, and say Writable if
// a send was refused and one would fit now.
fn _flush_output(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    // Bytes queued before the deadline are not written after it either (the socket may take them only later).
    if s.out_count > 0 && !w._tag_allows(s.tag) { w._close_connection(i, CloseReason.Fenced); return; }
    while s.out_count > 0 {
        let rest = w._buffer_slice(s.out_buffers[0])[s.out_pos..s.out_lengths[0]];
        let n = c_send(s.client_fd, rest[0], rest.len);
        if n > 0 {
            s.out_pos += n as i32;
            w._stats.bytes_out += n;
            if s.out_pos == s.out_lengths[0] {            // the oldest buffer is done: back to the pool, the others move up
                w._give_back_buffer(s.out_buffers[0]);
                for k in 1..4 { s.out_buffers[k - 1] = s.out_buffers[k]; s.out_lengths[k - 1] = s.out_lengths[k]; }
                s.out_count--;
                s.out_pos = 0;
            }
        } else if n == -(c_EAGAIN as i64) || n == -(c_EINTR as i64) {
            break;
        } else {
            w._close_connection(i, CloseReason.PeerReset);
            return;
        }
    }
    if s.out_count == 0 && s.closing { w._close_connection(i, s.closing_reason); return; }
    if s.want_writable && s._output_bytes() < w.cfg.limits.buffer_size {
        s.want_writable = false;
        let writable .= w._queue_event(_PENDING_WRITABLE, i);
    }
    w._update_epoll_interest(i);
}

// Close once the queue is empty (now, if it already is).
fn _begin_close(w: Worker&, i: i64, reason: CloseReason) {
    let s .= w._connection_slots[i];
    if s.closing { return; }
    s.closing = true;
    s.closing_reason = reason;
    w._flush_output(i);
}
