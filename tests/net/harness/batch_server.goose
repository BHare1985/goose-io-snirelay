// Gate for the batching window (RT-16): a forwarder whose Limits.batch_min_events / batch_max_wait_us come from the command line.
//
//     batch_server --listen A --to B [--tagged TAG] [--batch-min N] [--batch-wait-us U] [--workers N]
//
// stdin: `stats` prints `BATCH waits=W wait_us=U accepted=A open=O`; `deadline TAG MS` posts Message.Deadline; `ping` gathers and prints `PONG` (the test times it).
// stdout: READY.
import tcprouter from "../../..";
import std;
import os;

var LISTEN: u8[>..] = [];
var TARGET: u8[>..] = [];
var TAG: i64 = 0;
var BATCH_MIN: i64 = 0;
var BATCH_WAIT: i64 = 0;
var WORKERS: i64 = 1;

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var w = tcprouter::Worker { .. };
    if !w.start(cfg, index) { write_stderr(str("batch_server: ", w.error, "\n")); return; }
    print("READY");
    w.serve() { w, ev => };
}

extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

fn run_command(line: const u8[:]) {
    let parts = words(line);
    if parts.len == 1 && parts[0] == "stats" {
        let s = tcprouter::gather_stats(WORKERS);
        print("BATCH waits=", s.batch_waits, " wait_us=", s.batch_wait_us, " accepted=", s.accepted, " open=", s.open);
    } else if parts.len == 1 && parts[0] == "ping" {
        let s = tcprouter::gather_stats(WORKERS);
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
    while i + 1 < a.len {
        if a[i] == "--listen" { LISTEN.append(a[i + 1]); }
        else if a[i] == "--to" { TARGET.append(a[i + 1]); }
        else if a[i] == "--tagged" { let n, ok = parse_int(a[i + 1]); if ok { TAG = n; } }
        else if a[i] == "--batch-min" { let n, ok = parse_int(a[i + 1]); if ok { BATCH_MIN = n; } }
        else if a[i] == "--batch-wait-us" { let n, ok = parse_int(a[i + 1]); if ok { BATCH_WAIT = n; } }
        else if a[i] == "--workers" { let n, ok = parse_int(a[i + 1]); if ok { WORKERS = n; } }
        i += 2;
    }
    var cfg = tcprouter::Config { .. };
    cfg.limits.batch_min_events = BATCH_MIN;
    cfg.limits.batch_max_wait_us = BATCH_WAIT;
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(LISTEN) });
    var t = tcprouter::Target { addrs: [] };
    t.addrs.push(tcprouter::addr(TARGET));
    if TAG > 0 { t.tag = TAG as u16; t.gen = 1; }
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::add_target(cfg, t) }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    let ids = tcprouter::spawn(cfg, WORKERS, worker);
    thread_spawn(control);
    for id in ids { thread_wait(id); }
}
