// Proves: — (no requirement row. M0 deliverable: the package builds, its C layer links, and the
// struct Goose lays out matches the one C fills in.)
//
//     goose build --debug tests/unit/package_smoke_test.goose && ./tests/unit/package_smoke_test
//
// Imports the package the way a stranger would, with the sources it came from.
import tcprouter from "../..";

var checks: i64 = 0;
var failures: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    checks++;
    if !ok { failures++; print("FAIL: ", what); }
}

extern fn pipe2(fds: i32[2]&, flags: i32) -> i32;
extern fn write(fd: i32, buf: const u8&, n: u64) -> i64;

fn main() {
    // C layer: the clock moves forward.
    let t0 = tcprouter::router_boottime_milliseconds();
    check(t0 > 0, "CLOCK_BOOTTIME is positive");

    // Layout: Goose's EpollEvent is 12 packed bytes, like c_epoll_event in src/c_sys.c.
    let one: tcprouter::router_EpollEvent[1] = [tcprouter::router_EpollEvent { 0, 0 }];
    check(bytes_of(one).len == 12, "EpollEvent is 12 bytes");

    // C layer: epoll round trip carries the 64-bit user data intact.
    var p: i32[2] = [0, 0];
    check(pipe2(p, 0) == 0, "pipe2");
    let ep = tcprouter::router_epoll_create();
    check(ep >= 0, "epoll_create");
    let EPOLLIN: u32 = 1;
    let EPOLL_CTL_ADD: i32 = 1;
    let tag: u64 = 0xDEADBEEF12345678;
    check(tcprouter::router_epoll_control(ep, EPOLL_CTL_ADD, p[0], EPOLLIN, tag) == 0, "epoll_ctl add");
    let msg = "x";
    write(p[1], msg[0], 1);
    var evs: tcprouter::router_EpollEvent[4] = [tcprouter::router_EpollEvent { 0, 0 }; 4];
    let n = tcprouter::router_epoll_wait(ep, evs[0], 4, 1000);
    check(n == 1, "epoll_wait reports one event");
    check(evs[0].events == EPOLLIN && evs[0].data == tag, "event data survives the C copy");

    if failures > 0 { print(failures, " of ", checks, " checks FAILED"); exit(1); }
    print("all ", checks, " checks passed");
}
