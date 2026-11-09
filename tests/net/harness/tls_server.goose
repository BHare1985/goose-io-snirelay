// A TLS 1.2 / 1.3 server on tcprouter's handler mode, with gslib's sans-I/O TLS (github.com/SorinS/gslib) doing the cryptography.
// Support check only (design/09 O-9; not an HTTP router): it shows what tcprouter has to give a TLS engine, no more.
//
//   tls_server --listen ADDR --tag N --chain chain.der --key key.der [--control] [--log-events]
//
// How the two fit: tcprouter hands every byte the peer sent as a Data event; they go to `tls::server_feed`, which returns the
// bytes to send back (`out`: handshake flights, alerts, encrypted application records) and the decrypted application bytes
// (`app`). `out` is queued with `send` in pieces of one pool buffer; when `send` says no, the rest waits in the session and
// continues on Writable. Requests (HTTP/1.1, GET only, keep-alive):
//   GET /       "hello\n"
//   GET /N      N bytes, body[i] = i % 251 (made 16 KiB at a time, only while the previous records are out: backpressure)
//   GET /sni    the server name the client sent
//   GET /live   how many sessions this worker holds

import tcprouter from "../../..";
import gslib from "github.com/SorinS/gslib@714f87b387f2f9de6a4c7a77d9abc9db2516ee80";
import gslib.crypto.tls;
import gslib.crypto.tls.handshake;
import slot_pool;
import std;
import os;

let PIECE = 32768;                  // bytes of `out` given to one send (the engine's buffer size)
let WINDOW = 16384;                 // bytes of body encrypted at a time
let PERIOD = 251;

struct Session {
    live: bool,
    conn: tls::Conn,                // gslib's connection state, one per session
    pend: u8[..65536],              // bytes to send (a slot_pool item may hold no growable array, so this is a fixed one), from sent on
    sent: i64,
    req: u8[..4096],                // decrypted request bytes not yet answered
    left: i64,                      // body bytes still to encrypt
    at: i64,                        // body bytes already encrypted
    closing: bool,                  // close after `pend` is out
}

var CONFIG: tls::ServerConfig = tls::ServerConfig { .. };
var LOG_EVENTS: bool = false;

fn log(line: const u8[:]) { if LOG_EVENTS { print(line); } }

fn die(message: const u8[:]) {
    write_stderr(str("tls_server: ", message, "\n"));
    exit(2);
}

// Moves what is pending into the engine, a piece at a time. Returns false when the engine said no (Writable continues).
fn flush(w: tcprouter::Worker&, s: Session&, conn: tcprouter::Conn) -> bool {
    while s.sent < s.pend.len {
        let rest = s.pend.len - s.sent;
        let n = if rest < PIECE { rest } else { PIECE };
        if !w.send(conn, s.pend[s.sent..s.sent + n]) { return false; }
        s.sent += n;
    }
    s.pend.clear();
    s.sent = 0;
    true
}

// Puts what the TLS engine produced behind the pending bytes. false if it does not fit (the session is then closed).
fn queue(s: Session&, out: const u8[:]) -> bool {
    if s.pend.len + out.len > s.pend.cap { s.closing = true; return false; }
    s.pend.append(out);
    true
}

// Encrypts the next window of the body once the previous records are out, then flushes again, until the body is done.
fn pump(w: tcprouter::Worker&, s: Session&, conn: tcprouter::Conn) {
    loop {
        if !flush(w, s, conn) { w.pause_reading(conn, true); return; }
        w.pause_reading(conn, false);
        if s.left > 0 {
            var window: u8[WINDOW] = [0; WINDOW];
            var out: u8[>..] = [];
            let n = if s.left < WINDOW { s.left } else { WINDOW };
            for k in n { window[k] = ((s.at + k) % PERIOD) as! u8; }
            tls::send(s.conn, window[..n], out);
            s.left -= n;
            s.at += n;
            queue(s, out);
        } else {
            break;
        }
    }
    if s.closing { w.close(conn); }
}

fn respond(s: Session&, out: u8[>..]&, status: const u8[:], length: i64, body: const u8[:]) {
    var head: u8[>..] = [];
    format(head, "HTTP/1.1 ", status, "\r\nContent-Length: ", length, "\r\nContent-Type: application/octet-stream\r\n\r\n");
    head.append(body);
    tls::send(s.conn, head, out);
}

// Answers the complete requests in `app`, one at a time.
fn answer(s: Session&, out: u8[>..]&, sessions_live: i64) {
    loop {
        if s.left > 0 { return; }                                   // the previous body is still going out
        let end = find(s.req, "\r\n\r\n");
        if end < 0 { return; }
        let line_end = find(s.req, "\r\n");
        let line = s.req[..line_end];
        let sp = find(line[4..], " ");
        var target = line[4..4 + sp];
        if line.len < 14 || line[..4] != "GET " { respond(s, out, "405 Method Not Allowed", 0, ""); s.closing = true; return; }
        if target == "/" {
            respond(s, out, "200 OK", 6, "hello\n");
        } else if target == "/sni" {
            respond(s, out, "200 OK", s.conn.sni.len, s.conn.sni[..]);
        } else if target == "/live" {
            let text = str(sessions_live);
            respond(s, out, "200 OK", text.len, text);
        } else {
            let n, good = parse_int(target[1..]);
            if !good || n < 0 { respond(s, out, "404 Not Found", 0, ""); } else { respond(s, out, "200 OK", n, ""); s.left = n; s.at = 0; }
        }
        let rest = s.req.len - end - 4;
        for k in rest { s.req[k] = s.req[end + 4 + k]; }
        s.req.pop_n(end + 4);
    }
}

fn live_count(sessions: slot_pool<Session>&) -> i64 {
    var n = 0;
    for i in sessions.items.len { if sessions.items[i].live { n++; } }
    n
}

fn on_data(w: tcprouter::Worker&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32, bytes: const u8[:]) {
    if user >= sessions.items.len { return; }
    let s .= sessions.items[user];
    if !s.live || s.closing { return; }
    // gslib's code may shrink one of its globals, and the compiler cannot show that the event's bytes (a slice of an engine
    // buffer, seen through a generic block) are not in it: so the bytes are copied into a local first (finding F-2 in docs/tls-support.md).
    var input: u8[>..] = [];
    input.append(bytes);
    var app: u8[>..] = [];
    var out: u8[>..] = [];
    let alert = tls::server_feed(s.conn, CONFIG, input, out, app);
    if alert != 0 { s.closing = true; log(str("E tls-failed alert=", s.conn.alert)); }   // send the alert, then close
    if app.len > 0 && !s.closing {
        if s.req.len + app.len > s.req.cap { s.closing = true; } else { s.req.append(app); }
    }
    if s.req.len > 0 && !s.closing { answer(s, out, live_count(sessions)); }
    queue(s, out);
    pump(w, s, conn);
}

fn on_writable(w: tcprouter::Worker&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32) {
    if user >= sessions.items.len { return; }
    let s .= sessions.items[user];
    if s.live { pump(w, s, conn); }
}

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var sessions = slot_pool<Session> {};
    var w = tcprouter::Worker { .. };
    if !w.start(cfg, index) { print(w.error); return; }
    w.serve() { w, ev =>
        match ev {
            Opened o => {
                let i = sessions.alloc_index(Session { live: true, conn: tls::server(CONFIG), pend: [], sent: 0, req: [], left: 0, at: 0, closing: false });
                w.set_user(o.conn, i as u32);
                log("E opened");
            },
            Data d => { on_data(w, sessions, d.conn, d.user, d.bytes); },
            Writable x => { on_writable(w, sessions, x.conn, x.user); },
            Closed c => {
                log(str("E closed why=", c.why));
                if c.user < sessions.items.len {
                    sessions.items[c.user].live = false;
                    sessions.free(c.user);
                }
            },
            _ => {},
        }
    };
}

// --- the control thread: `deadline TAG BOOTTIME_MS` on stdin ------------------------------------------------------

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
    var listen: u8[>..] = [];
    listen.append("127.0.0.1:8443");
    var tag = 1;
    var chain: u8[>..] = [];
    var key: u8[>..] = [];
    var control_on = false;
    var i = 1;
    while i < a.len {
        if a[i] == "--log-events" { LOG_EVENTS = true; i++; continue; }
        if a[i] == "--control" { control_on = true; i++; continue; }
        if i + 1 >= a.len { die(str(a[i], " needs a value")); }
        if a[i] == "--listen" { listen.clear(); listen.append(a[i + 1]); }
        else if a[i] == "--tag" { let n, good = parse_int(a[i + 1]); if !good { die("bad --tag"); } tag = n; }
        else if a[i] == "--chain" { if !read_file(a[i + 1], chain) { die("cannot read the chain"); } }
        else if a[i] == "--key" { if !read_file(a[i + 1], key) { die("cannot read the key"); } }
        else { die(str("unknown flag ", a[i])); }
        i += 2;
    }
    let sc, ok = tls::server_config(chain, key);
    if !ok { die("the certificate chain or the key was not accepted"); }
    CONFIG = copy(sc);
    tls::add_alpn(CONFIG.alpn, "http/1.1");

    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(listen) });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Handle { tag: tag as u16 }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    let ids = tcprouter::spawn(cfg, 1, worker);
    if control_on {
        thread_spawn(control);
        for id in ids { thread_wait(id); }
    } else {
        tcprouter::wait_for_signal_then_drain(5000);
    }
}
