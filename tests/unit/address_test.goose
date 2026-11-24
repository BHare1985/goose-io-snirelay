// Proves: RT-1c   (supporting: the address parser behind check() and, later, the engine's sockaddr)
//
//     goose build --debug tests/unit/address_test.goose && ./tests/unit/address_test
//
// config_test proves check() accepts and rejects the right texts. This proves the BYTES a good text
// parses to, since a wrong byte here binds the wrong address and no check would notice.
import tcprouter from "../..";
import goose_io from "github.com/BHare1985/goose-io@v0.4";

var checks: i64 = 0;
var failures: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    checks++;
    if !ok { failures++; print("FAIL: ", what); }
}

fn v4(text: const u8[:], a: u8, b: u8, c: u8, d: u8, port: u16) -> bool {
    var p = tcprouter::_ParsedAddress { false, [0; 16], 0 };
    let ok = tcprouter::_parse_address(text, p);
    return ok && !p.v6 && p.ip[0] == a && p.ip[1] == b && p.ip[2] == c && p.ip[3] == d && p.port == port;
}

// The 16 bytes of an IPv6 address given as eight 16-bit groups.
fn v6(text: const u8[:], g: u16[8], port: u16) -> bool {
    var p = tcprouter::_ParsedAddress { false, [0; 16], 0 };
    let ok = tcprouter::_parse_address(text, p);
    if !ok || !p.v6 || p.port != port { return false; }
    for i in 8 {
        if p.ip[i * 2] != (g[i] >> 8) as u8 || p.ip[i * 2 + 1] != (g[i] & 0xff) as u8 { return false; }
    }
    return true;
}

fn rejected(text: const u8[:]) -> bool {
    var p = tcprouter::_ParsedAddress { false, [0; 16], 0 };
    return !tcprouter::_parse_address(text, p);
}

fn main() {
    check(v4("0.0.0.0:80", 0, 0, 0, 0, 80), "0.0.0.0:80");
    check(v4("127.0.0.1:65535", 127, 0, 0, 1, 65535), "127.0.0.1:65535");
    check(v4("10.20.30.40:1", 10, 20, 30, 40, 1), "10.20.30.40:1");
    check(v4("255.255.255.255:443", 255, 255, 255, 255, 443), "255.255.255.255:443");

    check(v6("[::]:8080", [0, 0, 0, 0, 0, 0, 0, 0], 8080), "[::]");
    check(v6("[::1]:443", [0, 0, 0, 0, 0, 0, 0, 1], 443), "[::1]");
    check(v6("[2001:db8::1]:5432", [0x2001, 0xdb8, 0, 0, 0, 0, 0, 1], 5432), "[2001:db8::1]");
    check(v6("[1:2:3:4:5:6:7:8]:9", [1, 2, 3, 4, 5, 6, 7, 8], 9), "eight groups, no ::");
    check(v6("[1:2:3:4:5:6:7::]:9", [1, 2, 3, 4, 5, 6, 7, 0], 9), "trailing :: for one group");
    check(v6("[::2:3:4:5:6:7:8]:9", [0, 2, 3, 4, 5, 6, 7, 8], 9), "leading :: for one group");
    check(v6("[FE80::ABCD]:9", [0xfe80, 0, 0, 0, 0, 0, 0, 0xabcd], 9), "capital hex digits");
    check(v6("[1::8]:9", [1, 0, 0, 0, 0, 0, 0, 8], 9), ":: in the middle");

    for bad in ["[1::2::3]:1", "[1:2:3:4:5:6:7:8:9]:1", "[1:2:3:4:5:6:7:8::]:1", "[:1]:1", "[1:]:1", "[:::]:1",
                "[12345::]:1", "[1:2:3:4:5:6:7]:1", "[::g]:1", "[]:1", "[:]:1",
                "1.2.3.4.5:1", "1.2.3:1", "1..3.4:1", "01.2.3.4:1", "1.2.3.4:01x", "1.2.3.4:-1", "1.2.3.4 :1"] {
        check(rejected(bad), str("rejected: ", bad));
    }
    if failures > 0 { print(failures, " of ", checks, " checks FAILED"); exit(1); }
    print("all ", checks, " checks passed");
}
