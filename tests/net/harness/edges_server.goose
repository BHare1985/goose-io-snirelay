// Gate for the handler edge cases found in the review of 2026-11-14 (RT-19): pool pressure, close order, flush progress, forward guards, dial vs idle.
//
//     edges_server --listen A [--buffers N] [--buffer-size B] [--idle-ms MS]      one worker, handler connections (tag 7)
//
// A client names its connection with the line `NAME x` (x = a..h). Every later line of the form `DO ...` is queued and run at the NEXT Tick, so that no
// read buffer is held while it runs (the pool can then be filled exactly):
//   DO HOLD x k       send full buffers to x until k of the pool's buffers hold unsent bytes (x's client must not read)
//   DO SEND x         send "pong" to x; prints `SEND x true|false`; after a false, retries on Writable and prints `RETRY x true|false`
//   DO SENDBIG x      send 5 buffers + 1 byte to x (it can never fit the 4-buffer queue): prints `SENDBIG x true|false`
//   DO SHUTFWD x      shutdown_write(x), then forward(x, 127.0.0.1:1): prints `FWD_AFTER_SHUT x true|false`
//   DO FWDHOLE        forward(it, [127.0.0.1:1 (refused), a cleared slot]): the first address fails and there is nothing left to retry; prints `FWDHOLE true|false`
//   DO STATS          prints `STATS retries=N`
//   DO FWDONEOF x     when x's peer half-closes (PeerEof), try forward(x, 127.0.0.1:1): prints `FWD_ON_EOF x true|false`
//   DO DIAL ADDR MS   w.dial(ADDR, 7, MS) as connection `#`: prints `DIAL_OPENED` or `CLOSED # why`
// Prints: READY, `DATA x n` (a read that is not a command), `WRITABLE x`, `CLOSED x why`, and the lines above.
import tcprouter from "../../..";
import std;
import os;

let CHARS = "abcdefgh#";
let DIAL_USER: u32 = 8;                       // user id of a dialled connection (letters are 0..7, unnamed accepted connections are 100)
let UNNAMED: u32 = 100;

var LISTEN: u8[>..] = [];
var BUFFERS: i64 = 4096;
var BUFFER_SIZE: i64 = 32768;
var IDLE_MS: i64 = 300000;

struct State {
    conns: tcprouter::Conn[8],
    retry: bool[8],                           // a SEND was refused: try again on Writable
    script: u8[..2048],                       // DO lines waiting for the next Tick
    last: tcprouter::Conn,                    // the most recently accepted connection (named or not: the forward commands use it before it is named)
    eof_conn: tcprouter::Conn,                // FWDONEOF: forward this one when its peer's EOF arrives
    eof_armed: bool,
}

fn name_of(user: u32) -> const u8[:] {
    let k = user as i64;
    if k < 9 { CHARS[k..k + 1] } else { "?" }
}

fn index_of(text: const u8[:]) -> i64 {
    if text.len != 1 { return -1; }
    let k = (text[0] as i64) - 97;
    if k < 0 || k >= 8 { return -1; }
    k
}

fn forward_target() -> tcprouter::Target {
    var t = tcprouter::Target { addrs: [] };
    t.addrs.push(tcprouter::addr("127.0.0.1:1"));
    t
}

// Sends full buffers until `k` more of the pool's buffers hold unsent bytes (the socket is full, so the queue keeps them).
fn hold(w: tcprouter::Worker&, conn: tcprouter::Conn, k: i64) {
    var chunk: u8[65536] = [120; 65536];
    let size = BUFFER_SIZE;
    let start = w.stats().buffers_in_use;
    var sent = 0;
    for step in 200000 {
        if w.stats().buffers_in_use - start >= k { break; }
        if !w.send(conn, chunk[..size]) { break; }
        sent++;
    }
    print("HELD in_use=", w.stats().buffers_in_use, " sent=", sent);
}

fn run_command(w: tcprouter::Worker&, st: State&, line: const u8[:]) {
    let parts = words(line);
    if parts.len < 2 { return; }
    if parts[0] != "DO" { return; }
    let verb = parts[1];
    if verb == "STATS" { print("STATS retries=", w.stats().retries); return; }
    if verb == "SHUTFWD" {
        w.shutdown_write(st.last);
        print("FWD_AFTER_SHUT ", w.forward(st.last, forward_target()));
        return;
    }
    if verb == "FWDHOLE" {
        var t = forward_target();
        t.addrs.push(tcprouter::Addr { text: [] });
        print("FWDHOLE ", w.forward(st.last, t));
        return;
    }
    if verb == "FWDONEOF" { st.eof_conn = st.last; st.eof_armed = true; return; }
    if verb == "DIAL" && parts.len == 4 {
        let ms, ok = parse_int(parts[3]);
        if !ok { return; }
        let conn = w.dial(parts[2], 7, ms);
        w.set_user(conn, DIAL_USER);
        return;
    }
    if parts.len < 3 { return; }
    let k = index_of(parts[2]);
    if k < 0 { return; }
    let conn = st.conns[k];
    if verb == "HOLD" && parts.len == 4 {
        let n, ok = parse_int(parts[3]);
        if ok { hold(w, conn, n); }
    } else if verb == "SEND" {
        let ok = w.send(conn, "pong");
        print("SEND ", name_of(k as u32), " ", ok);
        if !ok { st.retry[k] = true; }
    } else if verb == "SENDBIG" {
        var chunk: u8[65536] = [120; 65536];
        let ok = w.send(conn, chunk[..BUFFER_SIZE * 5 + 1]);
        print("SENDBIG ", name_of(k as u32), " ", ok);
    }
}

fn run_script(w: tcprouter::Worker&, st: State&) {
    var text: u8[>..] = [];
    text.append(st.script[..]);
    st.script.clear();
    var pos = 0;
    while pos < text.len {
        let nl = find(text[pos..], "\n");
        if nl < 0 { break; }
        run_command(w, st, text[pos..pos + nl]);
        pos += nl + 1;
    }
}

fn on_data(w: tcprouter::Worker&, st: State&, conn: tcprouter::Conn, user: u32, bytes: const u8[:]) {
    var text: u8[>..] = [];
    text.append(bytes);
    var pos = 0;
    var commands = 0;
    while pos < text.len {
        var nl = find(text[pos..], "\n");
        if nl < 0 { nl = text.len - pos; }
        let line = text[pos..pos + nl];
        pos += nl + 1;
        let parts = words(line);
        if parts.len == 2 && parts[0] == "NAME" {
            let k = index_of(parts[1]);
            if k >= 0 { st.conns[k] = conn; w.set_user(conn, k as u32); }
            commands++;
        } else if parts.len >= 2 && parts[0] == "DO" {
            if st.script.len + line.len + 1 <= st.script.cap { st.script.append(line); st.script.append("\n"); }
            commands++;
        }
    }
    if commands == 0 { print("DATA ", name_of(user), " ", bytes.len); }
}

fn on_peer_eof(w: tcprouter::Worker&, st: State&, conn: tcprouter::Conn, user: u32) {
    if st.eof_armed && conn.slot == st.eof_conn.slot && conn.gen == st.eof_conn.gen {
        st.eof_armed = false;
        print("FWD_ON_EOF ", w.forward(conn, forward_target()));
        return;
    }
    w.close(conn);
}

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var w = tcprouter::Worker { .. };
    if !w.start(cfg, index) { write_stderr(str("edges_server: ", w.error, "\n")); return; }
    var st = State { conns: [tcprouter::Conn { slot: 0, gen: 0 }; 8], retry: [false; 8], script: [], last: tcprouter::Conn { slot: 0, gen: 0 }, eof_conn: tcprouter::Conn { slot: 0, gen: 0 }, eof_armed: false };
    print("READY");
    w.serve() { w, ev =>
        match ev {
            Opened o => {
                if w.user(o.conn) == DIAL_USER { print("DIAL_OPENED"); }
                else { st.last = o.conn; w.set_user(o.conn, UNNAMED); w.set_keep_open_on_eof(o.conn, true); }
            },
            Data d => { on_data(w, st, d.conn, d.user, d.bytes); },
            Writable x => {
                print("WRITABLE ", name_of(x.user));
                if x.user < 8 && st.retry[x.user as i64] {
                    let ok = w.send(x.conn, "pong");
                    print("RETRY ", name_of(x.user), " ", ok);
                    st.retry[x.user as i64] = !ok;
                }
            },
            PeerEof e => { on_peer_eof(w, st, e.conn, e.user); },
            Closed c => { print("CLOSED ", name_of(c.user), " ", c.why); },
            Tick t => { if st.script.len > 0 { run_script(w, st); } },
            _ => {},
        }
    };
}

fn main() {
    let a = args();
    var i = 1;
    while i + 1 < a.len {
        if a[i] == "--listen" { LISTEN.append(a[i + 1]); }
        else if a[i] == "--buffers" { let n, ok = parse_int(a[i + 1]); if ok { BUFFERS = n; } }
        else if a[i] == "--buffer-size" { let n, ok = parse_int(a[i + 1]); if ok { BUFFER_SIZE = n; } }
        else if a[i] == "--idle-ms" { let n, ok = parse_int(a[i + 1]); if ok { IDLE_MS = n; } }
        i += 2;
    }
    var cfg = tcprouter::Config { .. };
    cfg.limits.buffers_per_worker = BUFFERS;
    cfg.limits.buffer_size = BUFFER_SIZE;
    cfg.limits.idle_timeout_ms = IDLE_MS;
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(LISTEN) });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Handle { tag: 7 }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    let ids = tcprouter::spawn(cfg, 1, worker);
    tcprouter::wait_for_signal_then_drain(2000);
}
