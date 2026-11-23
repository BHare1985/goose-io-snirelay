// Handler mode on goose-io (port, stage 3): the user's code gets a link as events and answers with send, close, reset, forward...
// The calls are the old ones with the loop as an extra argument (`w.send(io, c, bytes)`): the router owns no loop, so it cannot reach one.
// A Conn is the loop's Link under another name.
namespace tcprouter;

import std;
import goose_io from "github.com/BHare1985/goose-io@bfadab427f4ac37a89d9182fbd943d0c9e0d7457";

fn _link(c: Conn) -> goose_io::Link { return goose_io::Link { slot: c.slot, gen: c.gen }; }
fn _conn(l: goose_io::Link) -> Conn { return Conn { slot: l.slot, gen: l.gen }; }

// --- the calls a handler block may make ---------------------------------------------------------------------

// Queues bytes to the peer. All or nothing: false (and nothing queued) if the link is gone or closing, or the bytes do not fit; after a
// false you get exactly one Writable once there is room.
fn send<Io>(w: Worker&, io: Io&, c: Conn, bytes: const u8[:]) -> bool {
    let l = _link(c);
    let r = w.recs.find(l);
    guard r else { return false; }
    if r.role != _Role.Handler && r.role != _Role.HandlerDial { return false; }
    if r.closing { return false; }
    if r.tag != 0 && !w._tag_allows(io, r.tag) { r._decide(CloseReason.Fenced); io.close(l); return false; }
    if bytes.len == 0 { return true; }
    if io.send(l, bytes) != goose_io::SendStatus.Sent { return false; }
    r.consumed = true;
    w.stats.bytes_out += bytes.len;
    return true;
}

// Opens a link to `addr` from this worker and returns its handle at once. Events: Opened when the connect finished, then Data, Writable and
// Closed; a connect that fails has no Opened and exactly one Closed (ConnectFailed). `send` before Opened returns false.
fn dial<Io>(w: Worker&, io: Io&, addr: const u8[:], tag: u16, connect_ms: i64) -> Conn {
    let ms = if connect_ms > 0 { connect_ms } else { w.cfg.limits.connect_timeout_ms };
    let over = w.stats.open >= w.cfg.limits.max_conns_per_worker;
    w.stats.open++;
    let l = io.dial(addr, ms);
    if !goose_io::is_valid(l) {
        // no link to name: the Closed is delivered for a handle nothing else can be done with
        w.pending.push(_Pending { kind: 2, link: goose_io::Link { slot: 4294967295, gen: 1 }, tag: tag, listener: 0, sni: [] });
        return Conn { slot: 4294967295, gen: 1 };
    }
    w.recs.put(l, _Rec { role: _Role.HandlerDial, tag: tag });
    io.set_keep_open_on_eof(l, true);
    if !w._tag_allows(io, tag) { let fr = w.recs.find(l); if fr { fr._decide(CloseReason.Fenced); } io.close(l); return _conn(l); }
    w._arm_fence(io, l, tag);
    if over {
        let r = w.recs.find(l);
        if r { r._decide(CloseReason.ConnectFailed); }
        io.close(l);
    }
    return _conn(l);
}

// Closes after the queued bytes are sent. Before Opened it cancels the dial.
fn close<Io>(w: Worker&, io: Io&, c: Conn) {
    let l = _link(c);
    let r = w.recs.find(l);
    guard r else { return; }
    if r.role != _Role.Handler && r.role != _Role.HandlerDial { return; }
    r.closing = true;
    io.close(l);
}

// Closes now with an RST.
fn reset<Io>(w: Worker&, io: Io&, c: Conn) {
    let l = _link(c);
    let r = w.recs.find(l);
    guard r else { return; }
    if r.role != _Role.Handler && r.role != _Role.HandlerDial { return; }
    r.closing = true;
    io.reset(l);
}

// Stores the handler's own id on a handler link.
fn set_user<Io>(w: Worker&, io: Io&, c: Conn, user: u32) {
    let r = w.recs.find(_link(c));
    guard r else { return; }
    if r.role == _Role.Handler || r.role == _Role.HandlerDial { r.user = user; }
}

// The id set with set_user (0 if none).
fn user<Io>(w: Worker&, io: Io&, c: Conn) -> u32 {
    let r = w.recs.find(_link(c));
    guard r else { return 0; }
    if r.role == _Role.Handler || r.role == _Role.HandlerDial { return r.user; }
    return 0;
}

// Stops or resumes reading from the peer: your own backpressure.
fn pause_reading<Io>(w: Worker&, io: Io&, c: Conn, paused: bool) {
    let l = _link(c);
    let r = w.recs.find(l);
    guard r else { return; }
    if r.role == _Role.Handler { io.pause_reading(l, paused); }
}

// Keeps the link open when the peer finishes sending: PeerEof once, you can still send, and finish with shutdown_write or close.
fn set_keep_open_on_eof<Io>(w: Worker&, io: Io&, c: Conn, keep: bool) {
    let l = _link(c);
    let r = w.recs.find(l);
    guard r else { return; }
    if r.role != _Role.Handler && r.role != _Role.HandlerDial { return; }
    r.keep = keep;
    io.set_limit(l, goose_io::Limit.HalfOpen, if keep { w.cfg.limits.half_close_timeout_ms } else { 0 });
}

// Once the queued bytes are out, shuts down the write side. send returns false from now on.
fn shutdown_write<Io>(w: Worker&, io: Io&, c: Conn) {
    let l = _link(c);
    let r = w.recs.find(l);
    guard r else { return; }
    if r.role != _Role.Handler || r.closing { return; }
    r.closing = true;
    io.shutdown_write(l);
}

// How many bytes `send` would accept right now (0 when it is full, closing, shut or stale).
fn send_room<Io>(w: Worker&, io: Io&, c: Conn) -> i64 {
    let l = _link(c);
    let r = w.recs.find(l);
    guard r else { return 0; }
    if (r.role != _Role.Handler && r.role != _Role.HandlerDial) || r.closing { return 0; }
    return io.send_room(l);
}

// True once the loop was told to drain: a handler can answer new requests with 503 and close.
fn draining<Io>(w: Worker&, io: Io&) -> bool { return io.draining(); }

// Opt in (or out) of Event.PassEnd.
fn want_pass_end(w: Worker&, on: bool) { w.pass_end = on; }

// Hands the link to the router's forwarding. Only before any byte was consumed or sent; false (and nothing done) afterwards. When it returns
// true the handler's ownership ENDS: no Closed event follows.
fn forward<Io>(w: Worker&, io: Io&, c: Conn, to: Target) -> bool {
    let l = _link(c);
    let r = w.recs.find(l);
    guard r else { return false; }
    if r.role != _Role.Handler || r.consumed || r.closing || r.ended || to.addrs.len == 0 { return false; }
    var at = -1;
    for k in w.override_targets.len { if at < 0 && w.override_targets[k].addrs.len == 0 { at = k; } }
    if at < 0 { at = w.override_targets.len; w.override_targets.push(to); } else { w.override_targets[at] = to; }
    r.override = at as i32;
    r.role = _Role.Client;
    r.first = (w.round_robin % to.addrs.len) as u8;
    w.round_robin++;
    r.tries = 0;
    io.pause_reading(l, true);
    if !w._dial_next(io, l, false) { r._decide(CloseReason.ConnectFailed); io.close(l); }
    return true;
}

// --- delivering events to the handler block -------------------------------------------------------------------

// Events waiting for the block: Opened of a link routed to a handler, and the Closed of a dial that never had a link.
fn _deliver_pending<Io, F>(w: Worker&, io: Io&) {
    while w.pending_head < w.pending.len {
        let p = w.pending[w.pending_head];
        w.pending_head++;
        if p.kind == 1 {
            let e: Event = Event.Opened { conn: _conn(p.link), tag: p.tag, listener: p.listener, sni: p.sni };
            F(w, io, e);
            let r = w.recs.find(p.link);
            // not forwarded away: the hello bytes held for routing now go to the handler as Data
            if r && r.role == _Role.Handler && r.inspected { io.wait_input(p.link, 0); }
        } else {
            w.stats.closed[_slot(CloseReason.ConnectFailed)]++;
            w.stats.open--;
            let e: Event = Event.Closed { conn: _conn(p.link), user: 0, why: CloseReason.ConnectFailed };
            F(w, io, e);
        }
    }
    w.pending.clear();
    w.pending_head = 0;
}

// A handler link ended: count it and tell the block.
fn _handler_closed<Io, F>(w: Worker&, io: Io&, link: goose_io::Link, r: _Rec&, why: goose_io::CloseReason) {
    w._fence_reason(io, r, why);
    var reason = _reason_of(why);
    if r.decided { reason = r.why; }
    w.stats.closed[_slot(reason)]++;
    w.stats.open--;
    let user = r.user;
    w.recs.drop(link);
    let e: Event = Event.Closed { conn: _conn(link), user: user, why: reason };
    F(w, io, e);
}

// The event handler: call it from the loop's serve block with the block that handles the handler-mode events.
fn on_event<Io, F>(w: Worker&, io: Io&, ev: goose_io::Event) {
    var none = NoPolicy { };
    w.policy_on = false;
    w._on_event(io, none, ev, F);
}

// The same with a policy that picks where forwarded connections go (RT-13).
fn on_event<Io, F, P>(w: Worker&, io: Io&, ev: goose_io::Event, pol: P&) {
    w.policy_on = true;
    w._on_event(io, pol, ev, F);
}

fn _on_event<Io, P, F>(w: Worker&, io: Io&, pol: P&, ev: goose_io::Event) {
    match ev {
        Opened o => {
            let r = w.recs.find(o.link);
            if !goose_io::is_listener(o.listener) && r && r.role == _Role.HandlerDial {
                io.set_limit(o.link, goose_io::Limit.Idle, w.cfg.limits.idle_timeout_ms);
                let e: Event = Event.Opened { conn: _conn(o.link), tag: r.tag, listener: 0, sni: [] };
                F(w, io, e);
            } else {
                w._core_event(io, pol, ev);
            }
        },
        Data d => {
            let r = w.recs.find(d.link);
            if r && (r.role == _Role.Handler || r.role == _Role.HandlerDial) {
                r.consumed = true;
                w.stats.bytes_in += d.bytes.len;
                w.data_copy.clear();
                w.data_copy.append(d.bytes);
                let e: Event = Event.Data { conn: _conn(d.link), user: r.user, bytes: w.data_copy[..] };
                F(w, io, e);
            }
        },
        Writable x => {
            let r = w.recs.find(x.link);
            if r && (r.role == _Role.Handler || r.role == _Role.HandlerDial) {
                let e: Event = Event.Writable { conn: _conn(x.link), user: r.user };
                F(w, io, e);
            }
        },
        PeerEof x => {
            let r = w.recs.find(x.link);
            if r && (r.role == _Role.Handler || r.role == _Role.HandlerDial) {
                r.ended = true;
                if !r.keep { r._decide(CloseReason.PeerClosed); io.close(x.link); return; }   // not opted in: the peer finishing ends the connection
                let e: Event = Event.PeerEof { conn: _conn(x.link), user: r.user };
                F(w, io, e);
            }
        },
        Closed c => {
            let r = w.recs.find(c.link);
            if r && (r.role == _Role.Handler || r.role == _Role.HandlerDial) { w._handler_closed(io, c.link, r, c.why, F); }
            else { w._core_event(io, pol, ev); }
        },
        PassEnd => {
            if w.pass_end {
                let e: Event = Event.PassEnd { };
                F(w, io, e);
            }
        },
        Tick t => {
            w._core_event(io, pol, ev);
            let e: Event = Event.Tick { now_ms: t.now_ms };
            F(w, io, e);
        },
        _ => { w._core_event(io, pol, ev); },
    }
    w._deliver_pending(io, F);
}

// Without a handler block: routes that name a handler close the link.
fn on_event<Io>(w: Worker&, io: Io&, ev: goose_io::Event) {
    var none = NoPolicy { };
    w.policy_on = false;
    w._core_event(io, none, ev);
}

// Without a handler block but with a policy: routes that name a handler close the link.
fn on_event<Io, P>(w: Worker&, io: Io&, ev: goose_io::Event, pol: P&) {
    w.policy_on = true;
    w._core_event(io, pol, ev);
}
