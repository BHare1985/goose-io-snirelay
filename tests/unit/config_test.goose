// Proves: RT-1c   (the config checks; design/05 RT-1c and design/02 sections 2 and 7)
//
//     goose build --debug tests/unit/config_test.goose && ./tests/unit/config_test
//
// check(cfg, problems) appends one line per problem to `problems` and returns true only when there is
// none. Each line starts with the path of the field at fault, then a colon and what is wrong:
//
//     listeners[1].id: duplicate id 7 (also listeners[0])
//     routes[2].listener: no listener has id 9
//
// This test depends on the paths, not on the wording after the colon. It never expects an abort.
//
// Reading choices of mine, for Charlie to confirm or strike:
//   C1. "Sni rows on a listener without inspect: Sni" (RT-1c) covers all three SNI kinds: Sni,
//       SniSuffix and NoSni. Any is allowed everywhere.
//   C2. check also validates the address text of listeners and targets (design/02 says check reports
//       bad text): "ip:port" or "[ipv6]:port", port 1..65535, no host names (the program resolves).
//   C3. A config with no listeners, or a route with no matching listener, is reported; zero routes is
//       fine (a listener whose connections are all handled by nobody simply closes them).
import tcprouter from "../..";
import goose_io from "github.com/BHare1985/goose-io@v0.3";
import std;

var checks: i64 = 0;
var failures: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    checks++;
    if !ok { failures++; print("FAIL: ", what); }
}

fn listener(cfg: tcprouter::Config&, id: u16, address: const u8[:], inspect: tcprouter::Inspect) {
    cfg.listeners.push(tcprouter::Listener { id: id, addr: tcprouter::addr(address), inspect: inspect });
}

fn any_to_close(cfg: tcprouter::Config&, listener: u16) {
    cfg.routes.push(tcprouter::any_route(listener, tcprouter::Action.Close));
}

// A good config to start from: one plain listener, one SNI listener, routes for both.
fn good() -> tcprouter::Config {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, "0.0.0.0:5432", tcprouter::Inspect.None);
    listener(cfg, 2, "[::]:443", tcprouter::Inspect.Sni);
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::add_target(cfg, tcprouter::target(["10.0.0.5:5432", "[2001:db8::1]:5432"])) }));
    cfg.routes.push(tcprouter::sni_route(2, "api.example.com", tcprouter::Action.Handle { tag: 1 }));
    var suffix = tcprouter::Match.SniSuffix { name: [] };
    suffix.name.append("example.com");
    cfg.routes.push(tcprouter::Route { listener: 2, on: suffix, action: tcprouter::Action.Close });
    cfg.routes.push(tcprouter::Route { listener: 2, on: tcprouter::Match.NoSni, action: tcprouter::Action.Close });
    cfg.routes.push(tcprouter::any_route(2, tcprouter::Action.Close));
    return cfg;
}

// Runs check and returns its report.
fn report(cfg: const tcprouter::Config&) -> u8[>..], bool {
    var problems: u8[>..] = [];
    let ok = tcprouter::check(cfg, problems);
    return problems, ok;
}

fn lines(text: const u8[:]) -> i64 {
    var n = 0;
    each_split(text, '\n') { if it.len > 0 { n++; } };
    return n;
}

fn mentions(text: const u8[:], path: const u8[:]) -> bool { return find(text, path) >= 0; }

// --- a good config -------------------------------------------------------------------------------------

fn test_good() {
    let cfg = good();
    let r, ok = report(cfg);
    check(ok, "RT-1c a good config passes");
    check(r.len == 0, "RT-1c a good config reports nothing");
}

// --- the four problems of RT-1c ------------------------------------------------------------------------

fn test_duplicate_listener_ids() {
    var cfg = good();
    listener(cfg, 1, "0.0.0.0:6000", tcprouter::Inspect.None);        // listeners[2] repeats id 1
    let r, ok = report(cfg);
    check(!ok, "RT-1c duplicate listener ids fail the check");
    check(mentions(r, "listeners[2].id"), "RT-1c ... naming listeners[2].id");
    check(lines(r) == 1, "RT-1c ... as exactly one problem");
}

fn test_unknown_listener_in_route() {
    var cfg = good();
    any_to_close(cfg, 9);                                             // routes[5] names listener 9
    let r, ok = report(cfg);
    check(!ok, "RT-1c a route to an unknown listener fails the check");
    check(mentions(r, "routes[5].listener"), "RT-1c ... naming routes[5].listener");
    check(lines(r) == 1, "RT-1c ... as exactly one problem");
}

fn test_sni_rows_without_inspect() {
    // C1: all three SNI kinds are refused on a listener that does not read the ClientHello.
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, "0.0.0.0:80", tcprouter::Inspect.None);
    cfg.routes.push(tcprouter::sni_route(1, "api.example.com", tcprouter::Action.Close));     // routes[0]
    var suffix = tcprouter::Match.SniSuffix { name: [] };
    suffix.name.append("example.com");
    cfg.routes.push(tcprouter::Route { listener: 1, on: suffix, action: tcprouter::Action.Close });   // routes[1]
    cfg.routes.push(tcprouter::Route { listener: 1, on: tcprouter::Match.NoSni, action: tcprouter::Action.Close });  // routes[2]
    any_to_close(cfg, 1);                                                                      // routes[3]: fine
    let r, ok = report(cfg);
    check(!ok, "RT-1c Sni rows on a listener without inspect: Sni fail the check");
    check(mentions(r, "routes[0].on"), "RT-1c ... naming routes[0].on (Sni)");
    check(mentions(r, "routes[1].on"), "RT-1c ... naming routes[1].on (SniSuffix)");
    check(mentions(r, "routes[2].on"), "RT-1c ... naming routes[2].on (NoSni)");
    check(!mentions(r, "routes[3]"), "RT-1c ... and not the Any row");
    check(lines(r) == 3, "RT-1c ... as exactly three problems");
}

fn test_empty_targets() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, "0.0.0.0:80", tcprouter::Inspect.None);
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::add_target(cfg, tcprouter::Target { addrs: [] }) }));
    let r, ok = report(cfg);
    check(!ok, "RT-1c a Forward route with no target addresses fails the check");
    check(mentions(r, "routes[0].action"), "RT-1c ... naming routes[0].action");
    check(lines(r) == 1, "RT-1c ... as exactly one problem");
}

// --- addresses (C2) --------------------------------------------------------------------------------------

fn address_ok(text: const u8[:]) -> bool {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, text, tcprouter::Inspect.None);
    let r, ok = report(cfg);
    return ok && r.len == 0;
}

fn address_names_field(text: const u8[:]) -> bool {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, text, tcprouter::Inspect.None);
    let r, ok = report(cfg);
    return !ok && mentions(r, "listeners[0].addr");
}

fn test_addresses() {
    for a in ["0.0.0.0:80", "127.0.0.1:65535", "10.0.0.5:1", "[::]:8080", "[::1]:443", "[2001:db8::1]:5432"] {
        check(address_ok(a), str("C2 good address ", a));
    }
    for a in ["", "10.0.0.1", "10.0.0.1:", ":80", "10.0.0.1:0", "10.0.0.1:65536", "10.0.0.1:99999999999",
              "10.0.0.256:80", "10.0.0:80", "localhost:80", "example.com:443", "[::1]", "[::1:80", "::1:80",
              "10.0.0.1:80x", " 10.0.0.1:80", "10.0.0.1:80 ", "[zz::1]:80"] {
        check(address_names_field(a), str("C2 bad address '", a, "' is reported at listeners[0].addr"));
    }
    // Text longer than the 48 bytes an Addr holds.
    var long: u8[>..] = [];
    for i in 80 { long.push('1'); }
    long.append(":80");
    check(address_names_field(long), "C2 an address over 48 bytes is reported, not cut short");

    // A bad target address names the route and the target.
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, "0.0.0.0:80", tcprouter::Inspect.None);
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::add_target(cfg, tcprouter::target(["10.0.0.5:80", "not an address"])) }));
    let r, ok = report(cfg);
    check(!ok && mentions(r, "routes[0].action"), "C2 a bad target address is reported at routes[0].action");
}

// --- everything is reported, not just the first problem ----------------------------------------------------

fn test_all_problems() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, "0.0.0.0:80", tcprouter::Inspect.None);
    listener(cfg, 1, "nonsense", tcprouter::Inspect.None);                                    // dup id + bad address
    cfg.routes.push(tcprouter::sni_route(1, "api.example.com", tcprouter::Action.Close));    // sni without inspect
    any_to_close(cfg, 8);                                                                     // unknown listener
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::add_target(cfg, tcprouter::Target { addrs: [] }) }));
    let r, ok = report(cfg);
    check(!ok, "RT-1c a config with five problems fails");
    check(mentions(r, "listeners[1].id"), "RT-1c all: duplicate id");
    check(mentions(r, "listeners[1].addr"), "RT-1c all: bad address");
    check(mentions(r, "routes[0].on"), "RT-1c all: Sni row without inspect");
    check(mentions(r, "routes[1].listener"), "RT-1c all: unknown listener");
    check(mentions(r, "routes[2].action"), "RT-1c all: empty target");
    check(lines(r) == 5, "RT-1c all: one line per problem, five lines");
}

// --- the check appends, and tolerates a full config ------------------------------------------------------------

fn test_appends_and_limits() {
    var problems: u8[>..] = [];
    problems.append("earlier text\n");
    var cfg = good();
    any_to_close(cfg, 9);
    check(!tcprouter::check(cfg, problems), "RT-1c check with a prefilled buffer still fails the bad config");
    check(find(problems, "earlier text") == 0, "RT-1c check appends: what was in the buffer stays first");

    // No listeners at all (C3).
    var none = tcprouter::Config { .. };
    let r, ok = report(none);
    check(!ok && mentions(r, "listeners"), "C3 a config with no listeners is reported at listeners");

    // Full tables: 16 listeners and 256 routes, all valid.
    var full = tcprouter::Config { .. };
    for i in 16 { listener(full, (i + 1) as u16, str("0.0.0.0:", 9000 + i), tcprouter::Inspect.None); }
    for i in 256 { any_to_close(full, ((i % 16) + 1) as u16); }
    let r2, ok2 = report(full);
    check(ok2 && r2.len == 0, "RT-1c a full valid config (16 listeners, 256 routes) passes");
}

// Building a Config from too much text never aborts; check() reports it where it went wrong.
fn test_overflows() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, "0.0.0.0:80", tcprouter::Inspect.Sni);
    var long: u8[>..] = [];
    for i in 300 { long.push('a'); }
    cfg.routes.push(tcprouter::sni_route(1, long, tcprouter::Action.Close));                         // routes[0]: name too long
    let nine = tcprouter::add_target(cfg, tcprouter::target(["1.1.1.1:1", "1.1.1.2:1", "1.1.1.3:1", "1.1.1.4:1", "1.1.1.5:1",
                                                             "1.1.1.6:1", "1.1.1.7:1", "1.1.1.8:1", "1.1.1.9:1"]));
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: nine }));                // routes[1]: nine targets
    let r, ok = report(cfg);
    check(!ok, "RT-1c a 300-byte route name and nine target addresses fail the check (and did not abort)");
    check(mentions(r, "routes[0].on"), "RT-1c ... the long name is reported at routes[0].on");
    check(mentions(r, "routes[1].action"), "RT-1c ... the ninth target is reported at routes[1].action");
}

// Routes share targets by index; an index that is not in the table is reported, a full table hands out an index check() rejects.
fn test_target_table() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, "0.0.0.0:80", tcprouter::Inspect.None);
    let shared = tcprouter::add_target(cfg, tcprouter::target(["10.0.0.5:80"]));
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: shared }));
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: shared }));
    let r, ok = report(cfg);
    check(ok && cfg.targets.len == 1, "RT-1c two routes can share one target entry");
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: 7 }));
    let r2, ok2 = report(cfg);
    check(!ok2 && mentions(r2, "routes[2].action"), "RT-1c a Forward route naming a target that is not in the table is reported at routes[2].action");
    var full = tcprouter::Config { .. };
    listener(full, 1, "0.0.0.0:80", tcprouter::Inspect.None);
    var last: u16 = 0;
    for k in 65 { last = tcprouter::add_target(full, tcprouter::target(["10.0.0.5:80"])); }
    full.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: last }));
    let r3, ok3 = report(full);
    check(full.targets.len == 64 && !ok3 && mentions(r3, "routes[0].action"), "RT-1c a 65th target does not fit: its index is rejected by the check");
}

fn main() {
    test_target_table();
    test_overflows();
    test_good();
    test_duplicate_listener_ids();
    test_unknown_listener_in_route();
    test_sni_rows_without_inspect();
    test_empty_targets();
    test_addresses();
    test_all_problems();
    test_appends_and_limits();
    if failures > 0 {
        print(failures, " of ", checks, " checks FAILED");
        exit(1);
    }
    print("all ", checks, " checks passed");
}
