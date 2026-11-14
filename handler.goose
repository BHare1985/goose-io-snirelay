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
    if s.closing || s.wr_shut || s.shut_wr_pending { return false; }
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

// Opens a connection to `addr` ("host:port") from this worker and returns its handle at once; the connect never blocks (RT-14).
// The handle is a Conn like any other. Events, in order: Opened when the connect finished (nothing is ever delivered before it), then Data,
// Writable and Closed as for an accepted connection. If the connect fails (refused, unreachable, `connect_ms` passed: 0 means
// Limits.connect_timeout_ms) or the tag is fenced, there is no Opened and exactly one Closed, with why = ConnectFailed or Fenced.
// `send` on the Conn BEFORE Opened returns false and queues nothing: wait for Opened, as for Writable. A dialled connection counts toward
// max_conns_per_worker, obeys the idle timeout, and can be tagged and fenced (RT-6) like an accepted one. `close` before Opened cancels it.
fn dial(w: Worker&, addr: const u8[:], tag: u16, connect_ms: i64) -> Conn {
    var i: i64 = 0;
    var gen: u32 = 1;
    if w._free_slots.len > 0 {
        i = w._free_slots.pop();
        gen = w._connection_slots[i].gen;
        w._connection_slots[i] = _fresh_slot(gen, -1, 0, false, w._now_ms);
    } else {
        i = w._connection_slots.len;
        w._connection_slots.push(_fresh_slot(gen, -1, 0, false, w._now_ms));
    }
    let s .= w._connection_slots[i];
    s.state = _STATE_DIALING;
    s.tag = tag;
    s.connect_ms = connect_ms;
    w._stats.open++;
    w._dialing++;
    w._note_dial_due(w._now_ms + (if connect_ms > 0 { connect_ms } else { w.cfg.limits.connect_timeout_ms }));
    let conn = Conn { slot: i as u32, gen: s.gen };
    if w._stats.open > w.cfg.limits.max_conns_per_worker { w._close_connection(i, CloseReason.ConnectFailed); return conn; }
    if !w._tag_allows(tag) { w._close_connection(i, CloseReason.Fenced); return conn; }
    var p = _ParsedAddress { false, [0; 16], 0 };
    if !_parse_address(addr, p) { w._close_connection(i, CloseReason.ConnectFailed); return conn; }
    let fd = c_connect_start(p.v6, p.ip, p.port);
    if fd < 0 { w._close_connection(i, CloseReason.ConnectFailed); return conn; }
    s.client_fd = fd;
    s.client_mask = c_EPOLLOUT;                      // level-triggered: the connect finishing makes the socket writable (or errored)
    if c_epoll_ctl(w._epoll_fd, c_EPOLL_CTL_ADD, fd, c_EPOLLOUT, _pack_event_data(_EVENT_KIND_CLIENT, i, s.gen)) < 0 {
        w._close_connection(i, CloseReason.Error);
        return conn;
    }
    s.client_registered = true;
    conn
}

// Connect timeouts of dials are per connection and many dials share a tag, so the per-tag deadline table cannot express them. Instead the
// worker remembers the earliest connect deadline and the loop sleeps no longer than that: nothing wakes it while no dial is pending.
fn _note_dial_due(w: Worker&, due: i64) {
    if w._dial_due == 0 || due < w._dial_due { w._dial_due = due; }
}

// How long epoll_wait may sleep: 100 ms, or less when a dial's connect deadline comes sooner.
fn _wait_limit(w: Worker&) -> i32 {
    if w._dialing <= 0 { return 100; }
    let until = w._dial_due - c_boottime_ms();
    if until <= 0 { 0 } else if until < 100 { until as i32 } else { 100 }
}

// Closes (ConnectFailed) the dials whose own connect timeout has passed, and finds the next deadline among the rest.
fn _expire_dials(w: Worker&, now: i64) {
    var next: i64 = 0;
    for i in w._connection_slots.len {
        let s .= w._connection_slots[i];
        if !s.live || s.state != _STATE_DIALING { continue; }
        let allowed = if s.connect_ms > 0 { s.connect_ms } else { w.cfg.limits.connect_timeout_ms };
        let due = s.started_ms + allowed;
        if now >= due { w._close_connection(i, CloseReason.ConnectFailed); }
        else if next == 0 || due < next { next = due; }
    }
    w._dial_due = next;
}

// The connect of a dialled connection finished (or failed): Opened, or the one Closed.
fn _dial_finished(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    if c_connect_result(s.client_fd) != 0 { w._close_connection(i, CloseReason.ConnectFailed); return; }
    if !w._tag_allows(s.tag) { w._close_connection(i, CloseReason.Fenced); return; }
    w._dialing--;
    if w._dialing == 0 { w._dial_due = 0; }          // nothing left to time: no stale deadline for the next dial to inherit
    s.state = _STATE_HANDLING;
    s.started_ms = w._now_ms;
    s.last_active_ms = w._now_ms;
    w._queue_event(_PENDING_OPENED, i);
    w._update_epoll_interest(i);                       // now level-triggered input (and output when something is queued)
}

// Closes after the queued bytes are sent. On a dial that has not opened yet it cancels the dial (a Closed follows).
fn close(w: Worker&, c: Conn) {
    if c.slot < w._connection_slots.len {
        let d .= w._connection_slots[c.slot];
        if d.live && d.gen == c.gen && d.state == _STATE_DIALING { w._close_connection(c.slot as i64, CloseReason.ByHandler); return; }
    }
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
    let i = w._user_slot(c);
    if i >= 0 { w._connection_slots[i].user = user; }
}

// The id set with set_user, or 0 if none was set or the connection is gone.
fn user(w: Worker&, c: Conn) -> u32 {
    let i = w._user_slot(c);
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
let _PENDING_EOF: u8 = 5;

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

// Like _handler_slot, but a dial still in progress counts too: set_user and user work on a Conn as soon as dial returns it,
// while send and the rest wait for Opened.
fn _user_slot(w: Worker&, c: Conn) -> i64 {
    if c.slot >= w._connection_slots.len { return -1; }
    let s .= w._connection_slots[c.slot];
    if !s.live || s.gen != c.gen || (s.state != _STATE_HANDLING && s.state != _STATE_DIALING) { return -1; }
    c.slot
}

// Calls the user's block for every queued event, in order, including those the block itself causes.
fn _deliver_events<F>(w: Worker&) {
    while w._pending_head < w._pending.len {
        let r = w._pending[w._pending_head];
        w._pending_head++;
        if w._want_pass_end { w._pass_delivered++; }
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
        } else if r.kind == _PENDING_EOF {
            let e: Event = Event.PeerEof { conn: conn, user: user };
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
    if n == 0 {
        s.up.eof = true;
        if s.keep_open && !s.closing {                       // the handler wants to finish its answer (RT-15a)
            if s.wr_shut { w._close_connection(i, CloseReason.PeerClosed); return; }
            s.half_closed_at_ms = w._now_ms;                  // the half-close timeout (Limits.half_close_timeout_ms) bounds the wait for the handler (RT-15f)
            w._queue_event(_PENDING_EOF, i);
            w._update_epoll_interest(i);
            return;
        }
        w._begin_close(i, CloseReason.PeerClosed);
        return;
    }
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
    if s.out_count == 0 && s.shut_wr_pending {
        c_shutdown_wr(s.client_fd);
        s.wr_shut = true;
        s.shut_wr_pending = false;
        if s.up.eof { w._close_connection(i, CloseReason.PeerClosed); return; }      // both directions are finished
    }
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

// Keeps the connection open when the peer finishes sending (it shuts down its write side). Off by default: then the peer's EOF closes the connection after
// the queued bytes are flushed (Closed with PeerClosed). On: the engine stops reading, delivers PeerEof once, and you can keep sending (send, Writable) and finish with
// shutdown_write or close. For protocols whose client says "that is my whole request" by half-closing (RT-15a).
fn set_keep_open_on_eof(w: Worker&, c: Conn, keep: bool) {
    let i = w._handler_slot(c);
    if i >= 0 { w._connection_slots[i].keep_open = keep; }
}

// Once the queued bytes are out, shuts down the write side: the peer reads EOF after the last byte while you can still receive. When the peer has also
// finished sending, the connection closes (Closed). send returns false from now on. (`close` is the other ending: it closes once the queue is out.)
fn shutdown_write(w: Worker&, c: Conn) {
    let i = w._handler_slot(c);
    if i < 0 { return; }
    let s .= w._connection_slots[i];
    if s.closing || s.wr_shut { return; }
    s.shut_wr_pending = true;
    w._flush_output(i);
}

// How many bytes `send` would accept right now: the free room of the 4-buffer queue (a whole `send` of this size or less succeeds), 0 when it is full, the
// connection is closing or its write side is shut down, or the handle is stale (RT-15d).
fn send_room(w: Worker&, c: Conn) -> i64 {
    let i = w._handler_slot(c);
    if i < 0 { return 0; }
    let s .= w._connection_slots[i];
    if s.closing || s.wr_shut || s.shut_wr_pending { return 0; }
    let size = w.cfg.limits.buffer_size;
    let tail_room = if s.out_count > 0 { size - s.out_lengths[s.out_count - 1] } else { 0 };
    let queue_free = 4 - s.out_count;
    let available = w._free_buffers.len + (w.cfg.limits.buffers_per_worker - w._stats.buffers_total);
    let fresh = if queue_free < available { queue_free } else { available };
    tail_room + fresh * size
}

// True once a Drain message has reached this worker (posted by `drain` or wait_for_signal_then_drain): the listeners are closed and the worker ends
// when its connections have, or at the deadline. A handler can use it to answer new requests on open connections with 503 and close (RT-15h).
fn draining(w: Worker&) -> bool { w._draining }

// The batching window (RT-16). Called when a pass found `n` events: if there are fewer than Limits.batch_min_events, waits up to batch_max_wait_us for more
// and appends what arrived to `events`; returns how many it appended. Off (both limits 0) it returns at once and costs nothing.
// Rules: (1) it never waits past a deadline: the wait is cut to the earliest of the next Tick, the next sweep, a tag deadline, a dial's connect deadline,
// a paused listener's resume; it is not entered while draining; (2) it waits on the worker's MESSAGE PIPE, so a posted message (control, Policy, Drain, Stats)
// ends it at once, and it is skipped when a message is already among the events; (3) the clock is read again afterwards, so fences and timers see the real time.
fn _batch_window(w: Worker&, events: c_EpollEvent[256]&, n: i32, last_tick: i64, last_sweep: i64) -> i32 {
    let min = w.cfg.limits.batch_min_events;
    var us = w.cfg.limits.batch_max_wait_us;
    if min <= 0 || us <= 0 || (n as i64) >= min || n >= 256 || w._draining { return 0; }
    for k in n { if (events[k].data & 0xff) == _EVENT_KIND_MESSAGE { return 0; } }
    let now = c_boottime_ms();
    var next: i64 = last_tick + 100;                               // the next Tick
    if last_sweep + 250 < next { next = last_sweep + 250; }
    if w._deadline_scan_at != 0 && w._deadline_scan_at < next { next = w._deadline_scan_at; }
    if w._dialing > 0 && w._dial_due != 0 && w._dial_due < next { next = w._dial_due; }
    for li in w.cfg.listeners.len { if w._listener_resume_at[li] != 0 && w._listener_resume_at[li] < next { next = w._listener_resume_at[li]; } }
    let room_us = (next - now) * 1000;
    if room_us < us { us = room_us; }
    if us <= 0 { return 0; }
    let slept = c_wait_readable_us(w._message_fd, us);
    w._stats.batch_waits++;
    if slept > 0 { w._stats.batch_wait_us += slept; }
    let m = c_epoll_wait(w._epoll_fd, events[n], 256 - n, 0);        // everything that arrived meanwhile
    w._now_ms = c_boottime_ms();
    if m > 0 { m } else { 0 }
}

// Opt in (or out) of Event.PassEnd (RT-17): after the last handler event of every pass that delivered at least one (Opened, Data, Writable, PeerEof, Closed),
// the engine delivers one PassEnd, so a handler can flush what it gathered during the pass (one write for many replies). Ticks, posted messages (control,
// Policy, Stats) and policy hooks are NOT handler events: a pass with only those gets no PassEnd, and neither does an idle pass. A pass that ends a batching
// window wait is an ordinary pass. Sends made during PassEnd take the normal path (the deadline check included); events they cause are delivered at once and
// do not open another PassEnd. Off by default, and then costs nothing.
fn want_pass_end(w: Worker&, on: bool) {
    w._want_pass_end = on;
    w._pass_delivered = 0;
}

// Ends a pass: one PassEnd if the pass delivered handler events and the handler asked for it.
fn _finish_pass<F>(w: Worker&) {
    if !w._want_pass_end || w._pass_delivered == 0 { return; }
    w._pass_delivered = 0;
    let e: Event = Event.PassEnd { };
    F(w, e);
    w._deliver_events(F);
    w._pass_delivered = 0;
}
