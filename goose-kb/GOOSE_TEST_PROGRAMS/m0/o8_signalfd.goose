// M0 O-8: SIGTERM/SIGINT without function pointers: block them, read them from a signalfd.
// sigset_t is an opaque 128-byte blob here (glibc x86-64/arm64); the C functions fill it for us.
// Worker threads started AFTER blocking inherit the mask, so only the signalfd ever sees the signal.
//   ../../bin/goose build o8_signalfd.goose && ./o8_signalfd
extern fn sigemptyset(set: u8[128]&) -> i32;
extern fn sigaddset(set: u8[128]&, signo: i32) -> i32;
extern fn sigprocmask(how: i32, set: const u8[128]&, old: u8[128]&) -> i32;
extern fn signalfd(fd: i32, mask: const u8[128]&, flags: i32) -> i32;
extern fn kill(pid: i32, sig: i32) -> i32;
extern fn getpid() -> i32;
extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

let SIGINT = 2;
let SIGTERM = 15;
let SIG_BLOCK = 0;

thread_fn sleeper() {
    // If the mask were not inherited, SIGTERM delivered to this thread would kill the process (default action).
    var i = 0;
    while i < 200 { i++; }
}

fn main() {
    var set: u8[128] = [0; 128];
    var old: u8[128] = [0; 128];
    sigemptyset(set);
    sigaddset(set, SIGTERM);
    sigaddset(set, SIGINT);
    assert(sigprocmask(SIG_BLOCK, set, old) == 0);
    let sfd = signalfd(-1, set, 0);
    assert(sfd >= 0);

    let t = thread_spawn(sleeper);
    kill(getpid(), SIGTERM);                       // would terminate the process if not blocked
    var info: u8[128] = [0; 128];                  // struct signalfd_siginfo is 128 bytes; ssi_signo is the first u32
    let n = read(sfd, info[0], 128);
    let signo = info[0] as i64 | (info[1] as i64 << 8);
    print("read ", n, " bytes from signalfd; ssi_signo = ", signo, " (15 = SIGTERM)");
    thread_wait(t);
}
