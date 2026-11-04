// check(): is this Config usable? (design/02-api.md section 7, RT-1c)
namespace tcprouter;

import std;
import .config;
import .address;

// Appends one line per problem to `problems` and returns true when there is none. Each line starts
// with the path of the field at fault, a colon, and what is wrong:
//     listeners[2].id: duplicate id 1 (also listeners[0])
//     routes[5].listener: no listener has id 9
// Everything wrong is reported, not just the first problem. Never aborts; `cfg` is not changed.
fn check(cfg: const Config&, problems: u8[>..]&) -> bool {
    let before = problems.len;

    if cfg.listeners.len == 0 { problems.append("listeners: the config has no listeners\n"); }

    for i in cfg.listeners.len {
        let l = cfg.listeners[i];
        for j in i {
            if cfg.listeners[j].id == l.id {
                format(problems, "listeners[", i, "].id: duplicate id ", l.id, " (also listeners[", j, "])\n");
                break;
            }
        }
        tr_check_addr(problems, str("listeners[", i, "].addr"), l.addr);
    }

    for i in cfg.routes.len {
        let r = cfg.routes[i];
        // The first listener with that id is the one the route belongs to.
        var at = -1;
        for j in cfg.listeners.len { if at < 0 && cfg.listeners[j].id == r.listener { at = j; } }
        if at < 0 {
            format(problems, "routes[", i, "].listener: no listener has id ", r.listener, "\n");
        }

        match r.on {
            Any => {},
            Sni s => {
                if s.too_long { format(problems, "routes[", i, "].on: name longer than 253 bytes\n"); }
                tr_check_sni_listener(problems, cfg, i, at, "Sni");
            },
            SniSuffix s => {
                if s.too_long { format(problems, "routes[", i, "].on: name longer than 253 bytes\n"); }
                tr_check_sni_listener(problems, cfg, i, at, "SniSuffix");
            },
            NoSni => { tr_check_sni_listener(problems, cfg, i, at, "NoSni"); },
        }

        match r.action {
            Forward f => { tr_check_target(problems, i, f.to); },
            _ => {},
        }
    }
    return problems.len == before;
}

// Internal: an SNI row needs its listener to read the ClientHello.
fn tr_check_sni_listener(problems: u8[>..]&, cfg: const Config&, route: i64, listener_at: i64, kind: const u8[:]) {
    if listener_at >= 0 && cfg.listeners[listener_at].inspect != Inspect.Sni {
        format(problems, "routes[", route, "].on: a ", kind, " row needs listener ",
               cfg.listeners[listener_at].id, " to have inspect: Sni\n");
    }
}

fn tr_check_addr(problems: u8[>..]&, path: const u8[:], a: Addr) {
    if a.too_long {
        format(problems, path, ": address text is longer than 64 bytes\n");
        return;
    }
    var parsed = tr_Parsed { false, [0; 16], 0 };
    if !tr_parse_addr(a.text, parsed) {
        format(problems, path, ": bad address '", a.text, "' (want ip:port or [ipv6]:port; no host names)\n");
    }
}

fn tr_check_target(problems: u8[>..]&, route: i64, t: Target) {
    let path = str("routes[", route, "].action");
    if t.addrs.len == 0 && !t.too_many { format(problems, path, ": the target has no addresses\n"); }
    if t.too_many { format(problems, path, ": the target has more than 8 addresses\n"); }
    for k in t.addrs.len {
        var parsed = tr_Parsed { false, [0; 16], 0 };
        if t.addrs[k].too_long {
            format(problems, path, ": target address ", k, " is longer than 64 bytes\n");
        } else if !tr_parse_addr(t.addrs[k].text, parsed) {
            format(problems, path, ": bad target address ", k, " '", t.addrs[k].text, "'\n");
        }
    }
}
