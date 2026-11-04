// M0 O-3: can the kernel write into a growable array that grows afterwards?
// A buffer pool is one u8[>..] sized once; buffers are sub-slices. We also grow it AFTER taking a
// reference and let the kernel write through the OLD reference.
//   ../../bin/goose build o3_stable_buffers.goose && ./o3_stable_buffers
import std;
extern fn socketpair(domain: i32, kind: i32, protocol: i32, sv: i32[2]&) -> i32;
extern fn send(fd: i32, buf: const u8&, len: u64, flags: i32) -> i64;
extern fn recv(fd: i32, buf: u8&, len: u64, flags: i32) -> i64;

let BUF = 16384;

fn main() {
    var sv: i32[2] = [0, 0];
    assert(socketpair(1, 1, 0, sv) == 0);

    var pool: u8[>..] = [];
    pool.resize(4 * BUF, 0);                       // 4 buffers, allocated once at start
    let first .= pool[0];                          // a reference into the pool
    // Grow the pool by 64 MB with append: nothing moves, so `first` stays valid.
    // (`resize` is rejected while `first` lives: "cannot resize pool while first is still used" because resize may shrink.)
    let chunk: u8[4096] = [0; 4096];
    for i in 16384 { pool.append(chunk); }

    let msg = "kernel wrote through an old reference";
    send(sv[0], msg[0], msg.len as u64, 0);
    let n = recv(sv[1], first, BUF as u64, 0);     // pass the OLD reference to the kernel
    print("recv ", n, ": ", pool[..n]);
    assert(pool[..n] == msg);

    // Buffers as slices handed out by index, no per-buffer allocation.
    let buf2 = pool[BUF..2 * BUF];
    send(sv[0], msg[0], 5, 0);
    let n2 = recv(sv[1], buf2[0], buf2.len as u64, 0);
    print("buffer 1 got ", n2, ": ", buf2[..n2], "; pool len ", pool.len);
}
