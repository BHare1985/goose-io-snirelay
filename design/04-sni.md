# 04 — The ClientHello parser

The first code Brian writes: pure, no sockets, no threads, easy to test, and the piece most likely
to be useful on its own (a later standalone package, `tlshello`).

## Contract

```goose
enum Hello {                                   // [verify] ADT syntax
    Found(name: u8[..253]),     // SNI host name, lowercased, trailing dot removed
    NoSni,                      // a complete, valid ClientHello without a server_name extension
    NotTls,                     // the first bytes are not a TLS handshake record
    NeedMore(total: i64),       // valid so far; call again when at least `total` bytes are buffered
    Invalid,                    // a TLS record that breaks the format (lengths, types, sizes)
}

fn parse_hello(bytes: const u8[:], scratch: u8[:]) -> Hello   // one form only (Charlie, 2026-11-04):
                                                               // a split ClientHello always needs scratch,
                                                               // so a scratch-less form would be a trap
```

- **Input is whatever has arrived**, from byte 0 of the connection. The parser never consumes or
  changes it; the engine peeks (`MSG_PEEK`) or keeps the bytes and forwards them untouched.
- **No allocation.** The common case (one TLS record holds the whole ClientHello) is parsed in
  place. A ClientHello split across records is reassembled into `scratch` (caller-owned, 16 KB is
  enough: the limit below).
- **Limits:** a ClientHello larger than 16 KB is `Invalid` (RT-3f). `NeedMore.total` never exceeds
  16 KB + record headers, so the engine can size its peek buffer.
- **`NotTls` vs `Invalid`:** first byte not `0x16` (handshake) → `NotTls` at once, after 1 byte,
  so plain-TCP clients that speak first are routed by `NoSni`/`Any` without waiting. A `0x16`
  record with bad lengths → `Invalid`.
- **Name rules:** ASCII only; lowercased; one trailing dot dropped; empty name → `NoSni`; a name
  longer than 253 or with bytes outside `[a-z0-9.-]` after lowercasing → `Invalid` (RT-3e).
- **Matching** (separate, `fn match_sni(routes, name) -> u16?`): exact first, then the longest
  `SniSuffix`, then `NoSni`/`Any` rows, in config order within each kind.

**Settled at the first red gate (2026-11-04):** empty input is `NeedMore` (total ≥ 1); any first
byte other than `0x16` is `NotTls` (alerts and SSLv2 hellos included); `NeedMore.total` must exceed
the bytes given and not exceed the full record, but needn't be exact; an IPv4 literal passes the
name rule (RFC 6066 forbids it, clients don't send it, and it simply won't match a route).

## Test vectors (all required, test file `tests/sni_test.goose`)

| # | Input | Expect |
|---|---|---|
| S1 | Real ClientHello from `openssl s_client -servername api.example.com` | `Found("api.example.com")` |
| S2 | Same, `-servername API.Example.COM.` | `Found("api.example.com")` |
| S3 | ClientHello without SNI (`-noservername`) | `NoSni` |
| S4 | Each prefix of S1, length 1 … len-1 | `NeedMore(total)` with `total` ≤ full length, never `Found` early |
| S5 | S1 split into two TLS records (handshake fragmented) | `Found` with scratch; `NeedMore` without enough bytes |
| S6 | `GET / HTTP/1.1\r\n` | `NotTls` after 1 byte |
| S7 | Record length larger than 16 KB + 5 | `Invalid` |
| S8 | Extension length past the end of the record | `Invalid` |
| S9 | server_name list with a non-host-name type first, host name second | `Found` (host name) |
| S10 | Name of 254 bytes; name with `_`; name with a NUL | `Invalid` |
| S11 | Fuzz: 1,000,000 random and mutated inputs (from S1, S3, S5) | never aborts, never reads past input (`--debug` build) |
| S12 | ClientHellos captured from curl, Chrome, Firefox, Go, Python (files in `tests/data/`) | `Found` with the right name |

The C proxy's parser (`proxy.c`, search `sni`) handles S1–S9 today; port its behaviour, not its
code, and keep S11 green under `--debug`.
