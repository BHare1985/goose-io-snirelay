// The TLS ClientHello parser (design/04-sni.md). Pure: no sockets, no allocation, never aborts.
//
// What it is for: a listener with `inspect: Sni` holds the first bytes of a connection, asks
// parse_hello what they are, and routes on the answer. The bytes themselves are never consumed or
// changed here, so the backend later sees the client's handshake untouched.
//
// Behaviour follows the C proxy's sni_route/sni_lookup (c_proxy/proxy.c), with three deliberate
// differences, each also noted in design/04-sni.md:
//   * the C proxy returns a route index; this returns a Hello, and matching is a separate step;
//   * the C proxy closes a client whose first byte is not a TLS handshake; here that is NotTls, so
//     a plain-TCP client is routed by NoSni/Any (RT-3g);
//   * the C proxy accepts any bytes as a name; here a name is checked (see _parse_host_name).
namespace tcprouter;

import binary;

// What the first bytes of a connection are. Payloads are struct-like (`Found { name: … }`).
enum Hello {
    Found { name: u8[..253] },   // the SNI host name, lowercased, one trailing dot removed
    NoSni,                       // a complete, valid ClientHello without a server_name extension
    NotTls,                      // the first byte is not a TLS handshake record
    NeedMore { total: i64 },     // valid so far; call again once at least `total` bytes are buffered
    Invalid,                     // a TLS record that breaks the format (lengths, types, sizes)
}

// The longest ClientHello accepted (the handshake message, header included), and so the most
// bytes a caller ever needs for one record's payload. A TLS record carries at most this much.
let MAX_HELLO: i64 = 16384;

let TLS_HANDSHAKE: u8 = 0x16;      // record type
let HS_CLIENT_HELLO: u8 = 1;       // handshake message type
let EXT_SERVER_NAME: i64 = 0;
let NAME_TYPE_HOST: u8 = 0;

// Parses what has arrived so far, from byte 0 of the connection. Never consumes or changes it.
// A ClientHello that fits in one TLS record is parsed where it lies. One split over several
// records is reassembled into `scratch` (caller-owned; MAX_HELLO bytes always suffice, less is
// Invalid for a split hello). There is one form, because a split hello always needs scratch and a
// form without it would be a trap.
//
// NeedMore.total is the number of bytes at which the parser can make progress: a record header, or
// the end of the record it is reading. It always exceeds the bytes given.
fn parse_hello(bytes: const u8[:], scratch: u8[:]) -> Hello {
    if bytes.len == 0 { return Hello.NeedMore { total: 1 }; }
    if bytes[0] != TLS_HANDSHAKE { return Hello.NotTls; }

    var at = 0;       // where the record being read starts
    var held = 0;     // handshake bytes copied into scratch so far (split hello only)
    loop {
        let rest = bytes[at..];
        // Everything we can already see must look like a handshake record: type, major version 3.
        if rest.len >= 1 && rest[0] != TLS_HANDSHAKE { return Hello.Invalid; }
        if rest.len >= 2 && rest[1] != 3 { return Hello.Invalid; }
        if rest.len < 5 { return Hello.NeedMore { total: at + 5 }; }

        let rlen = (rest[3] as i64) << 8 | rest[4];
        if rlen == 0 || rlen > MAX_HELLO { return Hello.Invalid; }
        if rest.len < 5 + rlen { return Hello.NeedMore { total: at + 5 + rlen }; }
        let payload = rest[5..5 + rlen];

        // The common case: the whole handshake message is in the first record. Parse it in place.
        if at == 0 && payload.len >= 4 {
            if payload[0] != HS_CLIENT_HELLO { return Hello.Invalid; }
            let message = _handshake_message_length(payload);
            if message > MAX_HELLO { return Hello.Invalid; }
            if message <= payload.len { return _parse_client_hello_body(payload[4..message]); }
        }

        // Otherwise the message continues in the next record: collect the payloads in scratch.
        if held + payload.len > scratch.len { return Hello.Invalid; }
        scratch[held..held + payload.len].move_from(payload);
        held += payload.len;
        at += 5 + rlen;

        if held >= 1 && scratch[0] != HS_CLIENT_HELLO { return Hello.Invalid; }
        if held >= 4 {
            let message = _handshake_message_length(scratch[..held]);
            if message > MAX_HELLO { return Hello.Invalid; }
            if held >= message { return _parse_client_hello_body(scratch[4..message]); }
        }
    }
}

// Internal: the length of the whole handshake message (4-byte header + 24-bit body length).
// `head` holds at least the 4 header bytes.
fn _handshake_message_length(head: const u8[:]) -> i64 {
    return 4 + ((head[1] as i64) << 16 | (head[2] as i64) << 8 | head[3]);
}

// Internal: the ClientHello body (RFC 8446 section 4.1.2):
//   legacy_version(2) random(32) session_id<1> cipher_suites<2> compression_methods<1> extensions<2>
// Every read is checked: a length that runs past the body is Invalid, never a read past it.
fn _parse_client_hello_body(body: const u8[:]) -> Hello {
    var r = binary::reader(body);
    if !binary::skip(r, 2 + 32) { return Hello.Invalid; }

    let session_len, ok_s = binary::read_u8(r);
    if !ok_s || !binary::skip(r, session_len) { return Hello.Invalid; }
    let suites_len, ok_c = binary::read_u16be(r);
    if !ok_c || !binary::skip(r, suites_len) { return Hello.Invalid; }
    let compression_len, ok_m = binary::read_u8(r);
    if !ok_m || !binary::skip(r, compression_len) { return Hello.Invalid; }

    // Hellos from before TLS 1.0 extensions end here: valid, and no name.
    if r.pos == body.len { return Hello.NoSni; }

    let ext_len, ok_e = binary::read_u16be(r);
    var exts, ok_x = binary::subreader(r, ext_len);
    if !ok_e || !ok_x { return Hello.Invalid; }

    while exts.pos < exts.data.len {
        let kind, ok_k = binary::read_u16be(exts);
        let len, ok_l = binary::read_u16be(exts);
        var ext, ok_d = binary::subreader(exts, len);
        if !ok_k || !ok_l || !ok_d { return Hello.Invalid; }
        if kind == EXT_SERVER_NAME { return _parse_server_name_list(ext); }
    }
    return Hello.NoSni;
}

// Internal: the body of a server_name extension (RFC 6066 section 3): list<2> { name_type(1) name<2> }.
// The first host_name entry wins; entries of other types are skipped.
fn _parse_server_name_list(ext: binary::Reader&) -> Hello {
    let list_len, ok_n = binary::read_u16be(ext);
    var list, ok_l = binary::subreader(ext, list_len);
    if !ok_n || !ok_l { return Hello.Invalid; }

    while list.pos < list.data.len {
        let name_type, ok_t = binary::read_u8(list);
        let name_len, ok_w = binary::read_u16be(list);
        let name, ok_b = binary::read_bytes(list, name_len);
        if !ok_t || !ok_w || !ok_b { return Hello.Invalid; }
        if name_type == NAME_TYPE_HOST { return _parse_host_name(name); }
    }
    return Hello.NoSni;
}

// Internal: the rules for the name itself (design/04-sni.md): ASCII letters, digits, '.' and '-'
// only; lowercased; one trailing dot dropped; at most 253 bytes; an empty name is NoSni.
fn _parse_host_name(raw: const u8[:]) -> Hello {
    if raw.len == 0 { return Hello.NoSni; }
    var name = raw;
    if name[name.len - 1] == '.' { name = name[..name.len - 1]; }
    if name.len == 0 || name.len > 253 { return Hello.Invalid; }

    var found = Hello.Found { name: [] };
    for c in name {
        let lower = if c >= 'A' && c <= 'Z' { c + 32 } else { c };
        let allowed = (lower >= 'a' && lower <= 'z') || (lower >= '0' && lower <= '9')
                      || lower == '.' || lower == '-';
        if !allowed { return Hello.Invalid; }
        found.name.push(lower);
    }
    return found;
}
