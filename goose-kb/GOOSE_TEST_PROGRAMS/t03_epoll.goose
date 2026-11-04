// t03: epoll via extern fn. struct epoll_event is packed on x86-64 (12 bytes: u32 events, u64 data),
// which is exactly what a default (packed) Goose struct gives. Non-blocking via SOCK_NONBLOCK flags,
// because fcntl()/ioctl() are variadic and cannot be bound.
//   goose build t03_epoll.goose && ./t03_epoll
struct EpollEvent { events: u32, data: u64 }

extern fn socketpair(domain: i32, kind: i32, protocol: i32, sv: i32[2]&) -> i32;
extern fn epoll_create1(flags: i32) -> i32;
extern fn epoll_ctl(epfd: i32, op: i32, fd: i32, ev: EpollEvent&) -> i32;
extern fn epoll_wait(epfd: i32, events: EpollEvent&, max: i32, timeout_ms: i32) -> i32;
extern fn send(fd: i32, buf: const u8&, len: u64, flags: i32) -> i64;
extern fn recv(fd: i32, buf: u8&, len: u64, flags: i32) -> i64;
extern fn close(fd: i32) -> i32;

let SOCK_STREAM = 1;
let SOCK_NONBLOCK = 0x800;
let EPOLL_CTL_ADD = 1;
let EPOLLIN: u32 = 1;
let EAGAIN_PROBE = 0;

fn main() {
    assert(sizeof_check() == 12);
    var sv: i32[2] = [0, 0];
    assert(socketpair(1, SOCK_STREAM | SOCK_NONBLOCK, 0, sv) == 0);
    let ep = epoll_create1(0);
    var ev = EpollEvent { EPOLLIN, sv[1] as u64 };
    assert(epoll_ctl(ep, EPOLL_CTL_ADD, sv[1], ev) == 0);

    var evs: EpollEvent[8] = [EpollEvent { 0, 0 }; 8];
    print("nothing yet: ", epoll_wait(ep, evs[0], 8, 0));

    let msg = "ping";
    send(sv[0], msg[0], msg.len as u64, 0);
    let n = epoll_wait(ep, evs[0], 8, 1000);
    print("ready: ", n, " fd=", evs[0].data, " events=", evs[0].events);

    var buf: u8[64] = [0; 64];
    let got = recv(sv[1], buf[0], buf.len as u64, 0);
    print("recv ", got, ": ", buf[..got]);
    let again = recv(sv[1], buf[0], buf.len as u64, 0);
    print("second recv on empty nonblocking socket: ", again, " (-1 = EAGAIN)");
    close(sv[0]); close(sv[1]); close(ep);
}

// Goose has no sizeof; bytes_of on an array of one gives the packed element size.
fn sizeof_check() -> i64 {
    let one: EpollEvent[1] = [EpollEvent { 0, 0 }];
    return bytes_of(one).len;
}
