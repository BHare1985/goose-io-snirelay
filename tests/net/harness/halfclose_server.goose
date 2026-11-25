// Gate for graceful close of handler connections (RT-15): half-close, shutdown_write, send_room.
//
//     halfclose_server --listen 127.0.0.1:9000
//
// Requests (GET only, one per connection; the connection opts in to keeping itself open after the peer's EOF):
//   GET /N        N bytes of the pattern (body[i] = i % 251), sent as send() accepts them (false -> wait for Writable), then shutdown_write
//   GET /room     prints `ROOM fresh=F after1000=A full=0|>0 after_drain=D`, then answers "ok" and closes
//   GET /draining "1" if this worker is draining, else "0" (the connection stays usable for another request)
//   GET /hang     opts in, answers nothing and never closes (the half-close timeout must end it)
//   GET /trickle  opts in, then sends one byte on every Tick until send says false (fencing must end it)
//   GET /plain/N  like /N but WITHOUT the opt-in (the default: the connection closes after the peer's EOF, queued bytes flushed first)
// stdout: READY, PEER_EOF (once per connection that opted in), CLOSED why=W, ROOM ...
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";
import tcprouter from "../../..";
import slot_pool;
import std;
import os;

let PERIOD = 251;

struct Session {
    left: i64,                       // body bytes still to send
    at: i64,                         // body bytes already sent
    req: u8[..512],
    done: bool,
    room_probe: bool,                // /room: the probe is running
    fresh: i64, after1000: i64,
    trickle: bool,
    conn_self: tcprouter::Conn,
}

var LISTEN: u8[>..] = [];

fn pump(w: tcprouter::Worker&, io: epoll_ext::Loop&, s: Session&, conn: tcprouter::Conn) {
    while s.left > 0 {
        let n = if s.left < 16384 { s.left } else { 16384 };
        var piece: u8[16384] = [0; 16384];
        for k in n { piece[k] = ((s.at + k) % PERIOD) as! u8; }
        if !w.send(io, conn, piece[..n]) { return; }
        s.left -= n; s.at += n;
    }
    if !s.done {
        s.done = true;
        w.shutdown_write(io, conn);
        print("SEND_AFTER_SHUTDOWN ", w.send(io, conn, "x"));       // must be false
    }
}

fn room_probe(w: tcprouter::Worker&, io: epoll_ext::Loop&, s: Session&, conn: tcprouter::Conn) {
    // first call: measure, send 1000 bytes, measure, then fill the queue until send says no
    if !s.room_probe {
        s.room_probe = true;
        s.fresh = w.send_room(io, conn);
        var k: u8[1000] = [7; 1000];
        w.send(io, conn, k[..]);
        s.after1000 = w.send_room(io, conn);
        var big: u8[16384] = [9; 16384];
        while w.send(io, conn, big[..]) { }
        print("ROOM fresh=", s.fresh, " after1000=", s.after1000, " full=", w.send_room(io, conn));
        return;                                   // the rest on Writable
    }
    print("ROOM after_drain=", w.send_room(io, conn));
    w.close(io, conn);
}

fn on_data(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32, bytes: const u8[:]) {
    if user == 0 || (user - 1) as i64 >= sessions.items.len { return; }
    let s .= sessions.items[(user - 1) as i64];
    print("EV data ", bytes.len);
    if s.req.len + bytes.len > s.req.cap { w.close(io, conn); return; }
    s.req.append(bytes);
    let end = find(s.req, "\r\n\r\n");
    if end < 0 || s.left > 0 || s.done { return; }
    let line = s.req[..find(s.req, "\r\n")];
    let target = line[4..find(line[4..], " ") + 4];
    if target == "/room" { room_probe(w, io, s, conn); return; }
    if target == "/draining" {
        let text = if w.draining(io) { "1" } else { "0" };
        var out: u8[>..] = [];
        format(out, "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n", text);
        w.send(io, conn, out);
        s.req.clear();
        return;
    }
    if target == "/hang" { w.set_keep_open_on_eof(io, conn, true); return; }
    if target == "/trickle" { w.set_keep_open_on_eof(io, conn, true); s.trickle = true; return; }
    var skip: i64 = 1;
    var keep = true;
    if target.len > 7 && target[..7] == "/plain/" { skip = 7; keep = false; }
    let n, ok = parse_int(target[skip..]);
    if !ok { w.close(io, conn); return; }
    if keep { w.set_keep_open_on_eof(io, conn, true); }
    s.left = n; s.at = 0;
    pump(w, io, s, conn);
}

fn on_writable(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32) {
    if user == 0 || (user - 1) as i64 >= sessions.items.len { return; }
    let s .= sessions.items[(user - 1) as i64];
    if s.room_probe { room_probe(w, io, s, conn); } else { pump(w, io, s, conn); }
}

// /trickle: one byte per Tick, after the peer's EOF as well, until send says false.
fn on_tick(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&) {
    for i in sessions.items.len {
        let s .= sessions.items[i];
        if s.trickle && !s.done {
            if !w.send(io, s.conn_self, "t") { s.done = true; print("TRICKLE_FALSE"); }
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
    if !w.start(io, cfg, index) { epoll_ext::report_failed_start(); write_stderr(str("halfclose_server: ", w.error, "\n")); return; }
    io.attach(index);
    print("READY");
    io.serve() { io, ev => w.on_event(io, ev) { w, io, ev =>
        match ev {
            Opened o => {
                let id = sessions.alloc_index(Session { left: 0, at: 0, req: [], done: false, room_probe: false, fresh: 0, after1000: 0, trickle: false, conn_self: o.conn });
                w.set_user(io, o.conn, (id + 1) as u32);
            },
            Data d => { on_data(w, io, sessions, d.conn, d.user, d.bytes); },
            Writable x => { on_writable(w, io, sessions, x.conn, x.user); },
            PeerEof e => { print("PEER_EOF"); },
            Tick k => { on_tick(w, io, sessions); },
            Closed c => {
                print("CLOSED why=", c.why);
                if c.user > 0 && (c.user - 1) as i64 < sessions.items.len { sessions.free((c.user - 1) as i64); }
            },
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
    } else if parts.len == 2 && parts[0] == "drain" {
        let ms, ok = parse_int(parts[1]);
        if ok { tcprouter::post(io, tcprouter::Message.Drain { deadline_ms: ms }); }
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
    while i + 1 < a.len {
        if a[i] == "--listen" { LISTEN.append(a[i + 1]); }
        i += 2;
    }
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(LISTEN) });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Handle { tag: 7 }));
    cfg.limits.half_close_timeout_ms = 1000;       // RT-15f

    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    let ids = epoll_ext::spawn(1, cfg, worker);
    tcprouter::workers_ready(1);
    thread_spawn(control);
    for id in ids { thread_wait(id); }
}
