// The configuration of a router: plain, flat data. Build it by hand or from a file, check it, and
// hand the same value to every worker. (design/02-api.md section 2)
namespace tcprouter;

// A socket address as written by a person: "0.0.0.0:443", "[::]:8080", "10.0.0.5:5432". It is
// parsed when a worker starts, so building a Config never fails; check() reports bad text.
// `too_long` is set when the text did not fit in 64 bytes; check() reports it. Building a Config never aborts.
struct Addr { text: u8[..64], too_long: bool = false }

fn addr(text: const u8[:]) -> Addr {
    var a = Addr { text: [] };
    if text.len > a.text.cap {
        a.too_long = true;
        a.text.append(text[..a.text.cap]);
    } else {
        a.text.append(text);
    }
    return a;
}

// Where a connection's bytes go when the engine forwards them: tried in order, rotating the
// first choice from one connection to the next (the built-in policy).
// `too_many` is set when more than 8 addresses were given; check() reports it.
struct Target { addrs: Addr[..8], too_many: bool = false }

fn target(names: const u8[:][:]) -> Target {
    var t = Target { addrs: [] };
    for n in names {
        if t.addrs.len == t.addrs.cap { t.too_many = true; } else { t.addrs.push(addr(n)); }
    }
    return t;
}

// None: route by listener only. Sni: wait for the TLS ClientHello and route by server name.
enum Inspect { None, Sni }

struct Listener {
    id: u16,                           // yours; routes and events refer to it
    addr: Addr,
    inspect: Inspect = Inspect.None,
}

// What a route matches. The first route that matches, in config order, wins.
enum Match {
    Any,                               // every connection on the listener (port routing)
    Sni { name: u8[..253], too_long: bool = false },        // exact, case-insensitive, trailing dot ignored
    SniSuffix { name: u8[..253], too_long: bool = false },  // "example.com": any name ending in ".example.com"
    NoSni,                             // a ClientHello without server_name, or not TLS at all
}

enum Action {
    Forward { to: Target },            // the engine connects and copies bytes both ways
    Handle { tag: u16 },               // your serve block gets the events, with this tag
    Close,                             // close at once
}

// (`match` is a keyword in Goose, so the field is `on`.)
struct Route { listener: u16, on: Match, action: Action }

struct Limits {
    connect_timeout_ms: i64 = 2000,
    idle_timeout_ms: i64 = 300000,
    half_close_timeout_ms: i64 = 30000,
    inspect_timeout_ms: i64 = 5000,    // time allowed for the ClientHello to arrive
    max_conns_per_worker: i64 = 65536,
    buffer_size: i64 = 16384,
    buffers_per_worker: i64 = 4096,
}

struct Config {
    listeners: Listener[..16],
    routes: Route[..256],
    limits: Limits = Limits { .. },
}

// Route constructors, so a config reads like a table.
fn sni_route(listener: u16, name: const u8[:], action: Action) -> Route {
    var n = Match.Sni { name: [] };
    if name.len > n.name.cap {
        n.too_long = true;
        n.name.append(name[..n.name.cap]);
    } else {
        n.name.append(name);
    }
    return Route { listener: listener, on: n, action: action };
}

fn any_route(listener: u16, action: Action) -> Route {
    return Route { listener: listener, on: Match.Any, action: action };
}
