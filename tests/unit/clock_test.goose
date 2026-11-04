// Proves: RT-6c   (deadlines are on CLOCK_BOOTTIME)
//
//     goose build --debug tests/unit/clock_test.goose && ./tests/unit/clock_test
//
// A deadline that must survive a suspend has to be measured on CLOCK_BOOTTIME, which keeps counting while the machine sleeps;
// CLOCK_MONOTONIC stops. /proc/uptime is defined as the time since boot including suspend, i.e. CLOCK_BOOTTIME, so it is an
// independent witness for the clock the engine reads (c_boottime_ms, the one every deadline and timeout uses).
import tcprouter from "../..";
import std;
import os;

var checks: i64 = 0;
var failures: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    checks++;
    if !ok { failures++; print("FAIL: ", what); }
}

// /proc/uptime holds "seconds.hundredths idle.hundredths": the first number, in milliseconds.
fn uptime_ms() -> i64 {
    var text: u8[>..] = [];
    if !read_file("/proc/uptime", text) { return -1; }
    let dot = find(text, ".");
    let space = find(text, " ");
    let secs, ok1 = parse_int(text[..dot]);
    let hundredths, ok2 = parse_int(text[dot + 1..space]);
    if !ok1 || !ok2 { return -1; }
    return secs * 1000 + hundredths * 10;
}

fn main() {
    var previous: i64 = 0;
    var worst: i64 = 0;
    for i in 20 {
        let before = uptime_ms();
        let engine = tcprouter::c_boottime_ms();
        let after = uptime_ms();
        check(before > 0 && engine > 0, "both clocks can be read");
        // /proc/uptime has 10 ms resolution: the engine's reading must fall inside [before, after] widened by that.
        let off = if engine < before - 10 { before - 10 - engine } else if engine > after + 10 { engine - after - 10 } else { 0 };
        if off > worst { worst = off; }
        check(engine >= previous, "the engine's clock never goes backwards");
        previous = engine;
        sleep_ms(25);
    }
    check(worst == 0, "the engine's clock agrees with /proc/uptime (CLOCK_BOOTTIME) to within its 10 ms resolution");
    if failures > 0 { print(failures, " of ", checks, " checks FAILED"); exit(1); }
    print("all ", checks, " checks passed");
}
