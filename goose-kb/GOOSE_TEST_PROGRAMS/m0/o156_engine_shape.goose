// M0 O-1, O-5, O-6 (+ root-struct finding): the shape of tcprouter::serve.
//   ../../bin/goose build o156_engine_shape.goose && ./o156_engine_shape
//
// O-1: serve<P, F> calls policy functions on its generic parameter with UFCS (`p.pick(7)`),
//      resolved at compile time in the *type's* namespace. Two policy types, two namespaces.
// O-5: an enum with struct-like payloads, one holding a slice; `match` binds payloads.
// O-6: the block passed to serve receives the worker by reference and calls library functions with it.
// Root struct: a Worker with several growable tables must be a `root struct`, which cannot be returned by value.

struct Conn { slot: u32, gen: u32 }

enum Event {
    Opened { conn: Conn, tag: u16 },
    Data { conn: Conn, bytes: const u8[:] },
    Closed { conn: Conn },
    Tick { now_ms: i64 },
}

struct Slot { gen: u32, live: bool }

root struct Worker {
    slots: Slot[>..] = [],
    free: u32[>..<] = [],
    scratch: u8[>..] = [],
    sent: i64 = 0,
}

// A library function the block may call with the worker it was handed.
fn send(w: Worker&, c: Conn, bytes: const u8[:]) -> bool {
    w.sent += bytes.len;
    w.scratch.append(bytes);
    return true;
}

// Two policies in two namespaces, sharing no interface declaration.
struct pa::Policy { next: i64 }
fn pa::pick(p: pa::Policy&, route: u16) -> i64 { p.next += 1; return p.next * 100 + route; }

struct pb::Policy { fixed: i64 }
fn pb::pick(p: pb::Policy&, route: u16) -> i64 { return p.fixed; }

// The engine: generic over the policy P and the handler block F.
fn serve<P, F>(w: Worker&, p: P&) {
    let c = Conn { 1, 0 };
    // A variant literal has the variant's own type (Event.Opened); annotate to get an Event to match on.
    let e1: Event = Event.Opened { conn: c, tag: 7 };
    F(w, e1);
    let e2: Event = Event.Data { conn: c, bytes: "hello" };
    F(w, e2);
    let e3: Event = Event.Tick { now_ms: p.pick(7) };    // UFCS on the generic parameter
    F(w, e3);
    let e4: Event = Event.Closed { conn: c };
    F(w, e4);
}

fn run<P>(name: const u8[:], p: P&) {
    var w = Worker { .. };                           // a root is constructed where it lives
    var log: u8[>..] = [];
    serve(w, p) { w, ev =>
        match ev {
            Opened o => { format(log, "open(", o.conn.slot, ",tag ", o.tag, ") "); },
            Data d => { send(w, d.conn, d.bytes); format(log, "data(", d.bytes.len, ") "); },
            Tick t => { format(log, "tick(", t.now_ms, ") "); },
            Closed c => { format(log, "closed "); },
        }
    };
    print(name, ": ", log, "sent=", w.sent, " scratch=", w.scratch);
}

fn main() {
    var a = pa::Policy { 0 };
    var b = pb::Policy { 99 };
    run("policy A", a);
    run("policy B", b);
}
