// tcprouter on goose-io (port, stage 1): forward by listener. A Router lives beside an event loop and owns no sockets: it
// is generic over the loop and uses only the contract (goose_io.goose) and its capabilities.
namespace tcprouter;

import std;
import goose_io from "github.com/BHare1985/goose-io@v0.4";


// What a link's _Rec.role says it is.
enum _Role {
    None,
    Client,        // accepted client
    Server,        // dialled server
    Refused,       // client refused (over max_links or no route)
    Handler,       // client the handler decides about
    HandlerDial,   // link the handler dialled
}

// Where each close reason is counted in Stats.closed.
fn _slot(why: CloseReason) -> i64 {
    return match why {
        PeerClosed => 0, PeerReset => 1, IdleTimeout => 2, HalfCloseTimeout => 3, InspectTimeout => 4, ConnectFailed => 5,
        Fenced => 6, Drained => 7, ByHandler => 8, Error => 9, InvalidHello => 10,
    };
}

// The reasons that say least about what happened: the other end of a pair, if it has a better one, is told instead.
fn _vague(why: CloseReason) -> bool {
    return match why { ByHandler => true, Error => true, _ => false };
}

let _TICK_MS: i64 = 100;           // how often the router sweeps for deadlines
let _MAX_POLICY_SLOTS: i64 = 32;   // slots a policy may use: _Rec.tried is a u32 bit set

// What the router knows of one link.
struct _Rec {
    role: _Role = _Role.None,                 // 1 accepted client, 2 dialled server, 3 refused client
    partner: goose_io::Link = goose_io::Link { .. },
    done: bool = false,           // its Closed was handled
    reason: CloseReason = CloseReason.Error,   // the close reason it ended with
    counted: bool = false,        // the pair's close was counted
    route: i32 = 0,               // cfg.routes index (client)
    first: u8 = 0,               // first target address tried (client)
    tries: u8 = 0,               // addresses tried so far (client)
    why: CloseReason = CloseReason.Error,      // a reason the router decided, overriding what the loop reports (when decided)
    decided: bool = false,        // why was set
    inspecting: bool = false,     // client: waiting for the ClientHello (inspect: Sni listener)
    inspected: bool = false,      // client: the listener inspects, so the hello is replayed to each server tried (RT-21)
    seen: i32 = 0,                // client: bytes of hello seen at the last look
    hello_len: i32 = 0,           // server: bytes of hello sent from the client's held bytes
    hello_sent: bool = false,     // server: its first byte has not come yet, so the hello is still the client's
    early: bool = false,          // server: ended before its first byte (RT-21)
    listener: u8 = 0,            // client: cfg.listeners index
    user: u32 = 0,                // handler link: the id from set_user
    keep: bool = false,           // the handler opted in to PeerEof with the link kept open (the loop's keep-open window is only Opened)
    armed: bool = false,          // a write deadline is set on the link: a Local close nobody asked for is the fence (now_ms is per pass)
    tag: u16 = 0,                 // handler link: the tag of the route (Opened), or of the dial
    consumed: bool = false,       // handler link: a byte was received or sent, so forward is refused (RT-19d)
    ended: bool = false,          // handler link: the peer's end was seen
    closing: bool = false,        // handler link: the handler closed it or shut its write side
    override: i32 = -1,           // client forwarded from a handler: index into Worker.override_targets
    target_gen: u32 = 0,          // the generation of the target the link was routed to (close_tagged)
    policied: bool = false,       // client: a policy picks its server
    told: bool = false,           // client: the policy was told it connected, so it is told it closed
    tried: u32 = 0,               // client: bit set of the policy slots tried
    pick_slot: u8 = 0,            // client: the slot of the policy's last pick
    pick_connect_ms: i32 = 0,     // client: the connect timeout of the last pick
}

// A tag that has an entry may carry connections only while until_ms (CLOCK_BOOTTIME) is in the future; 0 means fenced.
struct _TagEntry { tag: u16, until_ms: i64 }

struct _WakerReport { index: i64, waker: goose_io::Waker }


// An Opened event waiting for the handler block (kind 1), or the Closed of a dial that never got a link (kind 2).
struct _Pending {
    kind: u8 = 0,
    link: goose_io::Link = goose_io::Link { .. },
    tag: u16 = 0,
    listener: u16 = 0,
    sni: u8[..253] = [],
}

let _MAX_HELLO: i64 = 32768;

// What serve gets when nobody supplied a policy: its hooks are never called (policy_on is false).
struct NoPolicy { unused: u8 = 0 }
// No policy: pick nothing.
fn pick(p: NoPolicy&, route: u16, conn: Conn, tried: u32, now_ms: i64) -> Pick { Pick.None }
// No policy: give up.
fn connect_failed(p: NoPolicy&, conn: Conn, slot: u8, tag: u16, tried: u32, now_ms: i64) -> Retry { Retry.GiveUp }
// No policy: ignore.
fn connected(p: NoPolicy&, conn: Conn, tag: u16) { }
// No policy: ignore.
fn closed(p: NoPolicy&, conn: Conn, tag: u16, why: CloseReason) { }
// No policy: no effect.
fn on_message(p: NoPolicy&, body: const u8[:], now_ms: i64) -> Effect { Effect.None }

let _STRONG_FROM: i64 = 0;

root struct Worker {
    cfg: Config = Config { .. },
    index: i64 = 0,
    error: u8[..200] = [],
    stats: Stats = Stats { .. },
    round_robin: i64 = 0,
    recs: goose_io::LinkMap<_Rec> = goose_io::LinkMap<_Rec> { .. },
    listener_ids: u32[..16] = [],     // the loop's listener id of cfg.listeners[k]
    scratch: u8[16384] = [0; 16384],  // where parse_hello reassembles a hello split over records
    pending: _Pending[>..] = [],      // events for the handler block, delivered at the end of on_event
    pending_head: i64 = 0,
    override_targets: Target[>..] = [],   // targets given to forward(); a free entry has no addresses
    data_copy: u8[>..] = [],            // handler Data bytes are copied here so the handler may call code that the borrow checker cannot prove apart from the loop's buffers
    pass_end: bool = false,           // the handler asked for PassEnd
    tags: _TagEntry[..64] = [],       // deadlines per tag
    tags_full: bool = false,          // a deadline could not be recorded: every tag without an entry is fenced (RT-6g)
    scan_at: i64 = 0,                 // when to look for links past their deadline (0 none)
    policy_on: bool = false,          // a policy picks the servers
}

fn _kind_text(k: goose_io::ListenErrorKind) -> const u8[:] {
    return match k {
        None => "no error", AddressInUse => "Address already in use", BadAddress => "bad address",
        Denied => "Permission denied", NoResources => "out of resources", Other => "error",
    };
}

// Requires the capabilities the router uses, then listens on every configured listener. false (and `error` says why) when not.
fn start<Io>(w: Worker&, io: Io&, cfg: const Config&, index: i64) -> bool {
    goose_io::require_core(io);
    goose_io::require_half_close(io);
    goose_io::require_sizing(io);
    goose_io::require_abort(io);
    goose_io::require_inspection(io);
    goose_io::require_relay(io);
    goose_io::require_peek(io);
    goose_io::require_revoke(io);
    goose_io::require_wake(io);
    goose_io::require_limits(io);
    w.cfg = cfg;
    w.index = index;
    for f in cfg.fenced_tags { w.tags.push(_TagEntry { tag: f, until_ms: 0 }); }
    for k in cfg.listeners.len {
        let text = cfg.listeners[k].addr.text;
        let l, err = io.listen(text);
        if goose_io::failed(err) {
            w.error.append("cannot listen on ");
            w.error.append(text);
            w.error.append(": ");
            w.error.append(_kind_text(err.kind));
            return false;
        }
        w.listener_ids.push(l.id);
    }
    io.tick_by(io.now_ms() + _TICK_MS);
    qput(_WakerReport { index: index, waker: io.waker() });
    true
}

fn _listener_index(w: Worker&, id: u32) -> i64 {
    for k in w.listener_ids.len { if w.listener_ids[k] == id { return k; } }
    return -1;
}

fn _reason_of(why: goose_io::CloseReason) -> CloseReason {
    return match why {
        PeerClosed => CloseReason.PeerClosed, PeerReset => CloseReason.PeerReset, ConnectFailed f => CloseReason.ConnectFailed,
        IdleTimeout => CloseReason.IdleTimeout, HalfCloseTimeout => CloseReason.HalfCloseTimeout,
        Local => CloseReason.ByHandler, Shutdown => CloseReason.Drained, Error => CloseReason.Error, LoopSpecific p => CloseReason.Error,
    };
}

// The router decides a link's reason, overriding what the loop reports.
fn _decide(r: _Rec&, why: CloseReason) { r.why = why; r.decided = true; }

fn _target_for(w: Worker&, cr: _Rec&) -> Target {
    if cr.override >= 0 { return w.override_targets[cr.override]; }
    return w._target_of(cr.route);
}

fn _target_of(w: Worker&, route: i64) -> Target {
    var t = Target { addrs: [] };
    match w.cfg.routes[route].action {
        Forward f => { if f.to < w.cfg.targets.len { t = w.cfg.targets[f.to as i64]; } },
        _ => {},
    }
    t
}

// Dials the next address not yet tried for client `c`. false when none is left.
fn _dial_next<Io>(w: Worker&, io: Io&, c: goose_io::Link, retry: bool) -> bool {
    let cr = w.recs.find(c);
    guard cr else { return false; }
    let target = w._target_for(cr);
    let count = target.addrs.len;
    cr.tag = target.tag;
    cr.target_gen = target.gen;
    if !w._tag_allows(io, cr.tag) { cr._decide(CloseReason.Fenced); io.close(c); return true; }
    var failed = retry;
    loop {
        if cr.tries >= count { return false; }
        let at = (cr.first + cr.tries) % count;
        cr.tries++;
        if target.addrs[at].text.len == 0 { continue; }
        if failed { w.stats.retries++; }
        let s = io.dial(target.addrs[at].text, w.cfg.limits.connect_timeout_ms);
        if goose_io::is_valid(s) {
            w.recs.put(s, _Rec { role: _Role.Server, partner: c, tag: cr.tag, target_gen: cr.target_gen });
            w._arm_fence(io, s, cr.tag);
            w._arm_fence(io, c, cr.tag);
            cr.partner = s;
            return true;
        }
        w.stats.connect_failures++;
        failed = true;
    }
}

// The policy picks where client `c` goes next and the router dials it.
recursive fn _policy_pick<Io, P>(w: Worker&, io: Io&, pol: P&, c: goose_io::Link) {
    let cr = w.recs.find(c);
    guard cr else { return; }
    var to: u16 = 0;
    match w.cfg.routes[cr.route].action { Forward f => { to = f.to; }, _ => {}, }
    let pick = pol.pick(to, _conn(c), cr.tried, io.now_ms());
    match pick {
        To t => {
            if t.slot >= _MAX_POLICY_SLOTS { cr._decide(CloseReason.ConnectFailed); io.close(c); return; }
            cr.tried |= (1 as u32) << t.slot;
            cr.pick_slot = t.slot;
            cr.tag = t.tag;
            cr.target_gen = t.gen;
            cr.pick_connect_ms = t.connect_ms as i32;
            if !w._tag_allows(io, t.tag) { cr._decide(CloseReason.Fenced); io.close(c); return; }
            let ms = if t.connect_ms > 0 { t.connect_ms } else { w.cfg.limits.connect_timeout_ms };
            let s = io.dial(t.addr.text, ms);
            if goose_io::is_valid(s) {
                w.recs.put(s, _Rec { role: _Role.Server, partner: c, tag: t.tag, target_gen: t.gen });
                w._arm_fence(io, s, t.tag);
                w._arm_fence(io, c, t.tag);
                cr.partner = s;
            } else {
                w.stats.connect_failures++;
                w._policy_failed(io, pol, c);
            }
        },
        _ => { cr._decide(CloseReason.ConnectFailed); io.close(c); },
    }
}

// The pick could not be connected: ask the policy whether to try again.
recursive fn _policy_failed<Io, P>(w: Worker&, io: Io&, pol: P&, c: goose_io::Link) {
    let cr = w.recs.find(c);
    guard cr else { return; }
    let again = pol.connect_failed(_conn(c), cr.pick_slot, cr.tag, cr.tried, io.now_ms());
    if again == Retry.Next {
        w.stats.retries++;
        w._policy_pick(io, pol, c);
    } else {
        cr._decide(CloseReason.ConnectFailed);
        io.close(c);
    }
}

fn _on_accepted<Io, P>(w: Worker&, io: Io&, pol: P&, link: goose_io::Link, listener: i64) {
    w.stats.accepted++;
    if w.stats.open >= w.cfg.limits.max_conns_per_worker {
        w.recs.put(link, _Rec { role: _Role.Refused });
        io.close(link);
        return;
    }
    w.stats.open++;
    w.recs.put(link, _Rec { role: _Role.Client, listener: listener as u8 });
    let cr = w.recs.find(link);
    guard cr else { return; }
    if w.cfg.listeners[listener].inspect == Inspect.Sni {
        cr.inspecting = true;
        cr.inspected = true;
        io.set_limit(link, goose_io::Limit.Age, w.cfg.limits.inspect_timeout_ms);
        io.wait_input(link, 1);
        return;
    }
    w._route_and_connect(io, pol, link, Hello.NoSni);
}

// Routes client `link` on what its first bytes were and starts connecting.
fn _route_and_connect<Io, P>(w: Worker&, io: Io&, pol: P&, link: goose_io::Link, hello: Hello) {
    let cr = w.recs.find(link);
    guard cr else { return; }
    let route = match_route(w.cfg, w.cfg.listeners[cr.listener].id, hello);
    guard route else { cr._decide(CloseReason.ByHandler); io.close(link); return; }
    cr.route = w.cfg.routes.index_of(route) as i32;
    var count = 0;
    var forward = false;
    var handle = false;
    var tag: u16 = 0;
    match route.action {
        Forward f => { forward = true; count = w._target_of(cr.route).addrs.len; },
        Handle h => { handle = true; tag = h.tag; },
        _ => {},
    }
    if handle {
        cr.role = _Role.Handler;
        cr.tag = tag;
        io.set_keep_open_on_eof(link, true);   // inside Opened when the route needs no hello; the router decides later what PeerEof means
        if !w._tag_allows(io, tag) { cr._decide(CloseReason.Fenced); io.close(link); return; }
        w._arm_fence(io, link, tag);
        cr.inspecting = false;
        io.set_limit(link, goose_io::Limit.Idle, w.cfg.limits.idle_timeout_ms);
        var p = _Pending { kind: 1, link: link, tag: tag, listener: w.cfg.listeners[cr.listener].id, sni: [] };
        match hello { Found f => { p.sni.append(f.name[..]); }, _ => {}, }
        w.pending.push(p);
        return;
    }
    if forward && w.policy_on {
        cr.policied = true;
        io.pause_reading(link, true);
        w._policy_pick(io, pol, link);
        return;
    }
    if !forward || count == 0 { cr._decide(CloseReason.ByHandler); io.close(link); return; }
    cr.first = (w.round_robin % count) as u8;
    w.round_robin++;
    io.pause_reading(link, true);
    if !w._dial_next(io, link, false) { cr._decide(CloseReason.ConnectFailed); io.close(link); }
}

// The client's first bytes are here (or its end): peek, parse, route (stage 2).
fn _on_client_input<Io, P>(w: Worker&, io: Io&, pol: P&, link: goose_io::Link, cr: _Rec&, available: i64) {
    let bytes = io.peek(link);
    if bytes.len == 0 || bytes.len <= cr.seen { cr._decide(CloseReason.PeerClosed); io.close(link); return; }     // ended with no (more) bytes: the peer's end
    cr.seen = bytes.len as i32;
    let hello = parse_hello(bytes, w.scratch[..]);
    match hello {
        NeedMore more => {
            if more.total > _MAX_HELLO { cr._decide(CloseReason.InvalidHello); io.close(link); return; }
            io.wait_input(link, more.total);
            return;
        },
        Invalid => { cr._decide(CloseReason.InvalidHello); io.close(link); return; },
        _ => {},
    }
    cr.inspecting = false;
    io.set_limit(link, goose_io::Limit.Age, 0);
    w._route_and_connect(io, pol, link, hello);
}

// The server's first byte (or its end) after the hello was sent (RT-21).
fn _on_server_input<Io, P>(w: Worker&, io: Io&, pol: P&, link: goose_io::Link, sr: _Rec&, available: i64) {
    if available == 0 { sr.early = true; io.close(link); return; }
    let client = sr.partner;
    io.discard_input(client, sr.hello_len);
    sr.hello_sent = false;
    w._join(io, pol, client, link);
}

fn _join<Io, P>(w: Worker&, io: Io&, pol: P&, client: goose_io::Link, link: goose_io::Link) {
    let r = io.relay(client, link);
    match r {
        Started => {
            let jr = w.recs.find(client);
            if jr && jr.policied && !jr.told { jr.told = true; pol.connected(_conn(client), jr.tag); }
            io.set_limit(client, goose_io::Limit.Idle, w.cfg.limits.idle_timeout_ms);
            io.set_limit(link, goose_io::Limit.Idle, w.cfg.limits.idle_timeout_ms);
            io.set_limit(client, goose_io::Limit.HalfOpen, w.cfg.limits.half_close_timeout_ms);
            io.set_limit(link, goose_io::Limit.HalfOpen, w.cfg.limits.half_close_timeout_ms);
        },
        _ => { io.close(link); io.close(client); },
    }
}

fn _on_opened<Io, P>(w: Worker&, io: Io&, pol: P&, link: goose_io::Link, listener: goose_io::Listener) {
    if goose_io::is_listener(listener) {
        let k = w._listener_index(listener.id);
        if k >= 0 { w._on_accepted(io, pol, link, k); } else { io.close(link); }
        return;
    }
    let sr = w.recs.find(link);
    guard sr else { io.close(link); return; }
    let client = sr.partner;
    let cr = w.recs.find(client);
    if cr && cr.inspected {
        let held = io.peek(client);
        sr.hello_len = held.len as i32;
        sr.hello_sent = true;
        if io.send(link, held) != goose_io::SendStatus.Sent { sr.early = true; io.close(link); return; }
        io.wait_input(link, 1);
        return;
    }
    w._join(io, pol, client, link);
}

fn _on_closed<Io, P>(w: Worker&, io: Io&, pol: P&, link: goose_io::Link, why: goose_io::CloseReason) {
    let r = w.recs.find(link);
    guard r else { return; }
    if r.role == _Role.Refused {
        w.stats.closed[_slot(CloseReason.Error)]++;
        w.recs.drop(link);
        return;
    }
    let carried = io.relayed_bytes(link);
    if r.role == _Role.Client { w.stats.bytes_in += carried; } else { w.stats.bytes_out += carried; }
    // A dial that failed: count it, try the next address, or end the client with ConnectFailed.
    if r.role == _Role.Server && (goose_io::is_connect_failed(why) || r.early || r.hello_sent) {
        w.stats.connect_failures++;
        let client = r.partner;
        let cr = w.recs.find(client);
        w.recs.drop(link);
        if cr && !cr.done {
            if cr.policied { w._policy_failed(io, pol, client); }
            else if !w._dial_next(io, client, true) { cr._decide(CloseReason.ConnectFailed); io.close(client); }
        }
        return;
    }
    w._fence_reason(io, r, why);
    var reason = _reason_of(why);
    if r.decided { reason = r.why; }
    r.done = true;
    r.reason = reason;
    let p = w.recs.find(r.partner);
    let strong = !_vague(reason);
    if r.role == _Role.Client && r.told {
        var told = reason;
        if !strong && p && p.done && !_vague(p.reason) { told = p.reason; }
        pol.closed(_conn(link), r.tag, told);
    }
    if !r.counted {
        var count_it = false;
        var counted = reason;
        if strong { count_it = true; }
        else if !p || p.done {
            count_it = true;
            if p && p.reason == CloseReason.Error { counted = CloseReason.Error; }
        }
        if count_it {
            w.stats.closed[_slot(counted)]++;
            w.stats.open--;
            r.counted = true;
            if p { p.counted = true; }
        }
    }
    // A client closed while its server is still dialling or open: the server goes too.
    if p && !p.done { if r.role == _Role.Client && p.role == _Role.Server { io.close(r.partner); } }
    if !p || p.done {
        w.recs.drop(r.partner);
        w.recs.drop(link);
    }
}

// A link the loop ended with Local at its write deadline was fenced.
fn _fence_reason<Io>(w: Worker&, io: Io&, r: _Rec&, why: goose_io::CloseReason) {
    var local = false;
    match why { Local => { local = true; }, _ => {}, }
    if local && !r.decided && r.tag != 0 && ((r.armed && !r.closing) || !w._tag_allows(io, r.tag)) { r._decide(CloseReason.Fenced); }
}

fn _on_expired<Io>(w: Worker&, io: Io&, link: goose_io::Link, limit: goose_io::Limit) {
    let r = w.recs.find(link);
    guard r else { return; }
    var why = CloseReason.IdleTimeout;
    match limit { HalfOpen => { why = CloseReason.HalfCloseTimeout; }, Age => { why = CloseReason.InspectTimeout; }, _ => {}, }
    r._decide(why);
    let p = w.recs.find(r.partner);
    if p { p._decide(why); }
    io.close(link);
}

// What the router does with an event of its own (links it forwards, inspects or dials for a handler's account).
fn _core_event<Io, P>(w: Worker&, io: Io&, pol: P&, ev: goose_io::Event) {
    match ev {
        Opened o => { w._on_opened(io, pol, o.link, o.listener); },
        Closed c => { w._on_closed(io, pol, c.link, c.why); },
        Expired x => { w._on_expired(io, x.link, x.limit); },
        Input i => {
            let r = w.recs.find(i.link);
            guard r else { return; }
            if r.role == _Role.Client && r.inspecting { w._on_client_input(io, pol, i.link, r, i.available); }
            else if r.role == _Role.Server && r.hello_sent { w._on_server_input(io, pol, i.link, r, i.available); }
        },
        Tick t => { io.tick_by(t.now_ms + _TICK_MS); w._enforce_deadlines(io); },
        Woken x => { w._on_woken(io, x.value, x.body[..], pol); },
        _ => {},
    }
}
