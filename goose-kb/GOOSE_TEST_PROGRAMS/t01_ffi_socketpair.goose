// t01: raw libc sockets through `extern fn`, with Goose-owned buffers.
// Goal: find out how a TCP proxy would talk to the kernel, since stdlib `os`
// has no networking. Uses socketpair() so the test needs no ports.
//
//   goose build t01_ffi_socketpair.goose && ./t01_ffi_socketpair

// The string after `=` is the C symbol. Pointers to Goose memory are `T&`.
extern fn socketpair(domain: i32, kind: i32, protocol: i32, sv: i32[2]&) -> i32;
extern fn send(fd: i32, buf: const u8&, len: u64, flags: i32) -> i64;
extern fn recv(fd: i32, buf: u8&, len: u64, flags: i32) -> i64;
extern fn close(fd: i32) -> i32;

let AF_UNIX = 1;
let SOCK_STREAM = 1;

// Send all of `data`; false on error. `data[0]` is only legal for a non-empty slice.
fn send_all(fd: i32, data: const u8[:]) -> bool {
    var off = 0;
    while off < data.len {
        let rest = data[off..];
        let n = send(fd, rest[0], rest.len as u64, 0);
        if n <= 0 { return false; }
        off += n;
    }
    return true;
}

// Receive up to `max` bytes and append them to `out`. Returns bytes read, or -1.
// The scratch is a fixed array so it needs no data stack.
fn recv_into(fd: i32, out: u8[>..]&, max: i64) -> i64 {
    var chunk: u8[4096] = [0; 4096];
    let want = if max < chunk.len { max } else { chunk.len };
    let n = recv(fd, chunk[0], want as u64, 0);
    if n > 0 { out.append(chunk[..n]); }
    return n;
}

fn main() {
    var sv: i32[2] = [0, 0];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);

    var msg: u8[>..] = [];
    format(msg, "hello through the kernel, ", 42);
    assert(send_all(sv[0], msg));

    var got: u8[>..] = [];
    let n = recv_into(sv[1], got, 1024);
    print("received ", n, " bytes: ", got);

    close(sv[0]);
    let eof = recv_into(sv[1], got, 1024);
    print("after close recv returns ", eof);
    close(sv[1]);
}
