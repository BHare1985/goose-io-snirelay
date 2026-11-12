// Gate for the end-of-pass signal (RT-17): a handler server that prints every event and the PassEnd.
//
//     passend_server --listen A [--pass-end] [--batch-min N --batch-wait-us U]
//
// Prints: READY, `EV opened`, `EV data N`, `EV closed`, `PASSEND`, `PASSEND_SEND true|false` (a send of 4 bytes "late" to the last connection during PassEnd).
// A Data event whose bytes start with "slow" sleeps 300 ms inside the handler (so a tag deadline can pass between the event and the PassEnd).
// stdin: `deadline TAG MS`, `ping` (a Stats gather: a posted message that delivers no handler event).
import tcprouter from "../../..";
import std;
import os;

var LISTEN: u8[>..] = [];
var PASS_END: bool = false;
var BATCH_MIN: i64 = 0;
var BATCH_WAIT: i64 = 0;

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var w = tcprouter::Worker { .. };
    if !w.start(cfg, index) { write_stderr(str("passend_server: ", w.error, "\n")); return; }
    if PASS_END { w.want_pass_end(true); }
    var last = tcprouter::Conn { slot: 0, gen: 0 };
    print("READY");
    w.serve() { w, ev =>
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
                let ok = w.send(last, "late");
                print("PASSEND_SEND ", ok);
            },
            _ => {},
        }
    };
}

extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

fn run_command(line: const u8[:]) {
    let parts = words(line);
    if parts.len == 1 && parts[0] == "ping" {
        let s = tcprouter::gather_stats(1);
        print("PONG ", s.accepted);
    } else if parts.len == 3 && parts[0] == "deadline" {
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
    let ids = tcprouter::spawn(cfg, 1, worker);
    thread_spawn(control);
    for id in ids { thread_wait(id); }
}
