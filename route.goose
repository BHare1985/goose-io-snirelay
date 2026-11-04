// Route matching (design/02-api.md section 2; RT-3a, RT-3b, RT-3g). Pure: no sockets, no allocation.
namespace tcprouter;

import .config;
import .sni;

// Which route takes a new connection on `listener`, given what its first bytes were (`hello`, from
// parse_hello; ignored on a listener whose `inspect` is None). Returns a reference to the winning
// route inside `cfg` (its index is `cfg.routes.index_of(route)`), or null when no route matches, which
// means the connection is closed. A hello that is NeedMore or Invalid never matches: the first is not
// routable yet, the second is a client the engine closes (RT-3f).
//
// Order of preference (design/05 RT-3b): an exact Sni row, the longest SniSuffix row, a NoSni row (only
// for a client with no name), then an Any row. Within one kind the first row in config order wins.
// The rows of other listeners are skipped. The cost is one pass over the rows per kind: at most
// 256 rows, no allocation.
fn match_route(cfg: const Config&, listener: u16, hello: Hello) -> const Route? {
    var inspect = Inspect.None;
    var known = false;
    for l in cfg.listeners {
        if l.id == listener && !known { inspect = l.inspect; known = true; }
    }
    if !known { return null; }

    // NeedMore and Invalid never match, on any listener (B4 in tests/unit/route_test.goose).
    let routable = match hello {
        NeedMore n => false,
        Invalid => false,
        _ => true,
    };
    if !routable { return null; }

    // Without inspection nobody read a hello: only Any rows can match (B3).
    if inspect == Inspect.None { return tr_first_any(cfg, listener); }

    return match hello {
        Found f => tr_route_for_name(cfg, listener, f.name),
        _ => tr_route_without_name(cfg, listener),      // NoSni or NotTls
    };
}

// Internal: a client with a name: exact, then the longest suffix, then Any.
fn tr_route_for_name(cfg: const Config&, listener: u16, name: const u8[:]) -> const Route? {
    for &r in cfg.routes {
        if r.listener != listener { continue; }
        match r.on {
            Sni s => { if tr_same_name(s.name, name) { return r; } },
            _ => {},
        }
    }
    var best: const Route? = null;
    var best_len = 0;
    for &r in cfg.routes {
        if r.listener != listener { continue; }
        match r.on {
            SniSuffix s => {
                let suffix = tr_trim_dot(s.name);
                if suffix.len > best_len && tr_below(name, suffix) {
                    best .= r;
                    best_len = suffix.len;
                }
            },
            _ => {},
        }
    }
    if best { return best; }
    return tr_first_any(cfg, listener);
}

// Internal: a client with no name, or not TLS at all: a NoSni row, then Any.
fn tr_route_without_name(cfg: const Config&, listener: u16) -> const Route? {
    for &r in cfg.routes {
        if r.listener != listener { continue; }
        match r.on {
            NoSni => { return r; },
            _ => {},
        }
    }
    return tr_first_any(cfg, listener);
}

fn tr_first_any(cfg: const Config&, listener: u16) -> const Route? {
    for &r in cfg.routes {
        if r.listener != listener { continue; }
        match r.on {
            Any => { return r; },
            _ => {},
        }
    }
    return null;
}

// Internal: `name` without one trailing dot.
fn tr_trim_dot(name: const u8[:]) -> const u8[:] {
    if name.len > 0 && name[name.len - 1] == '.' { return name[..name.len - 1]; }
    return name;
}

fn tr_lower(c: u8) -> u8 { return if c >= 'A' && c <= 'Z' { c + 32 } else { c }; }

// Internal: equal as host names: ASCII case ignored, one trailing dot ignored on either side. Empty
// names are never equal to anything.
fn tr_same_name(a: const u8[:], b: const u8[:]) -> bool {
    let x = tr_trim_dot(a);
    let y = tr_trim_dot(b);
    if x.len == 0 || x.len != y.len { return false; }
    for i in x.len { if tr_lower(x[i]) != tr_lower(y[i]) { return false; } }
    return true;
}

// Internal: `name` ends in "." followed by `suffix` (so the apex itself is not below it).
fn tr_below(name: const u8[:], suffix: const u8[:]) -> bool {
    let n = tr_trim_dot(name);
    if suffix.len == 0 || n.len <= suffix.len + 1 { return false; }
    if n[n.len - suffix.len - 1] != '.' { return false; }
    let tail = n[n.len - suffix.len..];
    for i in suffix.len { if tr_lower(tail[i]) != tr_lower(suffix[i]) { return false; } }
    return true;
}
