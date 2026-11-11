// Gate for wait_for_signal / drain (RT-8d, RT-8e): a forwarding server whose main thread is the program's signal handling.
//
//     signal_server --listen 127.0.0.1:9000 --to 127.0.0.1:9100 [--deadline MS]
//
// Prints READY, then after a signal `SIGNAL n`, after the drain `DRAINED k` (k = open sessions closed at the deadline, 0 = every session ended).
import tcprouter from "../../..";
import std;
import os;

var LISTEN: u8[>..] = [];
var TARGET: u8[>..] = [];
var DEADLINE: i64 = 500;

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var w = tcprouter::Worker { .. };
    if !w.start(cfg, index) { write_stderr(str("signal_server: ", w.error, "\n")); return; }
    w.serve() { w, ev => };
}

fn main() {
    let a = args();
    var i = 1;
    while i + 1 < a.len {
        if a[i] == "--listen" { LISTEN.append(a[i + 1]); }
        else if a[i] == "--to" { TARGET.append(a[i + 1]); }
        else if a[i] == "--deadline" { let n, ok = parse_int(a[i + 1]); if ok { DEADLINE = n; } }
        i += 2;
    }
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(LISTEN) });
    var t = tcprouter::Target { addrs: [] };
    t.addrs.push(tcprouter::addr(TARGET));
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::add_target(cfg, t) }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    tcprouter::spawn(cfg, 2, worker);
    print("READY");
    let sig = tcprouter::wait_for_signal();
    print("SIGNAL ", sig);
    let closed = tcprouter::drain(DEADLINE);
    print("DRAINED ", closed);
}
