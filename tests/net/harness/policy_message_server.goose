// Gate for Message.Policy (RT-13g to RT-13i): a forwarding server with a test-double policy that prints every on_message call.
//
//     policy_message_server --listen 127.0.0.1:9000 --to 127.0.0.1:9100 [--workers N]
//
// stdin commands (a control thread, as in tls_server): `msg TEXT` posts Message.Policy { body: TEXT } to every worker.
// Hook lines on stdout: READY; `PICK slot=S tag=T`; `CONNECTED tag=T`; `CLOSED tag=T`; `MSG worker=W body=TEXT now_ok=B`.
// The double answers a body "cut" with Effect.CloseTagged { tag: 40, gen: 7 } (the tag its pick returns), anything else None.
import goose_io from "github.com/BHare1985/goose-io@bfadab427f4ac37a89d9182fbd943d0c9e0d7457";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@ee6e3c9f414f300e4ffe2180f16d9ebe3230233e";
import tcprouter from "../../..";
import std;
import os;

var LISTEN: u8[>..] = [];
var TARGET: u8[>..] = [];
var WORKERS: i64 = 1;

struct spy::Policy { addr: tcprouter::Addr, worker: i64 = 0 }

fn spy::pick(p: spy::Policy&, route: u16, conn: tcprouter::Conn, tried: u32, now_ms: i64) -> tcprouter::Pick {
    if tried != 0 { return tcprouter::Pick.None; }
    print("PICK slot=0 tag=40");
    return tcprouter::Pick.To { addr: p.addr, tag: 40, gen: 7, slot: 0, connect_ms: 0 };
}

fn spy::connect_failed(p: spy::Policy&, conn: tcprouter::Conn, slot: u8, tag: u16, tried: u32, now_ms: i64) -> tcprouter::Retry { tcprouter::Retry.GiveUp }
fn spy::connected(p: spy::Policy&, conn: tcprouter::Conn, tag: u16) { print("CONNECTED tag=", tag); }
fn spy::closed(p: spy::Policy&, conn: tcprouter::Conn, tag: u16, why: tcprouter::CloseReason) { print("CLOSED tag=", tag); }

fn spy::on_message(p: spy::Policy&, body: const u8[:], now_ms: i64) -> tcprouter::Effect {
    print("MSG worker=", p.worker, " body=", body, " len=", body.len, " now_ok=", now_ms > 0);
    if body == "cut" { return tcprouter::Effect.CloseTagged { tag: 40, gen: 7 }; }
    return tcprouter::Effect.None;
}

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
    if !w.start(io, cfg, index) { epoll_ext::report_failed_start(); write_stderr(str("policy_message_server: ", w.error, "\n")); return; }
    io.attach(index);
    var p = spy::Policy { .. };
    p.addr = cfg.targets[0].addrs[0];
    p.worker = index;
    print("READY");
    io.serve() { io, ev => w.on_event(io, ev, p); };
}

extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

fn run_command(io: epoll_ext::Loop&, line: const u8[:]) {
    if line == "sync" {                       // post, then gather: the reply must come after every earlier Policy message was applied (PX-5)
        let s = tcprouter::gather_stats(io, WORKERS);
        print("SYNCED");
        return;
    }
    if line.len > 4 && line[..4] == "msg " {
        var body: u8[..48] = [];
        let text = line[4..];
        if text.len <= 48 { body.append(text); tcprouter::post(io, tcprouter::Message.Policy { body: body }); }
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
    while i + 1 < a.len {
        if a[i] == "--listen" { LISTEN.append(a[i + 1]); }
        else if a[i] == "--to" { TARGET.append(a[i + 1]); }
        else if a[i] == "--workers" { let n, ok = parse_int(a[i + 1]); if ok { WORKERS = n; } }
        i += 2;
    }
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(LISTEN) });
    var t = tcprouter::Target { addrs: [] };
    t.addrs.push(tcprouter::addr(TARGET));
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::add_target(cfg, t) }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }
    let ids = epoll_ext::spawn(WORKERS, cfg, worker);
    tcprouter::workers_ready(WORKERS);
    thread_spawn(control);
    for id in ids { thread_wait(id); }
}
