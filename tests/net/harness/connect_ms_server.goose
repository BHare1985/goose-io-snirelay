// Gate 4 (a connect timeout of the policy's own, Pick.To.connect_ms): a forwarding server whose backend choices come from a test-double
// policy, each pick carrying a connect timeout for its slot.
//
//     connect_ms_server --listen 127.0.0.1:9000 --to A [--to B ...] [--connect-ms SLOT=MS ...] [--connect-timeout-ms N]
//
// Like gate 1's policy_server (the double picks the LAST address not yet tried, tag 40 + slot, generation 7), and each Pick.To carries
// connect_ms = the value given for its slot with --connect-ms (0 when none was given: "use Limits.connect_timeout_ms").
// --connect-timeout-ms sets that default (Limits.connect_timeout_ms). Hook lines on stdout, as in gate 1, with the timeout added:
//     READY
//     PICK route=R tried=MASK -> slot=S tag=T gen=G connect_ms=M     (or "-> none")
//     CONNECT_FAILED slot=S tag=T tried=MASK
//     CONNECTED tag=T
//     CLOSED tag=T
import goose_io from "github.com/BHare1985/goose-io@v0.4";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";
import tcprouter from "../../..";
var cfg: tcprouter::Config = tcprouter::Config { .. };     // the path inside tcprouter (tests/net/harness/)
import std;
import os;

var LISTEN: u8[>..] = [];
var TARGETS: u8[][>..] = [];
var CONNECT_MS: i64[8] = [0; 8];
var DEFAULT_MS: i64 = 0;

struct spy::Policy { addrs: tcprouter::Addr[..8], count: i64 = 0, connect_ms: i64[8] }

fn spy::pick(p: spy::Policy&, route: u16, conn: tcprouter::Conn, tried: u32, now_ms: i64) -> tcprouter::Pick {
    var s = p.count;
    while s > 0 {
        s--;
        if (tried >> (s as u32)) & 1 == 0 {
            print("PICK route=", route, " tried=", tried, " -> slot=", s, " tag=", 40 + s, " gen=7 connect_ms=", p.connect_ms[s]);
            return tcprouter::Pick.To { addr: p.addrs[s], tag: (40 + s) as u16, gen: 7, slot: s as u8, connect_ms: p.connect_ms[s] };
        }
    }
    print("PICK route=", route, " tried=", tried, " -> none");
    return tcprouter::Pick.None;
}

fn spy::connect_failed(p: spy::Policy&, conn: tcprouter::Conn, slot: u8, tag: u16, tried: u32, now_ms: i64) -> tcprouter::Retry {
    print("CONNECT_FAILED slot=", slot, " tag=", tag, " tried=", tried);
    tcprouter::Retry.Next
}

fn spy::connected(p: spy::Policy&, conn: tcprouter::Conn, tag: u16) { print("CONNECTED tag=", tag); }

fn spy::closed(p: spy::Policy&, conn: tcprouter::Conn, tag: u16, why: tcprouter::CloseReason) { print("CLOSED tag=", tag); }

fn spy::on_message(p: spy::Policy&, body: const u8[:], now_ms: i64) -> tcprouter::Effect { tcprouter::Effect.None }

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
    if !w.start(io, cfg, index) { epoll_ext::report_failed_start(); write_stderr(str("connect_ms_server: ", w.error, "\n")); return; }
    io.attach(index);
    var p = spy::Policy { .. };
    p.addrs = cfg.targets[0].addrs;
    p.count = cfg.targets[0].addrs.len;
    p.connect_ms = CONNECT_MS;
    print("READY");
    io.serve() { io, ev => w.on_event(io, ev, p); };
}

fn main() {
    let a = args();
    var i = 1;
    while i + 1 < a.len {
        if a[i] == "--listen" { LISTEN.append(a[i + 1]); }
        else if a[i] == "--to" { TARGETS.push(a[i + 1]); }
        else if a[i] == "--connect-timeout-ms" { let n, ok = parse_int(a[i + 1]); if ok { DEFAULT_MS = n; } }
        else if a[i] == "--connect-ms" {
            let eq = find(a[i + 1], "=");
            let slot, ok1 = parse_int(a[i + 1][..eq]);
            let ms, ok2 = parse_int(a[i + 1][eq + 1..]);
            if eq > 0 && ok1 && ok2 && slot >= 0 && slot < 8 { CONNECT_MS[slot] = ms; }
        }
        i += 2;
    }
    var cfg = tcprouter::Config { .. };
    if DEFAULT_MS > 0 { cfg.limits.connect_timeout_ms = DEFAULT_MS; }
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(LISTEN) });
    var t = tcprouter::Target { addrs: [] };
    for target in TARGETS { t.addrs.push(tcprouter::addr(target)); }
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::add_target(cfg, t) }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    epoll_ext::spawn(1, cfg, worker);
    tcprouter::workers_ready(1);
    epoll_ext::wait_for_signal_then_drain(1000);
}
