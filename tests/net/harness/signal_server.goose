// Gate for wait_for_signal / drain (RT-8d, RT-8e): a forwarding server whose main thread is the program's signal handling.
//
//     signal_server --listen 127.0.0.1:9000 --to 127.0.0.1:9100 [--deadline MS]
//
// Prints READY, then after a signal `SIGNAL n`, after the drain `DRAINED k` (k = open sessions closed at the deadline, 0 = every session ended).
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";
import tcprouter from "../../..";
import std;
import os;

var LISTEN: u8[>..] = [];
var TARGET: u8[>..] = [];
var DEADLINE: i64 = 500;

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
    if !w.start(io, cfg, index) { epoll_ext::report_failed_start(); write_stderr(str("signal_server: ", w.error, "\n")); return; }
    io.attach(index);
    io.serve() { io, ev => w.on_event(io, ev); };
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
    epoll_ext::spawn(2, cfg, worker);
    tcprouter::workers_ready(2);
    print("READY");
    let sig = epoll_ext::wait_for_signal();
    print("SIGNAL ", sig);
    let closed = epoll_ext::drain(DEADLINE);
    print("DRAINED ", closed);
}
