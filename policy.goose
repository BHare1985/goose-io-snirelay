// The policy hook: who decides where a forwarded connection goes (design/07-tcpproxy.md).
//
// `w.serve(policy) { w, ev => ... }` makes the engine ask `policy` instead of rotating over Config.targets. The policy is any
// value whose type has these functions (found by UFCS in the type's own namespace, O-1):
//
//     fn pick(p: P&, route: u16, conn: Conn, tried: u32, now_ms: i64) -> Pick
//     fn connect_failed(p: P&, conn: Conn, slot: u8, tag: u16, tried: u32, now_ms: i64) -> Retry
//     fn connected(p: P&, conn: Conn, tag: u16)
//     fn closed(p: P&, conn: Conn, tag: u16, why: CloseReason)
//     fn on_message(p: P&, body: const u8[:], now_ms: i64) -> Effect
//
// `route` is the index of the Forward target in Config.targets (the group). `now_ms` is CLOCK_BOOTTIME, so the policy has no clock
// of its own and its rules can be tested without one. `tried` is a bit set the ENGINE keeps for each connection: it sets bit `slot` of
// every Pick.To before connecting and passes the set back, so the policy needs no per-connection memory (32 slots per route, the C
// proxy's MAX_SLOTS). `connected` and `closed` are told about the same tag the pick returned; `closed` is only called for a connection
// that `connected` was called for.
//
// How the engine calls it: no engine function is generic over the policy. A connection that needs a decision is put in a request
// queue (state, not a call) and `serve` drains the queue after each batch of events, on the worker's thread (the same shape as handler
// events). A policy call therefore never runs inside the epoll dispatch, and a connection waiting for its pick holds no server socket.
// A connection is retried only before a client byte was consumed: a connecting connection is not read.
namespace tcprouter;

import .config;
import .engine;
import .conn;

enum Pick {
    To { addr: Addr, tag: u16, gen: u32, slot: u8, connect_ms: i64 },   // connect to addr; the connection's tag and target generation are these; connect_ms is this connect's timeout (0 = Limits.connect_timeout_ms)
    None,                                              // nowhere: close the client
}

enum Retry { Next, GiveUp }

// What a policy asks the engine to do after a message. The engine performs it on this worker only (nothing is re-broadcast: every
// worker got the same message and its policy decides the same way).
enum Effect {
    None,
    CloseTagged { tag: u16, gen: u32 },      // close every connection of the tag whose target generation is <= gen (as Message.CloseTagged)
}

// What serve(F) without a policy passes: its hooks are never called, because nothing is ever queued for it.
struct _NoPolicy { unused: u8 = 0 }
// The four hooks of the policy nobody supplied; never called (see above).
fn pick(p: _NoPolicy&, route: u16, conn: Conn, tried: u32, now_ms: i64) -> Pick { Pick.None }
// (never called)
fn connect_failed(p: _NoPolicy&, conn: Conn, slot: u8, tag: u16, tried: u32, now_ms: i64) -> Retry { Retry.GiveUp }
// (never called)
fn connected(p: _NoPolicy&, conn: Conn, tag: u16) { }
// (never called)
fn closed(p: _NoPolicy&, conn: Conn, tag: u16, why: CloseReason) { }
// (never called)
fn on_message(p: _NoPolicy&, body: const u8[:], now_ms: i64) -> Effect { Effect.None }

let _POLICY_PICK: u8 = 1;
let _POLICY_FAILED: u8 = 2;
let _POLICY_CONNECTED: u8 = 3;
let _POLICY_CLOSED: u8 = 4;
let _POLICY_MESSAGE: u8 = 5;
let _POLICY_STATS: u8 = 6;

struct _PolicyRequest { kind: u8, slot: u32, gen: u32, tag: u16, why: CloseReason, body: u8[..48] }

fn _queue_policy(w: Worker&, kind: u8, i: i64) {
    let s .= w._connection_slots[i];
    w._policy_requests.push(_PolicyRequest { kind: kind, slot: i as u32, gen: s.gen, tag: s.tag, why: CloseReason.PeerClosed, body: [] });
}

// The connection has a Forward route and the engine runs with a policy: it asks for its first pick.
fn _start_deciding(w: Worker&, i: i64) {
    let s .= w._connection_slots[i];
    s.tried = 0;
    s.policied = true;
    w._end_inspection(i);
    w._register_client_edge(i);
    if !s.live { return; }
    s.state = _STATE_CONNECTING;
    w._queue_policy(_POLICY_PICK, i);
}

// The index in Config.targets of the Forward route the connection took.
fn _route_target(w: Worker&, s: _ConnectionSlot&) -> u16 {
    var to: u16 = 0;
    match w.cfg.routes[s.route_index as i64].action {
        Forward f => { to = f.to; },
        _ => {},
    }
    to
}

// A connect to the policy's pick failed (at once, or later): count it and ask the policy what next.
fn _policy_connect_failed(w: Worker&, i: i64) {
    w._stats.connect_failures++;
    w._queue_policy(_POLICY_FAILED, i);
}

// A Message.Policy arrived: queued like the other hooks, so the policy runs between event batches and in post order. Without a policy
// (serve(F)) the message is dropped.
fn _queue_policy_message(w: Worker&, length: u8, bytes: const u8[:]) {
    if !w._policy_on { return; }
    var body: u8[..48] = [];
    let n = if length < bytes.len { length } else { bytes.len };
    body.append(bytes[..n]);
    w._policy_requests.push(_PolicyRequest { kind: _POLICY_MESSAGE, slot: 0, gen: 0, tag: 0, why: CloseReason.PeerClosed, body: body });
}

// A Stats request while a policy runs: answered by serve in queue order, after every Policy message that arrived before it (PX-5: post, gather,
// reply: the gather returning means each worker applied everything posted earlier).
fn _queue_policy_stats(w: Worker&) {
    w._policy_requests.push(_PolicyRequest { kind: _POLICY_STATS, slot: 0, gen: 0, tag: 0, why: CloseReason.PeerClosed, body: [] });
}

// Called by _close_connection for a connection the policy was told is connected.
fn _queue_policy_closed(w: Worker&, i: i64, reason: CloseReason) {
    w._queue_policy(_POLICY_CLOSED, i);
    w._policy_requests[w._policy_requests.len - 1].why = reason;
}

fn _deliver_policy<P>(w: Worker&, p: P&) {
    while w._policy_head < w._policy_requests.len {
        let r = w._policy_requests[w._policy_head];
        w._policy_head++;
        let conn = Conn { slot: r.slot, gen: r.gen };
        let i = r.slot as i64;
        if r.kind == _POLICY_STATS {
            qput(_StatsReply { worker: w.index, stats: w.stats() });
            continue;
        }
        if r.kind == _POLICY_MESSAGE {
            let effect = p.on_message(r.body[..], w._now_ms);
            match effect {
                CloseTagged c => { w._close_tagged(c.tag, c.gen); },
                _ => {},
            }
            continue;
        }
        if r.kind == _POLICY_CLOSED {
            p.closed(conn, r.tag, r.why);
            continue;
        }
        let s .= w._connection_slots[i];
        if !s.live || s.gen != r.gen { continue; }          // closed while it waited
        if r.kind == _POLICY_CONNECTED {
            p.connected(conn, r.tag);
        } else if r.kind == _POLICY_FAILED {
            let again = p.connect_failed(conn, s.pick_slot, s.tag, s.tried, w._now_ms);
            if again == Retry.Next {
                w._stats.retries++;
                w._queue_policy(_POLICY_PICK, i);
            } else {
                w._close_connection(i, CloseReason.ConnectFailed);
            }
        } else {
            w._take_pick(i, p.pick(_route_target(w, s), conn, s.tried, w._now_ms));
        }
    }
    w._policy_requests.clear();
    w._policy_head = 0;
}

// Acts on the policy's answer: connect where it said, or close.
fn _take_pick(w: Worker&, i: i64, pick: Pick) {
    let s .= w._connection_slots[i];
    match pick {
        To t => {
            if t.slot >= 32 { w._close_connection(i, CloseReason.ConnectFailed); return; }
            s.tried |= (1 as u32) << t.slot;
            s.pick_slot = t.slot;
            s.tag = t.tag;
            s.target_gen = t.gen;
            s.connect_ms = t.connect_ms;                     // each connect starts its own timer (_connect_to sets started_ms)
            if !w._tag_allows(t.tag) { w._close_connection(i, CloseReason.Fenced); return; }
            s.attempts++;
            if !w._connect_to(i, t.addr) { w._policy_connect_failed(i); }
        },
        _ => { w._close_connection(i, CloseReason.ConnectFailed); },
    }
}
