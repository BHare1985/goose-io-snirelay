// Gate for the end-of-pass signal (RT-17): a handler server that prints every event and the PassEnd.
//
//     passend_server --listen A [--pass-end] [--batch-min N --batch-wait-us U]
//
// Prints: READY, `EV opened`, `EV data N`, `EV closed`, `PASSEND`, `PASSEND_SEND true|false` (a send of 4 bytes "late" to the last connection during PassEnd).
// A Data event whose bytes start with "slow" sleeps 300 ms inside the handler (so a tag deadline can pass between the event and the PassEnd).
// stdin: `deadline TAG MS`, `ping` (a Stats gather: a posted message that delivers no handler event).
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";
import tcprouter from "../../..";
import std;
import os;

var LISTEN: u8[>..] = [];
var PASS_END: bool = false;
var BATCH_MIN: i64 = 0;
var BATCH_WAIT: i64 = 0;

thread_fn worker(cfg: tcprouter::Config, index: i64) {
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
    if !w.start(io, cfg, index) { epoll_ext::report_failed_start(); write_stderr(str("passend_server: ", w.error, "\n")); return; }
    io.attach(index);
    if PASS_END { w.want_pass_end(true); }
    var last = tcprouter::Conn { slot: 0, gen: 0 };
    print("READY");
    io.serve() { io, ev => w.on_event(io, ev) { w, io, ev =>
        match ev {
            Opened o => { last = o.conn; print("EV opened"); },
            Data d => {
                last = d.conn;
                print("EV data ", d.bytes.len);
                if d.bytes.len >= 4 && d.bytes[..4] == "slow" { sleep_ms(300); }
            },
            Writable x => { print("EV writable"); },
            PeerEof e => { print("EV eof"); },
            Closed c => { print("EV closed"); },
            PassEnd p => {
                print("PASSEND");
                let ok = w.send(io, last, "late");
                print("PASSEND_SEND ", ok);
            },
            _ => {},
        }
    }; };
}

extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

fn run_command(io: epoll_ext::Loop&, line: const u8[:]) {
    let parts = words(line);
    if parts.len == 1 && parts[0] == "ping" {
        let s = tcprouter::gather_stats(io, 1);
        print("PONG ", s.accepted);
    } else if parts.len == 3 && parts[0] == "deadline" {
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
        if a[i] == "--pass-end" { PASS_END = true; i++; continue; }
        if i + 1 >= a.len { break; }
        if a[i] == "--listen" { LISTEN.append(a[i + 1]); }
        else if a[i] == "--batch-min" { let n, ok = parse_int(a[i + 1]); if ok { BATCH_MIN = n; } }
        else if a[i] == "--batch-wait-us" { let n, ok = parse_int(a[i + 1]); if ok { BATCH_WAIT = n; } }
        i += 2;
    }
    var cfg = tcprouter::Config { .. };
    cfg.limits.batch_min_events = BATCH_MIN;
    cfg.limits.batch_max_wait_us = BATCH_WAIT;
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(LISTEN) });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Handle { tag: 7 }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    let ids = epoll_ext::spawn(1, cfg, worker);
    tcprouter::workers_ready(1);
    thread_spawn(control);
    for id in ids { thread_wait(id); }
}
