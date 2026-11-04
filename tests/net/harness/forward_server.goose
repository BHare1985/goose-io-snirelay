// The system under test for the network tests: a forwarding server written the way a user would write
// examples/forward_port.goose, except that its config comes from the command line (a program may read
// flags; the library never does).
//
//     forward_server --listen 127.0.0.1:9000 [--listen [::1]:9000] --to 127.0.0.1:9100 [--to …]
//                    [--route LISTEN=TARGET[,TARGET…] …]
//                    [--workers 1] [--buffers 4096] [--buffer-size 16384] [--stat-ms 1000]
//                    [--inspect-listen ADDR] [--sni NAME=T[,T]] [--sni-suffix NAME=T[,T]] [--sni-none T[,T]] [--sni-any T[,T]]
//                    [--control] [--drain-ms N]
//                    [--connect-timeout-ms N] [--inspect-timeout-ms N] [--idle-timeout-ms N] [--half-close-timeout-ms N]
// --control: read commands from stdin on a control thread (`drain MS`), and exit when the workers have drained; without it the
// program waits for SIGTERM/SIGINT, drains with --drain-ms (default 5000) and exits.
// --inspect-listen: one listener with `inspect: Sni`; the --sni* flags add its routes, in the order given:
//   --sni exact name, --sni-suffix names below a domain, --sni-none no name / not TLS, --sni-any everything else.
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
    inspect_listen: u8[][>..] = [],
    sni_specs: u8[][>..] = [],          // "sni:NAME=T,T", "suffix:NAME=T", "none:T", "any:T", in flag order
    connect_timeout_ms: i64 = 0,
    inspect_timeout_ms: i64 = 0,
    control: bool = false,
    drain_ms: i64 = 5000,
    idle_timeout_ms: i64 = 0,
    half_close_timeout_ms: i64 = 0,
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
           " buffer_waits=", s.buffer_waits, " stale_events=", s.stale_events, " bad_events=", s.bad_events,
           " accept_failures=", s.accept_failures);
    format(line, " closed=");
    for k in 11 { if k > 0 { line.push(','); } format(line, s.closed[k]); }
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

// --- the control thread ---------------------------------------------------------------------------------------------

// Reads commands from stdin and turns them into messages to the workers: the pattern a real program uses for its control
// protocol. It runs after spawn(), so it has the message pipes (globals are copied to a thread when it starts).
thread_fn control() {
    var line: u8[>..] = [];
    while read_line(line) {
        let space = find(line, " ");
        let verb = if space < 0 { line[..] } else { line[..space] };
        let rest = if space < 0 { line[line.len..] } else { line[space + 1..] };
        if verb == "drain" {
            let ms, ok = parse_int(rest);
            if ok { tcprouter::post(tcprouter::Message.Drain { deadline_ms: ms }); }
        }
        line.clear();
    }
}

// --- main -------------------------------------------------------------------------------------------------

fn parse_options(o: Options&) {
    let a = args();
    var i = 1;
    while i < a.len {
        let flag = a[i];
        if flag == "--control" { o.control = true; i++; continue; }
        if i + 1 >= a.len { die(str(flag, " needs a value")); }
        let value = a[i + 1];
        if flag == "--listen" { o.listens.push(value); }
        else if flag == "--to" { o.targets.push(value); }
        else if flag == "--route" { o.routes.push(value); }
        else if flag == "--inspect-listen" { o.inspect_listen.push(value); }
        else if flag == "--sni" { o.sni_specs.push(str("sni:", value)); }
        else if flag == "--sni-suffix" { o.sni_specs.push(str("suffix:", value)); }
        else if flag == "--sni-none" { o.sni_specs.push(str("none:", value)); }
        else if flag == "--sni-any" { o.sni_specs.push(str("any:", value)); }
        else if flag == "--connect-timeout-ms" { o.connect_timeout_ms = number(value, flag); }
        else if flag == "--inspect-timeout-ms" { o.inspect_timeout_ms = number(value, flag); }
        else if flag == "--drain-ms" { o.drain_ms = number(value, flag); }
        else if flag == "--idle-timeout-ms" { o.idle_timeout_ms = number(value, flag); }
        else if flag == "--half-close-timeout-ms" { o.half_close_timeout_ms = number(value, flag); }
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
    if o.routes.len == 0 && o.inspect_listen.len == 0 && (o.listens.len == 0 || o.targets.len == 0) {
        die("need --route, --inspect-listen, or --listen and --to");
    }

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

    if o.connect_timeout_ms > 0 { cfg.limits.connect_timeout_ms = o.connect_timeout_ms; }
    if o.inspect_timeout_ms > 0 { cfg.limits.inspect_timeout_ms = o.inspect_timeout_ms; }
    if o.idle_timeout_ms > 0 { cfg.limits.idle_timeout_ms = o.idle_timeout_ms; }
    if o.half_close_timeout_ms > 0 { cfg.limits.half_close_timeout_ms = o.half_close_timeout_ms; }
    var have_inspect = false;
    for text in o.inspect_listen {                  // an array of strings can be walked, not indexed
        if !have_inspect {
            cfg.listeners.push(tcprouter::Listener { id: id, addr: tcprouter::addr(text), inspect: tcprouter::Inspect.Sni });
            have_inspect = true;
        }
    }
    if have_inspect {
        for spec in o.sni_specs {
            let colon = find(spec, ":");
            let kind = spec[..colon];
            let rest = spec[colon + 1..];
            let has_name = kind == "sni" || kind == "suffix";
            let eq = find(rest, "=");
            if has_name && eq < 0 { die(str("--sni needs NAME=TARGET, got '", rest, "'")); }
            let name = if has_name { rest[..eq] } else { "" };
            let targets = if has_name { rest[eq + 1..] } else { rest };
            var t = tcprouter::Target { addrs: [] };
            each_split(targets, ',') { t.addrs.push(tcprouter::addr(it)); };
            let action = tcprouter::Action.Forward { to: t };
            if kind == "sni" { cfg.routes.push(tcprouter::sni_route(id, name, action)); }
            else if kind == "suffix" { cfg.routes.push(tcprouter::sni_suffix_route(id, name, action)); }
            else if kind == "none" { cfg.routes.push(tcprouter::Route { listener: id, on: tcprouter::Match.NoSni, action: action }); }
            else { cfg.routes.push(tcprouter::any_route(id, action)); }
        }
        id++;
    }

    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { write_stderr(problems); exit(2); }

    let ids = tcprouter::spawn(cfg, o.workers, worker);
    var failed = 0;
    for i in o.workers { if !qget<Started>().ok { failed++; } }
    if failed > 0 { exit(1); }                    // a worker could not start (for instance, the port is taken)
    if o.control {
        thread_spawn(control);
        for id in ids { thread_wait(id); }        // returns when every worker has drained
    } else {
        tcprouter::wait_for_signal_then_drain(o.drain_ms);
    }
}
