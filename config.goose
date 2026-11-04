// The configuration of a router: plain, flat data. Build it by hand or from a file, check it, and
// hand the same value to every worker. (design/02-api.md section 2)
namespace tcprouter;

// A socket address as written by a person: "0.0.0.0:443", "[::]:8080", "10.0.0.5:5432". It is
// parsed when a worker starts, so building a Config never fails; check() reports bad text.
// `too_long` is set when the text did not fit in 48 bytes (the longest valid text, "[ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255]:65535", is 47); check() reports it.
// Building a Config never aborts.
struct Addr { text: u8[..48], too_long: bool = false }

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
// `too_many` is set when more than 8 addresses were given; check() reports it. `tag` and `gen` label the connections forwarded
// through this target, for deadlines and close-by-tag (messages.goose); tag 0 is untagged and is never fenced.
struct Target { addrs: Addr[..8], too_many: bool = false, tag: u16 = 0, gen: u32 = 0 }

// Targets live in Config.targets; a route names one by its index, so routes that share backends share the entry.
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
    // The name is `len` bytes of Config.names starting at `at` (names are stored once, in one pool, not 253 bytes per route).
    // `too_long` is set when the name was longer than 253 bytes or did not fit in the pool; check() reports it.
    Sni { at: u16, len: u8 = 0, too_long: bool = false },        // exact, case-insensitive, trailing dot ignored
    SniSuffix { at: u16, len: u8 = 0, too_long: bool = false },  // "example.com": any name ending in ".example.com"
    NoSni,                             // a ClientHello without server_name, or not TLS at all
}

enum Action {
    Forward { to: u16 },               // the engine connects and copies bytes both ways; `to` is an index into Config.targets (add_target)
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
    buffer_size: i64 = 32768,
    buffers_per_worker: i64 = 4096,
}

struct Config {
    listeners: Listener[..16],
    routes: Route[..256],
    names: u8[..8192],                // the SNI names of the routes, one after the other (sni_route, sni_suffix_route)
    targets: Target[..64],             // what Forward routes point at: shared, so 8 addresses are not repeated per route
    limits: Limits = Limits { .. },
    fenced_tags: u16[..16],            // tags that start with no deadline, so their connections are closed until one arrives (RT-6e)
}

// Adds a target to the table and returns its index for Action.Forward { to }. When the table is full it returns
// _NO_TARGET, an index check() reports as unknown.
let _NO_TARGET: u16 = 65535;
fn add_target(cfg: Config&, t: Target) -> u16 {
    if cfg.targets.len == cfg.targets.cap { return _NO_TARGET; }
    cfg.targets.push(t);
    return (cfg.targets.len - 1) as u16;
}

// Route constructors, so a config reads like a table.
// Stores a route name in the pool and returns where it went. A name longer than 253 bytes is cut and flagged, and a
// name that does not fit in the pool is stored as empty and flagged; check() reports both.
fn _store_name(cfg: Config&, name: const u8[:]) -> u16, u8, bool {
    var take = name.len;
    var flagged = false;
    if take > 253 { take = 253; flagged = true; }
    if cfg.names.len + take > cfg.names.cap { take = 0; flagged = true; }
    let at = cfg.names.len;
    cfg.names.append(name[..take]);
    return at as u16, take as u8, flagged;
}

// The bytes of a stored name.
fn name_text(cfg: const Config&, at: u16, len: u8) -> const u8[:] {
    let from = at as i64;
    let to = from + len;
    return cfg.names[from..to];
}

fn sni_route(cfg: Config&, listener: u16, name: const u8[:], action: Action) -> Route {
    let at, len, flagged = _store_name(cfg, name);
    return Route { listener: listener, on: Match.Sni { at: at, len: len, too_long: flagged }, action: action };
}

fn any_route(listener: u16, action: Action) -> Route {
    return Route { listener: listener, on: Match.Any, action: action };
}

// A SniSuffix route. Users type "*.example.com" (as on a wildcard certificate), the stored form is the
// bare "example.com": it matches names below it ("a.example.com"), never "example.com" itself.
fn sni_suffix_route(cfg: Config&, listener: u16, name: const u8[:], action: Action) -> Route {
    var bare = name;
    if bare.len >= 2 && bare[0] == '*' && bare[1] == '.' { bare = bare[2..]; }
    let at, len, flagged = _store_name(cfg, bare);
    return Route { listener: listener, on: Match.SniSuffix { at: at, len: len, too_long: flagged }, action: action };
}
