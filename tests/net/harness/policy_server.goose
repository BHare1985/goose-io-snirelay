// Gate 1 (the policy hook): a forwarding server whose backend choices come from a TEST-DOUBLE policy, not from
// Config.targets rotation, and which prints every call the engine makes on it.
//
//     policy_server --listen 127.0.0.1:9000 --to A [--to B ...] [--max-tries N]
//
// The double (namespace spy) picks the LAST address not yet tried, so the built-in rotation (which starts at the first)
// cannot pass by accident. Every hook prints one line on stdout:
//     READY
//     PICK route=R tried=MASK -> slot=S tag=T gen=G     (or "-> none")
//     CONNECT_FAILED slot=S tag=T tried=MASK
//     CONNECTED tag=T
//     CLOSED tag=T
// A server's tag is 40 + its slot and its generation is 7, so the lines show that the policy's own numbers reach the engine.
// --max-tries N: connect_failed answers GiveUp once N addresses were tried, though more remain (the policy's veto).
//
// The hook shape (what the engine calls on the policy value p, by UFCS in the type's namespace; design/07, O-1), with
// two additions to design/07 that this gate asks for, both for a policy that is pure and testable (see README.md):
//     fn pick(p: P&, route: u16, conn: Conn, tried: u32, now_ms: i64) -> Pick       // Pick.To { addr, tag, gen, slot } | Pick.None
//     fn connect_failed(p: P&, conn: Conn, slot: u8, tag: u16, tried: u32, now_ms: i64) -> Retry   // Retry.Next | Retry.GiveUp
//     fn connected(p: P&, conn: Conn, tag: u16)
//     fn closed(p: P&, conn: Conn, tag: u16, why: CloseReason)
// `tried` is a per-connection bit set the ENGINE keeps: it sets bit `slot` of the Pick.To it was handed before it
// connects, and passes the set back on every later call for that connection.
import tcprouter from "../../..";     // the path inside tcprouter (tests/net/harness/); see README.md
import std;
import os;

var LISTEN: u8[>..] = [];
var TARGETS: u8[][>..] = [];
var MAX_TRIES: i64 = 99;

struct spy::Policy { addrs: tcprouter::Addr[..8], count: i64 = 0, max_tries: i64 = 99 }

fn popcount(mask: u32) -> i64 {
    var n = 0;
    for k in 32 { if (mask >> (k as u32)) & 1 == 1 { n++; } }
    n
}

fn spy::pick(p: spy::Policy&, route: u16, conn: tcprouter::Conn, tried: u32, now_ms: i64) -> tcprouter::Pick {
    var s = p.count;
    while s > 0 {
        s--;
        if (tried >> (s as u32)) & 1 == 0 {
            print("PICK route=", route, " tried=", tried, " -> slot=", s, " tag=", 40 + s, " gen=7");
            return tcprouter::Pick.To { addr: p.addrs[s], tag: (40 + s) as u16, gen: 7, slot: s as u8, connect_ms: 0 };
        }
    }
    print("PICK route=", route, " tried=", tried, " -> none");
    return tcprouter::Pick.None;
}

fn spy::connect_failed(p: spy::Policy&, conn: tcprouter::Conn, slot: u8, tag: u16, tried: u32, now_ms: i64) -> tcprouter::Retry {
    print("CONNECT_FAILED slot=", slot, " tag=", tag, " tried=", tried);
    if popcount(tried) >= p.max_tries { tcprouter::Retry.GiveUp } else { tcprouter::Retry.Next }
}

fn spy::connected(p: spy::Policy&, conn: tcprouter::Conn, tag: u16) { print("CONNECTED tag=", tag); }

fn spy::closed(p: spy::Policy&, conn: tcprouter::Conn, tag: u16, why: tcprouter::CloseReason) { print("CLOSED tag=", tag); }

fn spy::on_message(p: spy::Policy&, body: const u8[:], now_ms: i64) -> tcprouter::Effect { tcprouter::Effect.None }

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var w = tcprouter::Worker { .. };
    if !w.start(cfg, index) { write_stderr(str("policy_server: ", w.error, "\n")); return; }
    var p = spy::Policy { .. };
    p.addrs = cfg.targets[0].addrs;
    p.count = cfg.targets[0].addrs.len;
    p.max_tries = MAX_TRIES;
    print("READY");
    w.serve(p) { w, ev => };
}

fn main() {
    let a = args();
    var i = 1;
    while i + 1 < a.len {
        if a[i] == "--listen" { LISTEN.append(a[i + 1]); }
        else if a[i] == "--to" { TARGETS.push(a[i + 1]); }
        else if a[i] == "--max-tries" { let n, ok = parse_int(a[i + 1]); if ok { MAX_TRIES = n; } }
        i += 2;
    }
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(LISTEN) });
    var t = tcprouter::Target { addrs: [] };
    for target in TARGETS { t.addrs.push(tcprouter::addr(target)); }
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::add_target(cfg, t) }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    tcprouter::spawn(cfg, 1, worker);
    tcprouter::wait_for_signal_then_drain(1000);
}
