// Gate for graceful close of handler connections (RT-15): half-close, shutdown_write, send_room.
//
//     halfclose_server --listen 127.0.0.1:9000
//
// Requests (GET only, one per connection; the connection opts in to keeping itself open after the peer's EOF):
//   GET /N        N bytes of the pattern (body[i] = i % 251), sent as send() accepts them (false -> wait for Writable), then shutdown_write
//   GET /room     prints `ROOM fresh=F after1000=A full=0|>0 after_drain=D`, then answers "ok" and closes
//   GET /hang     opts in, answers nothing and never closes (the half-close timeout must end it)
//   GET /trickle  opts in, then sends one byte on every Tick until send says false (fencing must end it)
//   GET /plain/N  like /N but WITHOUT the opt-in (the default: the connection closes after the peer's EOF, queued bytes flushed first)
// stdout: READY, PEER_EOF (once per connection that opted in), CLOSED why=W, ROOM ...
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

fn pump(w: tcprouter::Worker&, s: Session&, conn: tcprouter::Conn) {
    while s.left > 0 {
        let n = if s.left < 16384 { s.left } else { 16384 };
        var piece: u8[16384] = [0; 16384];
        for k in n { piece[k] = ((s.at + k) % PERIOD) as! u8; }
        if !w.send(conn, piece[..n]) { return; }
        s.left -= n; s.at += n;
    }
    if !s.done {
        s.done = true;
        w.shutdown_write(conn);
        print("SEND_AFTER_SHUTDOWN ", w.send(conn, "x"));       // must be false
    }
}

fn room_probe(w: tcprouter::Worker&, s: Session&, conn: tcprouter::Conn) {
    // first call: measure, send 1000 bytes, measure, then fill the queue until send says no
    if !s.room_probe {
        s.room_probe = true;
        s.fresh = w.send_room(conn);
        var k: u8[1000] = [7; 1000];
        w.send(conn, k[..]);
        s.after1000 = w.send_room(conn);
        var big: u8[16384] = [9; 16384];
        while w.send(conn, big[..]) { }
        print("ROOM fresh=", s.fresh, " after1000=", s.after1000, " full=", w.send_room(conn));
        return;                                   // the rest on Writable
    }
    print("ROOM after_drain=", w.send_room(conn));
    w.close(conn);
}

fn on_data(w: tcprouter::Worker&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32, bytes: const u8[:]) {
    if user == 0 || (user - 1) as i64 >= sessions.items.len { return; }
    let s .= sessions.items[(user - 1) as i64];
    print("EV data ", bytes.len);
    if s.req.len + bytes.len > s.req.cap { w.close(conn); return; }
    s.req.append(bytes);
    let end = find(s.req, "\r\n\r\n");
    if end < 0 || s.left > 0 || s.done { return; }
    let line = s.req[..find(s.req, "\r\n")];
    let target = line[4..find(line[4..], " ") + 4];
    if target == "/room" { room_probe(w, s, conn); return; }
    if target == "/hang" { w.set_keep_open_on_eof(conn, true); return; }
    if target == "/trickle" { w.set_keep_open_on_eof(conn, true); s.trickle = true; return; }
    var skip: i64 = 1;
    var keep = true;
    if target.len > 7 && target[..7] == "/plain/" { skip = 7; keep = false; }
    let n, ok = parse_int(target[skip..]);
    if !ok { w.close(conn); return; }
    if keep { w.set_keep_open_on_eof(conn, true); }
    s.left = n; s.at = 0;
    pump(w, s, conn);
}

fn on_writable(w: tcprouter::Worker&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32) {
    if user == 0 || (user - 1) as i64 >= sessions.items.len { return; }
    let s .= sessions.items[(user - 1) as i64];
    if s.room_probe { room_probe(w, s, conn); } else { pump(w, s, conn); }
}

// /trickle: one byte per Tick, after the peer's EOF as well, until send says false.
fn on_tick(w: tcprouter::Worker&, sessions: slot_pool<Session>&) {
    for i in sessions.items.len {
        let s .= sessions.items[i];
        if s.trickle && !s.done {
            if !w.send(s.conn_self, "t") { s.done = true; print("TRICKLE_FALSE"); }
        }
    }
}

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var sessions = slot_pool<Session> {};
    var w = tcprouter::Worker { .. };
    if !w.start(cfg, index) { write_stderr(str("halfclose_server: ", w.error, "\n")); return; }
    print("READY");
    w.serve() { w, ev =>
        match ev {
            Opened o => {
                let id = sessions.alloc_index(Session { left: 0, at: 0, req: [], done: false, room_probe: false, fresh: 0, after1000: 0, trickle: false, conn_self: o.conn });
                w.set_user(o.conn, (id + 1) as u32);
            },
            Data d => { on_data(w, sessions, d.conn, d.user, d.bytes); },
            Writable x => { on_writable(w, sessions, x.conn, x.user); },
            PeerEof e => { print("PEER_EOF"); },
            Tick k => { on_tick(w, sessions); },
            Closed c => {
                print("CLOSED why=", c.why);
                if c.user > 0 && (c.user - 1) as i64 < sessions.items.len { sessions.free((c.user - 1) as i64); }
            },
            _ => {},
        }
    };
}

extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

fn run_command(line: const u8[:]) {
    let parts = words(line);
    if parts.len == 3 && parts[0] == "deadline" {
        let tag, ok1 = parse_int(parts[1]);
        let until, ok2 = parse_int(parts[2]);
        if ok1 && ok2 { tcprouter::post(tcprouter::Message.Deadline { tag: tag as u16, until_ms: until }); }
    }
}

thread_fn control() {
    var pending: u8[>..] = [];
    var chunk: u8[256] = [0; 256];
    loop {
        let n = read(0, chunk[0], 256);
        if n <= 0 { return; }
        pending.append(chunk[..n]);
        loop {
            let nl = find(pending, "\n");
            if nl < 0 { break; }
            run_command(pending[..nl]);
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
    let ids = tcprouter::spawn(cfg, 1, worker);
    thread_spawn(control);
    for id in ids { thread_wait(id); }
}
