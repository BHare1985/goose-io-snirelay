// t02: a minimal TCP forwarding proxy in Goose, libc sockets via `extern fn`,
// one accept loop on main and a pool of `thread_fn` workers fed by a typed queue.
//
//   goose build t02_tcp_proxy.goose
//   ./t02_tcp_proxy <listen_port> <upstream_port> [workers]
//
// Design notes (verified by running, see RESULTS.md):
//  * Threads share no memory, so the only thing crossing is a flat `Conn { fd }`.
//  * `qget<Conn>()` in N workers is a work queue: one global queue per type.
//  * Buffers are fixed arrays, so they live on the native stack: no data stack.

import std;
import os;

// ---- libc, bound by C symbol name -------------------------------------------------

struct SockAddrIn { family: u16, port: u16, addr: u32, zero: u8[8] }   // 16 bytes, as in C
struct Pollfd { fd: i32, events: i16, revents: i16 }                   // 8 bytes, as in C

extern fn socket(domain: i32, kind: i32, protocol: i32) -> i32;
extern fn setsockopt(fd: i32, level: i32, name: i32, val: const i32&, len: u32) -> i32;
extern fn bind(fd: i32, addr: const SockAddrIn&, len: u32) -> i32;
extern fn listen(fd: i32, backlog: i32) -> i32;
extern fn accept(fd: i32, addr: SockAddrIn&, len: u32&) -> i32;
extern fn connect(fd: i32, addr: const SockAddrIn&, len: u32) -> i32;
extern fn send(fd: i32, buf: const u8&, len: u64, flags: i32) -> i64;
extern fn recv(fd: i32, buf: u8&, len: u64, flags: i32) -> i64;
extern fn poll(fds: Pollfd&, nfds: u64, timeout_ms: i32) -> i32;
extern fn shutdown(fd: i32, how: i32) -> i32;
extern fn close(fd: i32) -> i32;

let AF_INET = 2;
let SOCK_STREAM = 1;
let SOL_SOCKET = 1;
let SO_REUSEADDR = 2;
let MSG_NOSIGNAL = 0x4000;
let POLLIN: i16 = 1;
let POLLERR_HUP_NVAL: i16 = 0x8 | 0x10 | 0x20;
let SHUT_WR = 1;

// ---- helpers ----------------------------------------------------------------------

fn htons(p: u16) -> u16 { (p << 8) | (p >> 8) }

fn loopback(port: i64) -> SockAddrIn {
    // 127.0.0.1 in network order, read as a little-endian u32: 0x0100007f.
    SockAddrIn { family: 2, port: htons(port as u16), addr: 0x0100007f, zero: [0; 8] }
}

fn send_all(fd: i32, data: const u8[:]) -> bool {
    var off = 0;
    while off < data.len {
        let rest = data[off..];
        let n = send(fd, rest[0], rest.len as u64, MSG_NOSIGNAL);
        if n <= 0 { return false; }
        off += n;
    }
    return true;
}

// ---- the work item ----------------------------------------------------------------

struct Conn { fd: i32, upstream_port: i32 }

// Forward bytes both ways. A side that reaches EOF is half-closed on the other
// socket (SHUT_WR) and no longer polled; we finish when both sides are done.
// Note: send_all blocks, so two peers that both stop reading while we send can
// deadlock. A production proxy would use non-blocking sockets and POLLOUT.
fn relay(a: i32, b: i32) {
    var buf: u8[16384] = [0; 16384];
    var fds: Pollfd[2] = [Pollfd { a, POLLIN, 0 }, Pollfd { b, POLLIN, 0 }];
    let socks: i32[2] = [a, b];     // fds[i].fd is overwritten with -1 at EOF, so keep the real ones
    var live = 2;
    while live > 0 {
        fds[0].revents = 0;
        fds[1].revents = 0;
        // poll ignores entries whose fd is negative
        let ready = poll(fds[0], 2, -1);
        if ready <= 0 { return; }
        for i in 2 {
            if fds[i].revents == 0 { continue; }
            let src = socks[i];
            let dst = socks[1 - i];
            let n = recv(src, buf[0], buf.len as u64, 0);
            if n <= 0 {
                shutdown(dst, SHUT_WR);
                fds[i].fd = -1;
                live--;
            } else if !send_all(dst, buf[..n]) {
                return;
            }
        }
    }
}

thread_fn worker(id: i64) {
    loop {
        let c = qget<Conn>();
        guard c.fd >= 0 else { break; }           // fd -1 is the stop message
        let up = socket(AF_INET, SOCK_STREAM, 0);
        let addr = loopback(c.upstream_port);
        if up >= 0 && connect(up, addr, 16) == 0 {
            relay(c.fd, up);
        } else {
            write_stderr(str("worker ", id, ": upstream connect failed\n"));
        }
        if up >= 0 { close(up); }
        close(c.fd);
    }
}

fn die(msg: const u8[:]) {
    write_stderr(str(msg, "\n"));
    exit(1);
}

fn arg_int(i: i64, dflt: i64) -> i64 {
    if i >= arg_count() { return dflt; }
    var s: u8[>..] = [];
    arg(i, s);
    let v, ok = parse_int(s);
    if ok { v } else { dflt }
}

fn main() {
    let listen_port = arg_int(1, 0);
    let upstream_port = arg_int(2, 0);
    let nworkers = arg_int(3, 4);
    if listen_port <= 0 || upstream_port <= 0 { die("usage: proxy <listen_port> <upstream_port> [workers]"); }

    let ls = socket(AF_INET, SOCK_STREAM, 0);
    if ls < 0 { die("socket failed"); }
    let one: i32 = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, one, 4);
    let la = loopback(listen_port);
    if bind(ls, la, 16) != 0 { die("bind failed"); }
    if listen(ls, 128) != 0 { die("listen failed"); }

    qlimit<Conn>(64);    // refuse work rather than queue without end
    var ids: i64[>..] = [];
    for i in nworkers { ids.push(thread_spawn(worker, i)); }
    print("proxy listening on ", listen_port, " -> ", upstream_port, " with ", nworkers, " workers");

    loop {
        var peer = SockAddrIn { 0, 0, 0, [0; 8] };
        var plen: u32 = 16;
        let fd = accept(ls, peer, plen);
        if fd < 0 { continue; }
        if !qput(Conn { fd: fd, upstream_port: upstream_port as i32 }) {
            close(fd);   // queue full: shed load
        }
    }
}
