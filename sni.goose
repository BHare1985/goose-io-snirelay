// The TLS ClientHello parser (design/04-sni.md). Pure: no sockets, no allocation, never aborts.
// STUB: every function exists with its final signature and does nothing useful, so tests compile
// and fail (red gate for RT-3e, RT-3f).
namespace tcprouter;

// What the first bytes of a connection are. Payloads are struct-like (`Found { name: … }`).
enum Hello {
    Found { name: u8[..253] },   // the SNI host name, lowercased, one trailing dot removed
    NoSni,                       // a complete, valid ClientHello without a server_name extension
    NotTls,                      // the first byte is not a TLS handshake record
    NeedMore { total: i64 },     // valid so far; call again once at least `total` bytes are buffered
    Invalid,                     // a TLS record that breaks the format (lengths, types, sizes)
}

// The longest ClientHello accepted, and so the most bytes a caller ever needs to hold for one.
let MAX_HELLO: i64 = 16384;

// Parses what has arrived so far, from byte 0 of the connection. Never consumes or changes it.
// A ClientHello split over several TLS records needs the form with `scratch`.
fn parse_hello(bytes: const u8[:]) -> Hello {
    return Hello.Invalid;
}

// As above; a ClientHello split over several records is reassembled into `scratch`
// (caller-owned; MAX_HELLO bytes always suffice).
fn parse_hello(bytes: const u8[:], scratch: u8[:]) -> Hello {
    return Hello.Invalid;
}
