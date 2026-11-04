// Proves: RT-2c RT-2b   (RT-2c: slot indices from the kernel are range-checked; RT-2b at unit level: an event
//                        with an old generation never touches the connection now in that slot)
//
//     goose build --debug tests/unit/generation_test.goose && ./tests/unit/generation_test
//
// The kernel never sends an out-of-range slot, so the only way to test the check is to hand the dispatcher
// events it would not get. This test therefore reaches INTERNAL names (_dispatch_event, _new_connection, _pack_event_data, the
// worker's c_ fields) on purpose; it is the one test allowed to. It starts a real worker on a loopback port,
// gives it connections through socketpairs, and feeds events directly. tests/net/generation_test.py proves the
// same row over a million real sockets.
import tcprouter from "../..";

var checks: i64 = 0;
var failures: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    checks++;
    if !ok { failures++; print("FAIL: ", what); }
}

extern fn socketpair(domain: i32, kind: i32, protocol: i32, sv: i32[2]&) -> i32;
extern fn close(fd: i32) -> i32;

// A worker with one plain listener and one Any route that forwards to a port nobody listens on, so every
// connection it is given fails to connect and is closed again by the worker itself.
fn start_worker(w: tcprouter::Worker&) -> bool {
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr("127.0.0.1:41999") });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::target(["127.0.0.1:1"]) }));
    return tcprouter::start(w, cfg, 0);
}

// Gives the worker one connection and runs its event loop by hand until no connection is open.
fn run_until_closed(w: tcprouter::Worker&) {
    var events: tcprouter::c_EpollEvent[8] = [tcprouter::c_EpollEvent { 0, 0 }; 8];
    for round in 200 {
        if tcprouter::stats(w).open == 0 { return; }
        let n = tcprouter::c_epoll_wait(w._epoll_fd, events[0], 8, 20);
        for k in n { tcprouter::_dispatch_event(w, events[k].data, events[k].events); }
    }
}

fn give_connection(w: tcprouter::Worker&) {
    var sv: i32[2] = [0, 0];
    check(socketpair(1, 1, 0, sv) == 0, "a socketpair for a fake client");
    tcprouter::_new_connection(w, 0, sv[0]);
    close(sv[1]);
}

fn main() {
    var w = tcprouter::Worker { .. };
    if !start_worker(w) { print("cannot start the worker: ", w.error); exit(2); }

    give_connection(w);
    run_until_closed(w);
    var s = tcprouter::stats(w);
    check(s.accepted == 1 && s.open == 0, "the worker took one connection and closed it again");
    check(s.connect_failures == 1 && s.closed[5] == 1, "it was closed as ConnectFailed (the port has no listener)");
    // The worker's own loop may already have counted a stale event: the closed fake client and the failed connect
    // report in the same batch, and the second one arrives for a slot the first just freed. That is correct, so
    // everything below is measured against this baseline.
    let stale0 = s.stale_events;
    let bad0 = s.bad_events;
    check(bad0 == 0, "no bad events from a real connection");

    // The connection used slot 0 at generation 1; closing bumped it to 2.
    let CLIENT = tcprouter::_EVENT_KIND_CLIENT;
    let SERVER = tcprouter::_EVENT_KIND_SERVER;
    let IN = tcprouter::c_EPOLLIN;
    let OUT = tcprouter::c_EPOLLOUT;

    // RT-2b: events for a connection that is gone.
    tcprouter::_dispatch_event(w, tcprouter::_pack_event_data(CLIENT, 0, 1), IN);
    s = tcprouter::stats(w);
    check(s.stale_events == stale0 + 1, "an event with the old generation is counted as stale");
    tcprouter::_dispatch_event(w, tcprouter::_pack_event_data(SERVER, 0, 2), IN | OUT);
    s = tcprouter::stats(w);
    check(s.stale_events == stale0 + 2, "an event for a free slot, even at the current generation, is stale");

    // RT-2c: slot indices the table does not have.
    tcprouter::_dispatch_event(w, tcprouter::_pack_event_data(CLIENT, 7, 1), IN);
    tcprouter::_dispatch_event(w, tcprouter::_pack_event_data(SERVER, 1073741824, 1), IN);
    tcprouter::_dispatch_event(w, tcprouter::_pack_event_data(CLIENT, 4294967295, 1), IN | OUT);
    s = tcprouter::stats(w);
    check(s.bad_events == bad0 + 3, "slot numbers past the table are counted as bad, not used");

    // Event kinds that do not exist, and a listener index that does not exist, are bad too.
    tcprouter::_dispatch_event(w, tcprouter::_pack_event_data(9, 0, 2), IN);
    tcprouter::_dispatch_event(w, tcprouter::_pack_event_data(0, 0, 2), IN);
    tcprouter::_dispatch_event(w, tcprouter::_pack_event_data(tcprouter::_EVENT_KIND_LISTENER, 5, 0), IN);
    s = tcprouter::stats(w);
    check(s.bad_events == bad0 + 6, "unknown kinds and a listener index past the table are counted as bad");
    check(s.accepted == 1 && s.open == 0 && s.buffers_in_use == 0 && s.closed[5] == 1,
          "none of that changed anything else");

    // RT-2b at unit level: the next connection reuses slot 0 (generation 2). An event with generation 1, as if
    // from the old connection, must not close it or change it.
    give_connection(w);
    s = tcprouter::stats(w);
    check(s.accepted == 2 && s.open == 1, "a second connection is open (and uses the freed slot)");
    tcprouter::_dispatch_event(w, tcprouter::_pack_event_data(SERVER, 0, 1), tcprouter::c_EPOLLERR);
    tcprouter::_dispatch_event(w, tcprouter::_pack_event_data(CLIENT, 0, 1), tcprouter::c_EPOLLHUP);
    s = tcprouter::stats(w);
    check(s.open == 1 && s.stale_events == stale0 + 4, "events of the old generation did not touch the new connection");
    run_until_closed(w);
    s = tcprouter::stats(w);
    check(s.open == 0 && s.closed[5] == 2, "the new connection ended through its own events, as ConnectFailed");

    if failures > 0 { print(failures, " of ", checks, " checks FAILED"); exit(1); }
    print("all ", checks, " checks passed");
}
