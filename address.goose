// Socket addresses as people write them (design/02-api.md section 2): "10.0.0.5:5432", "[::1]:443".
// No host names: the program resolves names and gives us addresses (design/01-scope.md).
namespace tcprouter;

import std;

// An address in the form the sockets want: 4 or 16 bytes in network order, and a port.
// Internal: the engine builds its sockaddr from this.
struct router_ParsedAddress { v6: bool, ip: u8[16], port: u16 }

// Parses "ip:port" or "[ipv6]:port". False for anything else, including host names, a missing or
// zero port, a port over 65535, and surrounding spaces. Never aborts.
fn router_parse_address(text: const u8[:], out: router_ParsedAddress&) -> bool {
    if text.len == 0 { return false; }
    var host: const u8[:] = text;
    var port: const u8[:] = text;
    if text[0] == '[' {
        let close = find(text, "]");
        if close < 0 || close + 1 >= text.len || text[close + 1] != ':' { return false; }
        host = text[1..close];
        port = text[close + 2..];
        out.v6 = true;
        if !router_parse_ipv6(host, out.ip) { return false; }
    } else {
        let colon = find(text, ":");
        if colon < 0 { return false; }
        host = text[..colon];
        port = text[colon + 1..];
        out.v6 = false;
        if !router_parse_ipv4(host, out.ip) { return false; }
    }
    return router_parse_port(port, out.port);
}

// Internal: 1 to 5 decimal digits, 1..65535.
fn router_parse_port(text: const u8[:], out: u16&) -> bool {
    if text.len == 0 || text.len > 5 { return false; }
    var n = 0;
    for c in text {
        if c < '0' || c > '9' { return false; }
        n = n * 10 + (c - '0');
    }
    if n < 1 || n > 65535 { return false; }
    out = n as u16;
    return true;
}

// Internal: a.b.c.d, each 0..255, 1 to 3 digits, no leading zeros (they look like octal).
fn router_parse_ipv4(text: const u8[:], out: u8[16]&) -> bool {
    var part = 0;        // which of the four numbers
    var value = 0;
    var digits = 0;
    for i in text.len + 1 {
        let at_end = i == text.len;
        if at_end || text[i] == '.' {
            if digits == 0 || part > 3 { return false; }
            out[part] = value as u8;
            part++;
            value = 0;
            digits = 0;
        } else {
            let c = text[i];
            if c < '0' || c > '9' { return false; }
            if digits == 1 && value == 0 { return false; }          // leading zero
            value = value * 10 + (c - '0');
            digits++;
            if digits > 3 || value > 255 { return false; }
        }
    }
    return part == 4;
}

fn router_hex_digit_value(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

// Internal: colon-hex groups of 1 to 4 digits, at most one "::" standing for one or more zero groups.
fn router_parse_ipv6(text: const u8[:], out: u8[16]&) -> bool {
    if text.len < 2 { return false; }
    var groups: u16[8] = [0; 8];
    var head: i64 = 0;                 // groups before "::"
    var tail_start: i64 = 8;           // index in groups where the part after "::" begins
    var seen_gap = false;
    var tail: u16[8] = [0; 8];
    var tail_count: i64 = 0;
    var i = 0;
    if text[0] == ':' {
        if text[1] != ':' { return false; }
        seen_gap = true;
        i = 2;
    }
    while i < text.len {
        // one group
        var v = 0;
        var digits = 0;
        while i < text.len && text[i] != ':' {
            let h = router_hex_digit_value(text[i]);
            if h < 0 || digits == 4 { return false; }
            v = v * 16 + h;
            digits++;
            i++;
        }
        if digits == 0 { return false; }
        if seen_gap {
            if tail_count >= 8 { return false; }
            tail[tail_count] = v as u16;
            tail_count++;
        } else {
            if head >= 8 { return false; }
            groups[head] = v as u16;
            head++;
        }
        if i == text.len { break; }
        i++;                                           // the ':'
        if i < text.len && text[i] == ':' {            // "::"
            if seen_gap { return false; }
            seen_gap = true;
            i++;
            if i == text.len { break; }                // trailing "::"
        } else if i == text.len {
            return false;                              // a trailing single ':'
        }
    }
    if seen_gap {
        if head + tail_count > 7 { return false; }    // "::" stands for at least one group
        tail_start = 8 - tail_count;
        for k in tail_count { groups[tail_start + k] = tail[k]; }
    } else if head != 8 {
        return false;
    }
    for g in 8 {
        out[g * 2] = (groups[g] >> 8) as u8;
        out[g * 2 + 1] = groups[g] as! u8;          // the low byte: truncation is the point
    }
    return true;
}
