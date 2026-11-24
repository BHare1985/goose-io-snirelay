// Proves: RT-3a RT-3b RT-3g   (and the route half of RT-3f: an Invalid hello matches no route)
//
//     goose build --debug tests/unit/route_test.goose && ./tests/unit/route_test
//
// Routing is a pure function shared by the engine and this test:
//     tcprouter::match_route(cfg, listener, hello) -> const Route?
// It returns a reference to the winning route inside cfg (the test asks cfg.routes.index_of(route)
// which one), or null: no route, so the connection is closed.
//
// The order of preference, as design/05 RT-3b states it:
//   1. an exact Sni route          (case-insensitive; a trailing dot on either side is ignored)
//   2. the longest SniSuffix route (suffix "example.com" matches "a.example.com", not "example.com")
//   3. a NoSni route               (only when the client sent no name, or was not TLS)
//   4. an Any route
// Inside one kind, the first row in config order wins; the kinds beat each other regardless of order.
//
// Reading choices of mine, for Charlie to confirm or strike (the design leaves them open):
//   B1. A SniSuffix row is written WITHOUT a star: "example.com", as config.goose documents.
//       It matches only names that end in ".example.com", never "example.com" itself.
//   B2. A hello that carries a name never falls to a NoSni row: unmatched names go to Any.
//   B3. On a listener whose inspect is None, only Any rows can match; the hello is ignored.
//   B4. NeedMore and Invalid match nothing (null), whatever rows exist, Any included.
import tcprouter from "../..";
import goose_io from "github.com/BHare1985/goose-io@v0.4";
import std;

var checks: i64 = 0;
var failures: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    checks++;
    if !ok { failures++; print("FAIL: ", what); }
}

// --- building configs and hellos ------------------------------------------------------------------

fn listener(cfg: tcprouter::Config&, id: u16, inspect: tcprouter::Inspect) {
    cfg.listeners.push(tcprouter::Listener { id: id, addr: tcprouter::addr("127.0.0.1:1"), inspect: inspect });
}

// Every route closes: the action does not matter here, only which row wins.
fn add(cfg: tcprouter::Config&, listener: u16, on: tcprouter::Match) {
    cfg.routes.push(tcprouter::Route { listener: listener, on: on, action: tcprouter::Action.Close });
}

fn row_sni(cfg: tcprouter::Config&, listener: u16, name: const u8[:]) {
    var m = tcprouter::Match.Sni { name: [] };
    m.name.append(name);
    add(cfg, listener, m);
}
fn row_suffix(cfg: tcprouter::Config&, listener: u16, name: const u8[:]) {
    var m = tcprouter::Match.SniSuffix { name: [] };
    m.name.append(name);
    add(cfg, listener, m);
}
fn row_no_sni(cfg: tcprouter::Config&, listener: u16) { add(cfg, listener, tcprouter::Match.NoSni); }
fn row_any(cfg: tcprouter::Config&, listener: u16) { add(cfg, listener, tcprouter::Match.Any); }

fn found(name: const u8[:]) -> tcprouter::Hello {
    var h = tcprouter::Hello.Found { name: [] };
    h.name.append(name);
    return h;
}
fn no_sni() -> tcprouter::Hello { return tcprouter::Hello.NoSni; }
fn not_tls() -> tcprouter::Hello { return tcprouter::Hello.NotTls; }
fn need_more() -> tcprouter::Hello { return tcprouter::Hello.NeedMore { total: 100 }; }
fn invalid() -> tcprouter::Hello { return tcprouter::Hello.Invalid; }

// The index of the winning row, or -1 for no route.
fn which(cfg: const tcprouter::Config&, listener: u16, hello: tcprouter::Hello) -> i64 {
    let r = tcprouter::match_route(cfg, listener, hello);
    if r { return cfg.routes.index_of(r); }
    return -1;
}

// --- RT-3a: port routing ----------------------------------------------------------------------------

fn test_any() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, tcprouter::Inspect.None);
    listener(cfg, 2, tcprouter::Inspect.None);
    row_any(cfg, 1);                     // row 0
    row_any(cfg, 2);                     // row 1

    check(which(cfg, 1, no_sni()) == 0, "RT-3a Any row takes every connection on listener 1");
    check(which(cfg, 2, no_sni()) == 1, "RT-3a listener 2 has its own Any row");
    check(which(cfg, 3, no_sni()) == -1, "RT-3a an unknown listener matches nothing");

    var empty = tcprouter::Config { .. };
    listener(empty, 1, tcprouter::Inspect.None);
    check(which(empty, 1, no_sni()) == -1, "RT-3a a listener with no routes matches nothing");

    // First Any in config order wins.
    row_any(cfg, 1);                     // row 2
    check(which(cfg, 1, no_sni()) == 0, "RT-3a the first of two Any rows wins");
}

// B3: no inspection, so the hello is ignored and SNI rows cannot match.
fn test_no_inspect() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, tcprouter::Inspect.None);
    row_sni(cfg, 1, "api.example.com");  // 0: would match the hello below, but nobody read a hello
    row_no_sni(cfg, 1);                  // 1
    row_any(cfg, 1);                     // 2
    check(which(cfg, 1, found("api.example.com")) == 2, "B3 inspect None: only Any rows can match (name)");
    check(which(cfg, 1, no_sni()) == 2, "B3 inspect None: only Any rows can match (no name)");
    check(which(cfg, 1, invalid()) == -1, "B4 an Invalid hello matches nothing, even with Any");
}

// --- RT-3b: exact names --------------------------------------------------------------------------------

fn test_exact() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, tcprouter::Inspect.Sni);
    row_sni(cfg, 1, "api.example.com");        // 0
    row_sni(cfg, 1, "Web.Example.COM");        // 1: case in the config does not matter
    row_sni(cfg, 1, "dotted.example.com.");    // 2: a trailing dot in the config is ignored
    row_sni(cfg, 1, "api.example.com");        // 3: a duplicate; the first one wins

    check(which(cfg, 1, found("api.example.com")) == 0, "RT-3b exact match, first row of two");
    check(which(cfg, 1, found("web.example.com")) == 1, "RT-3b the config's capitals are ignored");
    check(which(cfg, 1, found("dotted.example.com")) == 2, "RT-3b the config's trailing dot is ignored");
    check(which(cfg, 1, found("API.Example.com")) == 0, "RT-3b the hello's capitals are ignored too");
    check(which(cfg, 1, found("dotted.example.com.")) == 2, "RT-3b the hello's trailing dot is ignored too");
    check(which(cfg, 1, found("api.example.com.evil")) == -1, "RT-3b a longer name does not match");
    check(which(cfg, 1, found("xapi.example.com")) == -1, "RT-3b a name with a prefix does not match");
    check(which(cfg, 1, found("example.com")) == -1, "RT-3b a shorter name does not match");
    check(which(cfg, 2, found("api.example.com")) == -1, "RT-3b another listener's rows do not match");
}

// --- RT-3b: suffixes -------------------------------------------------------------------------------------

fn test_suffix() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, tcprouter::Inspect.Sni);
    row_suffix(cfg, 1, "example.com");         // 0
    row_suffix(cfg, 1, "b.example.com");       // 1: longer, listed after the shorter one
    row_suffix(cfg, 1, "Example.COM.");        // 2: same suffix as row 0; row 0 stays first

    check(which(cfg, 1, found("a.example.com")) == 0, "RT-3b suffix matches one label below");
    check(which(cfg, 1, found("x.y.example.com")) == 0, "RT-3b suffix matches several labels below");
    check(which(cfg, 1, found("a.b.example.com")) == 1, "RT-3b the longest suffix wins, whatever the row order");
    check(which(cfg, 1, found("b.example.com")) == 0, "RT-3b 'b.example.com' is below 'example.com', not below itself");
    check(which(cfg, 1, found("example.com")) == -1, "B1 the suffix itself is not matched by a suffix row");
    check(which(cfg, 1, found("badexample.com")) == -1, "RT-3b a suffix must start at a label boundary");
    check(which(cfg, 1, found("example.com.evil")) == -1, "RT-3b a name that merely contains the suffix does not match");
    check(which(cfg, 1, found("A.EXAMPLE.COM")) == 0, "RT-3b suffix matching ignores case");
}

// Charlie's addition after approval (B1): users type "*.example.com"; the helper stores the bare form.
fn test_suffix_helper() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, tcprouter::Inspect.Sni);
    cfg.routes.push(tcprouter::sni_suffix_route(1, "*.example.com", tcprouter::Action.Close));   // 0
    cfg.routes.push(tcprouter::sni_suffix_route(1, "other.org", tcprouter::Action.Close));       // 1: bare form also fine
    check(which(cfg, 1, found("a.example.com")) == 0, "B1 '*.example.com' matches a name below it");
    check(which(cfg, 1, found("example.com")) == -1, "B1 '*.example.com' does not match the apex");
    check(which(cfg, 1, found("x.other.org")) == 1, "B1 the bare form 'other.org' works the same");
    var stored = false;
    match cfg.routes[0].on { SniSuffix s => { stored = s.name == "example.com"; }, _ => {} }
    check(stored, "B1 the stored form has no star");
}

fn test_exact_beats_suffix() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, tcprouter::Inspect.Sni);
    row_suffix(cfg, 1, "example.com");         // 0, listed first
    row_sni(cfg, 1, "api.example.com");        // 1
    check(which(cfg, 1, found("api.example.com")) == 1, "RT-3b exact beats a suffix listed before it");
    check(which(cfg, 1, found("web.example.com")) == 0, "RT-3b other names fall to the suffix");
}

// --- RT-3b and RT-3g: no name, not TLS -----------------------------------------------------------------

fn test_no_sni() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, tcprouter::Inspect.Sni);
    row_any(cfg, 1);                           // 0: listed first
    row_no_sni(cfg, 1);                        // 1
    row_sni(cfg, 1, "api.example.com");        // 2

    check(which(cfg, 1, no_sni()) == 1, "RT-3b a NoSni row beats Any when the client sent no name");
    check(which(cfg, 1, not_tls()) == 1, "RT-3g a client that is not TLS takes the NoSni row");
    check(which(cfg, 1, found("other.example.com")) == 0, "B2 a client with a name never takes a NoSni row");
    check(which(cfg, 1, found("api.example.com")) == 2, "RT-3b the exact row still wins");

    var no_any = tcprouter::Config { .. };
    listener(no_any, 1, tcprouter::Inspect.Sni);
    row_no_sni(no_any, 1);
    row_sni(no_any, 1, "api.example.com");
    check(which(no_any, 1, found("other.example.com")) == -1, "RT-3b with no Any row an unknown name matches nothing");
    check(which(no_any, 1, not_tls()) == 0, "RT-3g not-TLS with only a NoSni row takes it");

    var only_any = tcprouter::Config { .. };
    listener(only_any, 1, tcprouter::Inspect.Sni);
    row_any(only_any, 1);
    check(which(only_any, 1, not_tls()) == 0, "RT-3g not-TLS falls to Any when there is no NoSni row");
    check(which(only_any, 1, no_sni()) == 0, "RT-3b no name falls to Any when there is no NoSni row");
}

// --- B4 and RT-3f: hellos that are not routable ---------------------------------------------------------

fn test_unroutable() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, tcprouter::Inspect.Sni);
    row_sni(cfg, 1, "api.example.com");
    row_no_sni(cfg, 1);
    row_any(cfg, 1);
    check(which(cfg, 1, need_more()) == -1, "B4 NeedMore is not routable yet");
    check(which(cfg, 1, invalid()) == -1, "RT-3f an Invalid (for instance oversized) hello matches no route: closed");
}

// --- many routes ------------------------------------------------------------------------------------------

fn test_full_table() {
    var cfg = tcprouter::Config { .. };
    listener(cfg, 1, tcprouter::Inspect.Sni);
    for i in 255 { row_sni(cfg, 1, str("host", i, ".example.com")); }      // rows 0..254
    row_any(cfg, 1);                                                          // row 255: the table is full
    check(cfg.routes.len == 256, "the test fills all 256 route slots");
    var wrong: i64 = 0;
    for i in 255 {
        if which(cfg, 1, found(str("host", i, ".example.com"))) != i { wrong++; }
    }
    check(wrong == 0, "RT-3b every one of 255 distinct names finds its own row");
    check(which(cfg, 1, found("host255.example.com")) == 255, "RT-3b a 256th name falls to Any");

    // Names at the 253-byte limit.
    var long: u8[>..] = [];
    for i in 253 { long.push(if i % 60 == 59 { '.' } else { 'a' }); }
    var cfg2 = tcprouter::Config { .. };
    listener(cfg2, 1, tcprouter::Inspect.Sni);
    row_sni(cfg2, 1, long);
    check(which(cfg2, 1, found(long)) == 0, "RT-3b a 253-byte name matches");
}

fn main() {
    test_any();
    test_no_inspect();
    test_exact();
    test_suffix();
    test_suffix_helper();
    test_exact_beats_suffix();
    test_no_sni();
    test_unroutable();
    test_full_table();
    if failures > 0 {
        print(failures, " of ", checks, " checks FAILED");
        exit(1);
    }
    print("all ", checks, " checks passed");
}
