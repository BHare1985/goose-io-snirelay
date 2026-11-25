// The system under test for the handler-mode network tests: a server written the way a user would write one on
// tcprouter's handler mode. WHAT it does with a connection is chosen by the tag of the route that accepted it, so one
// binary serves every handler test.
//
//     handler_server --handle 127.0.0.1:9000=1 [--handle 127.0.0.1:9001=2 …] [--forward-to 127.0.0.1:9100]
//                    [--log-events] [--workers N] [--buffers N] [--buffer-size N] [--stat-ms N]
//
//   tag 1  echo: every byte comes back (flow-controlled: pause_reading while a send is refused)
//   tag 2  on open, send 1 MB of a known pattern, then close (close must deliver the queued bytes first)
//   tag 3  on open, send 64 MB of the pattern as fast as send() accepts it, honouring false and Writable
//   tag 4  on open, forward the connection to --forward-to
//   tag 5  echo; on the first Data try to forward (must be refused: a byte has been consumed)
//   tag 6  on open, reset the connection
//   tag 7, 8  echo, and every Tick (at most 100 ms) also send 16 bytes unasked; with --stall-ms N the Data handler waits N ms
//             before echoing (a worker held up inside the user's code). Used by handler_deadline_test (RT-6a-H) with
//             --control, which reads `deadline TAG BOOTTIME_MS`, `close-tagged TAG GEN` and `drain MS` from stdin.
//
// Output on stdout: READY n, STAT … (as forward_server), and with --log-events one line per event:
//   E open S:G tag=T        E data S:G n=N        E writable S:G        E closed S:G total=N fnv=H why=W
//   E tick MS               E forward S:G result=true|false           E sent-all S:G falses=N writables=M
// (S:G is the connection's slot and generation; FNV-1a 64 is taken over the bytes received.)
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";
import tcprouter from "../../..";
import slot_pool;
import std;
import os;

let TAG_ECHO: u16 = 1;
let TAG_SEND_1MB: u16 = 2;
let TAG_FLOOD: u16 = 3;
let TAG_FORWARD_ON_OPEN: u16 = 4;
let TAG_FORWARD_AFTER_DATA: u16 = 5;
let TAG_RESET: u16 = 6;
let TAG_PUSH_A: u16 = 7;
let TAG_PUSH_B: u16 = 8;

let MB: i64 = 1048576;
let FNV_OFFSET: u64 = 14695981039346656037;
let FNV_PRIME: u64 = 1099511628211;

// Set in main before the workers start; each worker gets a copy.
var LOG_EVENTS: bool = false;
var STAT_MS: i64 = 1000;
var FORWARD_TO: u8[..48] = [];
var STALL_MS: i64 = 0;
struct Session {
    tag: u16,
    sent: i64,                  // bytes of the pattern sent so far (tags 2 and 3)
    target: i64,                // bytes of the pattern to send
    received: i64,
    fnv: u64,
    falses: i64,                // sends that returned false
    writables: i64,
    pending: u8[..16384],       // an echo chunk whose send was refused
    forwarded: bool,
    conn: tcprouter::Conn,      // tags 7 and 8: whom to push to on a Tick
    open: bool,
}

fn die(message: const u8[:]) {
    write_stderr(str("handler_server: ", message, "\n"));
    exit(2);
}

fn number(text: const u8[:], what: const u8[:]) -> i64 {
    let n, ok = parse_int(text);
    if !ok || n < 1 { die(str(what, " needs a positive number, got '", text, "'")); }
    return n;
}

fn pattern_byte(i: i64) -> u8 { return ((i * 31 + 7) % 251) as! u8; }

fn log(line: const u8[:]) { if LOG_EVENTS { print(line); } }

fn conn_name(c: tcprouter::Conn) -> u8[>..] { return str(c.slot, ":", c.gen); }

// --- sending the pattern, honouring false and Writable -------------------------------------------------

fn push_pattern(w: tcprouter::Worker&, io: epoll_ext::Loop&, c: tcprouter::Conn, s: Session&) {
    var chunk: u8[16384] = [0; 16384];
    while s.sent < s.target {
        let left = s.target - s.sent;
        let n = if left < chunk.len { left } else { chunk.len };
        for k in n { chunk[k] = pattern_byte(s.sent + k); }
        if !w.send(io, c, chunk[..n]) {
            s.falses++;
            return;                                 // wait for Writable
        }
        s.sent += n;
    }
    if s.sent == s.target {
        s.target = -1;                              // done once
        if LOG_EVENTS { print("E sent-all ", conn_name(c), " falses=", s.falses, " writables=", s.writables); }
        w.close(io, c);
    }
}

// --- echo with flow control -------------------------------------------------------------------------------

fn echo(w: tcprouter::Worker&, io: epoll_ext::Loop&, c: tcprouter::Conn, s: Session&, bytes: const u8[:]) {
    if !w.send(io, c, bytes) {
        s.pending.clear();
        s.pending.append(bytes);                    // keep it, stop reading until it fits
        w.pause_reading(io, c, true);
    }
}

// --- the events ---------------------------------------------------------------------------------------------

fn on_opened(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, tag: u16) {
    let index = sessions.alloc_index(Session { tag: tag, sent: 0, target: 0, received: 0, fnv: FNV_OFFSET, falses: 0,
                                               writables: 0, pending: [], forwarded: false, conn: conn, open: true });
    w.set_user(io, conn, index as u32);
    log(str("E open ", conn_name(conn), " tag=", tag));
    let s .= sessions.items[index];
    if tag == TAG_SEND_1MB { s.target = MB; push_pattern(w, io, conn, s); }
    else if tag == TAG_FLOOD { s.target = 64 * MB; push_pattern(w, io, conn, s); }
    else if tag == TAG_RESET { w.reset(io, conn); }
    else if tag == TAG_FORWARD_ON_OPEN {
        var t = tcprouter::Target { addrs: [] };
        t.addrs.push(tcprouter::Addr { text: FORWARD_TO });
        let ok = w.forward(io, conn, t);
        log(str("E forward ", conn_name(conn), " result=", ok));
        if ok { sessions.free(index); }             // ownership ended: no Closed event will come, so free the state now
        else { s.forwarded = true; }
    }
}

fn on_data(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32, bytes: const u8[:]) {
    if user >= sessions.items.len { return; }       // an id from outside: check it
    let s .= sessions.items[user];
    for b in bytes { s.fnv = (s.fnv ^ b) * FNV_PRIME; }
    s.received += bytes.len;
    log(str("E data ", conn_name(conn), " n=", bytes.len));
    if s.tag == TAG_FORWARD_AFTER_DATA && !s.forwarded {
        var t = tcprouter::Target { addrs: [] };
        t.addrs.push(tcprouter::Addr { text: FORWARD_TO });
        let ok = w.forward(io, conn, t);
        s.forwarded = true;                         // ask once
        log(str("E forward ", conn_name(conn), " result=", ok));
    }
    if s.tag == TAG_PUSH_A || s.tag == TAG_PUSH_B {
        if STALL_MS > 0 { sleep_ms(STALL_MS); }     // the worker is held up inside the user's code (RT-6a-H)
        echo(w, io, conn, s, bytes);
    }
    if s.tag == TAG_ECHO || s.tag == TAG_FORWARD_AFTER_DATA { echo(w, io, conn, s, bytes); }
}

fn on_writable(w: tcprouter::Worker&, io: epoll_ext::Loop&, sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32) {
    if user >= sessions.items.len { return; }
    let s .= sessions.items[user];
    s.writables++;
    log(str("E writable ", conn_name(conn)));
    if s.tag == TAG_SEND_1MB || s.tag == TAG_FLOOD { if s.target >= 0 { push_pattern(w, io, conn, s); } }
    else if s.pending.len > 0 {
        if w.send(io, conn, s.pending) {
            s.pending.clear();
            w.pause_reading(io, conn, false);
        }
    }
}

fn on_closed(sessions: slot_pool<Session>&, conn: tcprouter::Conn, user: u32, why: tcprouter::CloseReason) {
    if user >= sessions.items.len { return; }
    let s .= sessions.items[user];
    s.open = false;
    if LOG_EVENTS { print("E closed ", conn_name(conn), " total=", s.received, " fnv=", s.fnv, " why=", why); }
    sessions.free(user);
}

fn on_tick(now_ms: i64, last: i64&, every_ms: i64, w: tcprouter::Worker&, io: epoll_ext::Loop&, index: i64, sessions: slot_pool<Session>&) {
    if LOG_EVENTS { print("E tick ", now_ms); }
    for &s in sessions.items {                      // tags 7 and 8: unasked server-to-client traffic
        if s.open && (s.tag == TAG_PUSH_A || s.tag == TAG_PUSH_B) { w.send(io, s.conn, "SSSSSSSSSSSSSSSS"); }
    }
    if now_ms - last >= every_ms {
        last = now_ms;
        let s = w.snapshot(io);
        let l = io.stats();
        print("STAT ", index, " accepted=", s.accepted, " open=", s.open, " bytes_in=", s.bytes_in, " bytes_out=", s.bytes_out,
              " buffers_in_use=", l.buffers_in_use, " buffer_waits=", l.buffer_waits);
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
    if !w.start(io, cfg, index) {
        write_stderr(str("handler_server: worker ", index, ": ", w.error, "\n"));
        epoll_ext::report_failed_start();
        return;
    }
    io.attach(index);
    print("READY ", index);
    var last: i64 = 0;
    let every_ms = STAT_MS;
    io.serve() { io, ev => w.on_event(io, ev) { w, io, e =>
        match e {
            Opened o => { on_opened(w, io, sessions, o.conn, o.tag); },
            Data d => { on_data(w, io, sessions, d.conn, d.user, d.bytes); },
            Writable x => { on_writable(w, io, sessions, x.conn, x.user); },
            PeerEof p => { },
            PassEnd p => { },
            Closed c => { on_closed(sessions, c.conn, c.user, c.why); },
            Tick t => { on_tick(t.now_ms, last, every_ms, w, io, index, sessions); },
        }
    }; };
}

struct Started { worker: i64, ok: bool }

// --- the control thread (as forward_server's): commands on stdin become messages to the workers --------------------

extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

fn run_command(io: epoll_ext::Loop&, line: const u8[:]) {
    let space = find(line, " ");
    let verb = if space < 0 { line[..] } else { line[..space] };
    let rest = if space < 0 { line[line.len..] } else { line[space + 1..] };
    let parts = words(rest);
    if verb == "drain" {
        let ms, ok = parse_int(rest);
        if ok { tcprouter::post(io, tcprouter::Message.Drain { deadline_ms: ms }); }
    } else if verb == "deadline" && parts.len == 2 {
        let tag, ok1 = parse_int(parts[0]);
        let until, ok2 = parse_int(parts[1]);
        if ok1 && ok2 { tcprouter::post(io, tcprouter::Message.Deadline { tag: tag as u16, until_ms: until }); }
    } else if verb == "close-tagged" && parts.len == 2 {
        let tag, ok1 = parse_int(parts[0]);
        let gen, ok2 = parse_int(parts[1]);
        if ok1 && ok2 { tcprouter::post(io, tcprouter::Message.CloseTagged { tag: tag as u16, gen: gen as u32 }); }
    }
}

thread_fn control() {
    var io = epoll_ext::Loop { .. };                    // only names the wake operation; it never runs
    var pending: u8[>..] = [];
    var chunk: u8[256] = [0; 256];
    loop {
        let n = read(0, chunk[0], 256);                 // raw read(2): a thread blocked in stdio would make exit() hang
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

// --- main -----------------------------------------------------------------------------------------------------

root struct Options {
    handles: u8[][>..] = [],
    workers: i64 = 1,
    buffers: i64 = 4096,
    buffer_size: i64 = 32768,
    control: bool = false,
}

fn main() {
    var o = Options { .. };
    let a = args();
    var i = 1;
    while i < a.len {
        let flag = a[i];
        if flag == "--log-events" { LOG_EVENTS = true; i++; continue; }
        if flag == "--control" { o.control = true; i++; continue; }
        if i + 1 >= a.len { die(str(flag, " needs a value")); }
        let value = a[i + 1];
        if flag == "--handle" { o.handles.push(value); }
        else if flag == "--forward-to" { FORWARD_TO.append(value); }
        else if flag == "--workers" { o.workers = number(value, flag); }
        else if flag == "--buffers" { o.buffers = number(value, flag); }
        else if flag == "--buffer-size" { o.buffer_size = number(value, flag); }
        else if flag == "--stat-ms" { STAT_MS = number(value, flag); }
        else if flag == "--stall-ms" { STALL_MS = number(value, flag); }
        else { die(str("unknown flag ", flag)); }
        i += 2;
    }
    if o.handles.len == 0 { die("need at least one --handle ADDRESS=TAG"); }

    var cfg = tcprouter::Config { .. };
    cfg.limits.buffers_per_worker = o.buffers;
    cfg.limits.buffer_size = o.buffer_size;
    var id: u16 = 1;
    for h in o.handles {
        let eq = find(h, "=");
        if eq < 0 { die(str("--handle needs ADDRESS=TAG, got '", h, "'")); }
        let tag, ok = parse_int(h[eq + 1..]);
        if !ok { die(str("bad tag in '", h, "'")); }
        cfg.listeners.push(tcprouter::Listener { id: id, addr: tcprouter::addr(h[..eq]) });
        cfg.routes.push(tcprouter::any_route(id, tcprouter::Action.Handle { tag: tag as u16 }));
        id++;
    }
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }

    let ids = epoll_ext::spawn(o.workers, cfg, worker);
    tcprouter::workers_ready(o.workers);
    if o.control {
        thread_spawn(control);
        for id in ids { thread_wait(id); }              // returns when every worker has drained
    } else {
        epoll_ext::wait_for_signal_then_drain(5000);
    }
}
