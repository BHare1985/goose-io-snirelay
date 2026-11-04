// The system under test for the network tests: a forwarding server written the way a user would write
// examples/forward_port.goose, except that its config comes from the command line (a program may read
// flags; the library never does).
//
//     forward_server --listen 127.0.0.1:9000 [--listen [::1]:9000] --to 127.0.0.1:9100 [--to …]
//                    [--route LISTEN=TARGET[,TARGET…] …]
//                    [--workers 1] [--buffers 4096] [--buffer-size 16384] [--stat-ms 1000]
// --listen/--to: every --listen forwards to every --to. --route: one listener with its own targets
// (an address containing ':' is fine: the split is at the '=').
//
// Output, one line each, on stdout:
//     READY <worker index>                      after start() succeeded
//     STAT <worker> accepted=… open=… … buffer_waits=…   every --stat-ms, from a Tick event
// Errors go to stderr. Exit status 2 for a bad command line or config.
import tcprouter from "../../..";
import std;
import os;

// A worker tells main how it started, over a typed queue: the way a user's main learns that a port was taken.
struct Started { worker: i64, ok: bool }

root struct Options {
    listens: u8[][>..] = [],
    targets: u8[][>..] = [],
    routes: u8[][>..] = [],
    workers: i64 = 1,
    buffers: i64 = 4096,
    buffer_size: i64 = 16384,
    stat_ms: i64 = 1000,
}

// How often a worker prints STAT. A global set in main before the workers start: workers get a copy.
var STAT_MS: i64 = 1000;

fn die(message: const u8[:]) {
    write_stderr(str("forward_server: ", message, "\n"));
    exit(2);
}

fn number(text: const u8[:], what: const u8[:]) -> i64 {
    let n, ok = parse_int(text);
    if !ok || n < 1 { die(str(what, " needs a positive number, got '", text, "'")); }
    return n;
}

// --- one worker -----------------------------------------------------------------------------------------

fn print_stats(w: tcprouter::Worker&, index: i64) {
    let s = tcprouter::stats(w);
    var line: u8[>..] = [];
    format(line, "STAT ", index, " accepted=", s.accepted, " open=", s.open,
           " bytes_in=", s.bytes_in, " bytes_out=", s.bytes_out,
           " connect_failures=", s.connect_failures, " retries=", s.retries,
           " buffers_total=", s.buffers_total, " buffers_in_use=", s.buffers_in_use,
           " buffer_waits=", s.buffer_waits);
    print(line);
}

// The serve block only calls this: a `return` in the block would leave the whole worker.
fn on_event(w: tcprouter::Worker&, ev: tcprouter::Event, index: i64, every_ms: i64, last: i64&) {
    match ev {
        Tick t => {
            if t.now_ms - last >= every_ms {
                last = t.now_ms;
                print_stats(w, index);
            }
        },
        _ => {},
    }
}

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var w = tcprouter::Worker { .. };
    if !tcprouter::start(w, cfg, index) {
        write_stderr(str("forward_server: worker ", index, ": ", w.error, "\n"));
        qput(Started { worker: index, ok: false });
        return;
    }
    qput(Started { worker: index, ok: true });
    print("READY ", index);
    var last: i64 = 0;
    let every_ms = STAT_MS;
    tcprouter::serve(w) { w, ev => on_event(w, ev, index, every_ms, last); };
}

// --- main -------------------------------------------------------------------------------------------------

fn parse_options(o: Options&) {
    let a = args();
    var i = 1;
    while i < a.len {
        let flag = a[i];
        if i + 1 >= a.len { die(str(flag, " needs a value")); }
        let value = a[i + 1];
        if flag == "--listen" { o.listens.push(value); }
        else if flag == "--to" { o.targets.push(value); }
        else if flag == "--route" { o.routes.push(value); }
        else if flag == "--workers" { o.workers = number(value, flag); }
        else if flag == "--buffers" { o.buffers = number(value, flag); }
        else if flag == "--buffer-size" { o.buffer_size = number(value, flag); }
        else if flag == "--stat-ms" { o.stat_ms = number(value, flag); }
        else { die(str("unknown flag ", flag)); }
        i += 2;
    }
}

fn main() {
    var o = Options { .. };
    parse_options(o);
    if o.routes.len == 0 && (o.listens.len == 0 || o.targets.len == 0) { die("need --route, or --listen and --to"); }

    var cfg = tcprouter::Config { .. };
    cfg.limits.buffers_per_worker = o.buffers;
    cfg.limits.buffer_size = o.buffer_size;
    STAT_MS = o.stat_ms;
    var id: u16 = 1;
    for l in o.listens {
        if cfg.listeners.len == cfg.listeners.cap { die("too many --listen (16 at most)"); }
        cfg.listeners.push(tcprouter::Listener { id: id, addr: tcprouter::addr(l) });
        var t = tcprouter::Target { addrs: [] };
        for target in o.targets {
            if t.addrs.len == t.addrs.cap { die("too many --to (8 at most)"); }
            t.addrs.push(tcprouter::addr(target));
        }
        cfg.routes.push(tcprouter::any_route(id, tcprouter::Action.Forward { to: t }));
        id++;
    }

    for r in o.routes {
        if cfg.listeners.len == cfg.listeners.cap { die("too many listeners (16 at most)"); }
        let eq = find(r, "=");
        if eq < 0 { die(str("--route needs LISTEN=TARGET, got '", r, "'")); }
        cfg.listeners.push(tcprouter::Listener { id: id, addr: tcprouter::addr(r[..eq]) });
        var t = tcprouter::Target { addrs: [] };
        each_split(r[eq + 1..], ',') {
            if t.addrs.len == t.addrs.cap { die("too many targets (8 at most)"); }
            t.addrs.push(tcprouter::addr(it));
        };
        cfg.routes.push(tcprouter::any_route(id, tcprouter::Action.Forward { to: t }));
        id++;
    }

    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }

    tcprouter::spawn(cfg, o.workers, worker);
    var failed = 0;
    for i in o.workers { if !qget<Started>().ok { failed++; } }
    if failed > 0 { exit(1); }                    // a worker could not start (for instance, the port is taken)
    tcprouter::wait_for_signal_then_drain(5000);
}
