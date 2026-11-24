// Gate for w.dial (RT-14a to RT-14k): a handler-mode server on tag 7 that makes outbound connections for its clients.
//
//     dial_server --listen 127.0.0.1:9000 [--workers N] --control
//
// Requests (HTTP-ish, one per client connection, answered on that connection):
//   GET /fast                 "ok"
//   GET /via/PORT[/MS]        dial 127.0.0.1:PORT (connect timeout MS, default 2000), send "hello" once Opened, answer with what comes back
//   GET /pipe/PORT/N          dial, then on Opened send N small messages "qNNNN\n" back to back (honouring false and Writable), answer OK/BAD
//                             when the echo has returned all of them in order
//   GET /fence/PORT           dial with tag 9, send one byte on every Tick until send says false
//   GET /open                 how many connections this worker has open (the leak check)
// stdin (control): `deadline TAG MS`.
// stdout: `DIAL send_before_open=B`, `DIAL_OPENED id=N`, `DIAL_CLOSED id=N why=W opened=B`, `FENCE_SEND_FALSE`, `READY`.
import goose_io from "github.com/BHare1985/goose-io@v0.4";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";
import tcprouter from "../../..";
import slot_pool;
import std;
import os;

let TAG_CLIENT: u16 = 7;
let TAG_FENCED: u16 = 9;
let FNV_OFFSET: u64 = 14695981039346656037;
let FNV_PRIME: u64 = 1099511628211;
let BIG: i64 = 1000;                 // /pipeb: bytes per message

struct Session {
    role: u8,                       // 0 = an accepted client, 1 = a dialled connection
    mode: u8,                       // dialled: 1 via, 2 pipe, 3 fence
    peer: u32,                      // the other session's id + 1 (0 = none)
    peer_conn: tcprouter::Conn,
    self_conn: tcprouter::Conn,      // dialled: its own handle (for the Tick sends)
    opened: bool,
    answered: bool,
    total: i64,                     // pipe: messages to send
    next: i64,                      // pipe: next message to send
    falses: i64,                    // pipe: how many sends said no
    req: u8[..512],                 // client: the request so far
    got: u8[..4096],                // pipe: the echo so far
    fnv: u64,                       // pipeb: FNV-1a of the echo so far
    received: i64,                  // pipeb: bytes of the echo so far
}

var LISTEN: u8[>..] = [];
var WORKERS: i64 = 1;

fn fresh(role: u8) -> Session {
    Session { role: role, mode: 0, peer: 0, peer_conn: tcprouter::Conn { slot: 0, gen: 0 }, self_conn: tcprouter::Conn { slot: 0, gen: 0 }, opened: false, answered: false,
              total: 0, next: 0, falses: 0, req: [], got: [], fnv: FNV_OFFSET, received: 0 }
}

fn reply(w: tcprouter::Worker&, io: epoll_ext::Loop&, c: tcprouter::Conn, status: const u8[:], body: const u8[:]) {
    var out: u8[>..] = [];
    format(out, "HTTP/1.1 ", status, "\r\nContent-Length: ", body.len, "\r\n\r\n");
    out.append(body);
    w.send(io, c, out);
}

fn message(n: i64) -> u8[>..] {
    var m: u8[>..] = [];
    format(m, "q", n / 1000 % 10, n / 100 % 10, n / 10 % 10, n % 10, "\n");
    m
}

// Sends the pipelined messages from where it stopped; false when the queue said no (Writable continues).
fn pump(w: tcprouter::Worker&, io: epoll_ext::Loop&, d: Session&, conn: tcprouter::Conn) {
    while d.next < d.total {
        var m = message(d.next);
        if d.mode == 4 { m.clear(); for j in BIG { m.push((d.next % 251) as! u8); } }
        if !w.send(io, conn, m) { d.falses++; return; }
        d.next++;
    }
}

fn start_dial(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, client: tcprouter::Conn, client_id: u32, port: i64, ms: i64, mode: u8, count: i64) {
    var d = fresh(1);
    d.mode = mode; d.total = count; d.peer = client_id + 1; d.peer_conn = client;
    let id = sessions.alloc_index(d);
    var addr: u8[>..] = [];
    format(addr, "127.0.0.1:", port);
    let tag = if mode == 3 { TAG_FENCED } else { TAG_CLIENT };
    let conn = w.dial(io, addr, tag, ms);
    w.set_user(io, conn, (id + 1) as u32);
    sessions.items[client_id].peer = (id + 1) as u32;
    sessions.items[client_id].peer_conn = conn;
    if mode == 1 {
        let early = w.send(io, conn, "hello");           // before Opened: must be false and queue nothing
        print("DIAL send_before_open=", early);
    }
}

fn answer(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, id: u32) {
    let s .= sessions.items[id];
    let end = find(s.req, "\r\n\r\n");
    if end < 0 { return; }
    let line_end = find(s.req, "\r\n");
    let line = s.req[..line_end];
    let target = line[4..find(line[4..], " ") + 4];
    if target == "/fast" { reply(w, io, conn, "200 OK", "ok"); s.req.clear(); return; }
    if target == "/open" { let text = str(w.snapshot(io).open); reply(w, io, conn, "200 OK", text); s.req.clear(); return; }
    var kind: u8 = 0;
    var skip: i64 = 0;
    if target.len > 5 && target[..5] == "/via/" { kind = 1; skip = 5; }
    else if target.len > 6 && target[..6] == "/pipe/" { kind = 2; skip = 6; }
    else if target.len > 7 && target[..7] == "/fence/" { kind = 3; skip = 7; }
    else if target.len > 7 && target[..7] == "/pipeb/" { kind = 4; skip = 7; }
    if kind == 0 { reply(w, io, conn, "404 Not Found", ""); s.req.clear(); return; }
    let rest = target[skip..];
    let slash = find(rest, "/");
    let port, ok1 = parse_int(if slash < 0 { rest } else { rest[..slash] });
    var extra: i64 = 0;
    if slash >= 0 { let v, ok2 = parse_int(rest[slash + 1..]); extra = v; }
    s.req.clear();
    if !ok1 { reply(w, io, conn, "400 Bad Request", ""); return; }
    start_dial(w, io, sessions, conn, id, port, if kind == 1 && extra > 0 { extra } else { 2000 }, kind, if kind == 2 || kind == 4 { extra } else { 0 });
}

fn on_opened(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, conn: tcprouter::Conn) {
    let user = w.user(io, conn);
    if user == 0 {                                    // an accepted client
        let id = sessions.alloc_index(fresh(0));
        w.set_user(io, conn, (id + 1) as u32);
        return;
    }
    let id = (user - 1) as i64;
    if id >= sessions.items.len { return; }
    let d .= sessions.items[id];
    d.opened = true;
    d.self_conn = conn;
    print("DIAL_OPENED id=", id);
    if d.mode == 1 { w.send(io, conn, "hello"); }
    else if d.mode == 2 || d.mode == 4 { pump(w, io, d, conn); }
    else if d.mode == 3 { w.send(io, conn, "x"); }
}

fn on_data(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32, bytes: const u8[:]) {
    if user == 0 || (user - 1) as i64 >= sessions.items.len { return; }
    let id = (user - 1) as i64;
    let s .= sessions.items[id];
    if s.role == 0 {
        if s.req.len + bytes.len > s.req.cap { w.close(io, conn); return; }
        s.req.append(bytes);
        answer(w, io, sessions, conn, id as u32);
        return;
    }
    if s.answered { return; }
    if s.mode == 1 {
        s.answered = true;
        reply(w, io, s.peer_conn, "200 OK", bytes);
        w.close(io, conn);
    } else if s.mode == 2 {
        if s.got.len + bytes.len <= s.got.cap { s.got.append(bytes); }
        if s.got.len == s.total * 6 {
            var ok = true;
            for k in s.total { let m = message(k); for j in 6 { if s.got[k * 6 + j] != m[j] { ok = false; } } }
            s.answered = true;
            let text = if ok { str("OK falses=", s.falses) } else { str("BAD") };
            reply(w, io, s.peer_conn, "200 OK", text);
            w.close(io, conn);
        }
    } else if s.mode == 4 {
        for b in bytes { s.fnv = (s.fnv ^ b) * FNV_PRIME; }
        s.received += bytes.len;
        if s.received == s.total * BIG {
            var want = FNV_OFFSET;
            for k in s.total { for j in BIG { want = (want ^ ((k % 251) as! u8)) * FNV_PRIME; } }
            s.answered = true;
            let text = if want == s.fnv { str("OK falses=", s.falses) } else { str("BAD") };
            reply(w, io, s.peer_conn, "200 OK", text);
            w.close(io, conn);
        }
    }
}

fn on_writable(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32) {
    if user == 0 || (user - 1) as i64 >= sessions.items.len { return; }
    let d .= sessions.items[(user - 1) as i64];
    if d.role == 1 && (d.mode == 2 || d.mode == 4) && d.opened { pump(w, io, d, conn); }
}

fn on_closed(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, user: u32, why: tcprouter::CloseReason) {
    if user == 0 || (user - 1) as i64 >= sessions.items.len { return; }
    let id = (user - 1) as i64;
    let s .= sessions.items[id];
    if s.role == 1 {
        print("DIAL_CLOSED id=", id, " why=", why, " opened=", s.opened);
        if !s.answered && s.peer > 0 { reply(w, io, s.peer_conn, "502 Bad Gateway", "dial failed"); }
        if s.peer > 0 && (s.peer - 1) as i64 < sessions.items.len { sessions.items[(s.peer - 1) as i64].peer = 0; }
    } else if s.peer > 0 {
        w.close(io, s.peer_conn);
    }
    sessions.free(id);
}

// Mode 3: one byte on every Tick until send says false (the fence closed it).
fn on_tick(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&) {
    for i in sessions.items.len {
        let d .= sessions.items[i];
        if d.role == 1 && d.mode == 3 && d.opened && !d.answered {
            if !w.send(io, d.self_conn, "x") { d.answered = true; print("FENCE_SEND_FALSE"); }
        }
    }
}

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var sessions = slot_pool<Session> {};
    var io = epoll_ext::Loop { .. };
    io.limits.peek_bound = 32768;
    io.limits.buffer_size = cfg.limits.buffer_size;
    io.limits.buffers_per_loop = cfg.limits.buffers_per_worker;
    io.limits.batch_min_events = cfg.limits.batch_min_events;
    io.limits.batch_max_wait_us = cfg.limits.batch_max_wait_us;
    io.limits.max_links = cfg.limits.max_conns_per_worker;
    io.limits.connect_timeout_ms = cfg.limits.connect_timeout_ms;
    io.limits.idle_timeout_ms = cfg.limits.idle_timeout_ms;
    io.limits.half_close_timeout_ms = cfg.limits.half_close_timeout_ms;
    var w = tcprouter::Worker { .. };
    if !w.start(io, cfg, index) { epoll_ext::report_failed_start(); write_stderr(str("dial_server: ", w.error, "\n")); return; }
    io.attach(index);
    print("READY");
    io.serve() { io, ev => w.on_event(io, ev) { w, io, ev =>
        match ev {
            Opened o => { on_opened(w, io, sessions, o.conn); },
            Data d => { on_data(w, io, sessions, d.conn, d.user, d.bytes); },
            Writable x => { on_writable(w, io, sessions, x.conn, x.user); },
            Closed c => { on_closed(w, io, sessions, c.user, c.why); },
            Tick t => { on_tick(w, io, sessions); },
            _ => {},
        }
    }; };
}

extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

fn run_command(io: epoll_ext::Loop&, line: const u8[:]) {
    let parts = words(line);
    if parts.len == 3 && parts[0] == "deadline" {
        let tag, ok1 = parse_int(parts[1]);
        let until, ok2 = parse_int(parts[2]);
        if ok1 && ok2 { tcprouter::post(io, tcprouter::Message.Deadline { tag: tag as u16, until_ms: until }); }
    }
}

thread_fn control() {
    var io = epoll_ext::Loop { .. };                    // only names the wake operation; it never runs
    var pending: u8[>..] = [];
    var chunk: u8[256] = [0; 256];
    loop {
        let n = read(0, chunk[0], 256);
        if n <= 0 { return; }
        pending.append(chunk[..n]);
        loop {
            let nl = find(pending, "\n");
            if nl < 0 { break; }
            run_command(io, pending[..nl]);
            let rest = pending.len - nl - 1;
            for k in rest { pending[k] = pending[nl + 1 + k]; }
            pending.pop_n(nl + 1);
        }
    }
}

fn main() {
    let a = args();
    var i = 1;
    while i < a.len {
        if a[i] == "--control" { i++; continue; }
        if i + 1 >= a.len { break; }
        if a[i] == "--listen" { LISTEN.append(a[i + 1]); }
        else if a[i] == "--workers" { let n, ok = parse_int(a[i + 1]); if ok { WORKERS = n; } }
        i += 2;
    }
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(LISTEN) });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Handle { tag: TAG_CLIENT }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    let ids = epoll_ext::spawn(WORKERS, cfg, worker);
    tcprouter::workers_ready(WORKERS);
    thread_spawn(control);
    for id in ids { thread_wait(id); }
}
