// Proves: RT-3e RT-3f   (design/04-sni.md vectors S1-S12; the first red gate)
//
//     goose build --debug tests/unit/sni_test.goose && ./tests/unit/sni_test
//
// Exit status 0 and a last line "all N checks passed" mean success. Build with --debug: the fuzz
// vector (S11) relies on its range checks to catch a read past the end of the input.
//
// The test uses the library the way a stranger would: it imports the package, calls
// tcprouter::parse_hello on bytes it holds, and looks at the tcprouter::Hello it gets back.
//
// Real ClientHellos in tests/data/ were captured from installed clients by tests/data/capture.py
// (openssl, curl, python, node, wget; see tests/data/README.md). Chrome, Firefox and Go are not
// installed on the development host, so S12 does not include them. The synthetic ClientHellos
// (S5 to S10) are built by the helpers below, which follow RFC 8446 section 4.1.2 and RFC 6066.
//
// ASSUMPTIONS the design leaves open (Charlie: please confirm or strike each one):
//   A1. parse_hello(bytes) without scratch, given a ClientHello split over several records,
//       returns Invalid (it has nowhere to reassemble). Checked in S5.
//   A2. Empty input is NeedMore with total >= 1. Checked in "extra".
//   A3. A first byte that is not 0x16 is NotTls whatever follows: 0x15 (alert) and 0x80 (SSLv2
//       hello) included. Checked in S6.
//   A4. For a prefix of a single-record ClientHello, NeedMore.total is the whole record, or less,
//       but always more than the bytes given (S4). The test does not require it to be exact.

import tcprouter from "../..";
import std;

var checks: i64 = 0;
var failures: i64 = 0;

fn check(ok: bool, what: const u8[:]) {
    checks++;
    if !ok {
        failures++;
        print("FAIL: ", what);
    }
}

// --- the captured vectors, compiled into the test ---------------------------------------------

let S1 = embed_file("../data/s1_openssl.bin");
let S2 = embed_file("../data/s2_openssl_upper_dot.bin");
let S3 = embed_file("../data/s3_openssl_nosni.bin");

// --- reading a Hello ----------------------------------------------------------------------------

fn is_found(h: tcprouter::Hello, name: const u8[:]) -> bool {
    return match h {
        Found f => f.name == name,
        _ => false,
    };
}

fn is_no_sni(h: tcprouter::Hello) -> bool { return match h { NoSni => true, _ => false }; }
fn is_not_tls(h: tcprouter::Hello) -> bool { return match h { NotTls => true, _ => false }; }
fn is_invalid(h: tcprouter::Hello) -> bool { return match h { Invalid => true, _ => false }; }
fn is_found_any(h: tcprouter::Hello) -> bool { return match h { Found f => true, _ => false }; }

// NeedMore: true when the parser asks for more than `have` bytes, and no more than `at_most`.
fn needs_more(h: tcprouter::Hello, have: i64, at_most: i64) -> bool {
    return match h {
        NeedMore n => n.total > have && n.total <= at_most,
        _ => false,
    };
}

fn kind(h: tcprouter::Hello) -> u8[:] {
    return match h {
        Found f => "Found",
        NoSni => "NoSni",
        NotTls => "NotTls",
        NeedMore n => "NeedMore",
        Invalid => "Invalid",
    };
}

// --- building ClientHellos ----------------------------------------------------------------------

fn put16(out: u8[>..]&, v: i64) { out.push((v >> 8) as! u8); out.push(v as! u8); }
fn put24(out: u8[>..]&, v: i64) { out.push((v >> 16) as! u8); out.push((v >> 8) as! u8); out.push(v as! u8); }

// One server_name list entry: type, 2-byte length, bytes.
fn name_entry(out: u8[>..]&, kind: u8, name: const u8[:]) {
    out.push(kind);
    put16(out, name.len);
    out.append(name);
}

// A server_name extension (type 0) around already-built list entries.
fn sni_extension(out: u8[>..]&, entries: const u8[:]) {
    put16(out, 0);                    // extension type: server_name
    put16(out, entries.len + 2);      // extension length
    put16(out, entries.len);          // server_name_list length
    out.append(entries);
}

// A supported_versions-style filler extension, so that tests have extensions around the SNI.
fn filler_extension(out: u8[>..]&, ext_type: i64, n: i64) {
    put16(out, ext_type);
    put16(out, n);
    for i in n { out.push(i as! u8); }
}

// The handshake message: ClientHello with the given extensions block (already built).
fn client_hello_message(out: u8[>..]&, extensions: const u8[:]) {
    var body: u8[>..] = [];
    put16(body, 0x0303);                           // legacy_version
    for i in 32 { body.push((i * 7) as! u8); }     // random
    body.push(0);                                  // legacy_session_id: empty
    put16(body, 4); put16(body, 0x1301); put16(body, 0x1302);   // two cipher suites
    body.push(1); body.push(0);                    // compression: null only
    put16(body, extensions.len);
    body.append(extensions);
    out.push(1);                                   // handshake type: client_hello
    put24(out, body.len);
    out.append(body);
}

// One TLS record carrying `payload`.
fn record(out: u8[>..]&, payload: const u8[:]) {
    out.push(0x16); put16(out, 0x0301); put16(out, payload.len);
    out.append(payload);
}

// A complete ClientHello in one record whose SNI extension holds `entries`.
fn hello_with_entries(out: u8[>..]&, entries: const u8[:]) {
    var exts: u8[>..] = [];
    filler_extension(exts, 0x000b, 4);
    sni_extension(exts, entries);
    filler_extension(exts, 0x002b, 5);
    var msg: u8[>..] = [];
    client_hello_message(msg, exts);
    record(out, msg);
}

fn hello_for(out: u8[>..]&, name: const u8[:]) {
    var entries: u8[>..] = [];
    name_entry(entries, 0, name);
    hello_with_entries(out, entries);
}

// The same handshake message as `src`'s single record, re-cut into records of at most `piece` bytes.
fn recut(src: const u8[:], piece: i64, out: u8[>..]&) {
    let payload = src[5..];
    var at = 0;
    while at < payload.len {
        let n = if payload.len - at < piece { payload.len - at } else { piece };
        record(out, payload[at..at + n]);
        at += n;
    }
}

// Two records: the first holds `first` bytes of the handshake message.
fn split_in_two(src: const u8[:], first: i64, out: u8[>..]&) {
    let payload = src[5..];
    record(out, payload[..first]);
    record(out, payload[first..]);
}

fn name_of(n: i64, ch: u8) -> u8[>..] {
    var s: u8[>..] = [];
    for i in n { s.push(if i % 60 == 59 { '.' } else { ch }); }
    return s;
}

// --- S1 S2 S3: real ClientHellos ---------------------------------------------------------------

fn test_real() {
    var scratch: u8[16384] = [0; 16384];
    check(S1.len == 1557, "S1 file is the 1557-byte openssl capture");
    check(is_found(tcprouter::parse_hello(S1), "api.example.com"), "S1 openssl -servername api.example.com");
    check(is_found(tcprouter::parse_hello(S1, scratch), "api.example.com"), "S1 with a scratch buffer");
    check(is_found(tcprouter::parse_hello(S2), "api.example.com"), "S2 API.Example.COM. is lowercased, trailing dot dropped");
    check(is_no_sni(tcprouter::parse_hello(S3)), "S3 openssl -noservername");

    // The ClientHello is never consumed or changed, and bytes after it do not matter (RT-3c's parser half).
    var with_tail: u8[>..] = [];
    with_tail.append(S1);
    with_tail.append("\x17\x03\x03\x00\x05hello");
    check(is_found(tcprouter::parse_hello(with_tail), "api.example.com"), "S1 followed by more bytes");
}

// --- S4: every prefix asks for more, never answers early ---------------------------------------

fn prefixes_ask_for_more(full: const u8[:], label: const u8[:]) {
    var bad: i64 = 0;
    for n in 1..full.len {
        let h = tcprouter::parse_hello(full[..n]);
        if !needs_more(h, n, full.len) { bad++; if bad <= 3 { print("  prefix ", n, " of ", label, " gave ", kind(h)); } }
    }
    check(bad == 0, label);
}

fn test_prefixes() {
    prefixes_ask_for_more(S1, "S4 every prefix of S1 is NeedMore with len < total <= full");
    prefixes_ask_for_more(S3, "S4 every prefix of S3 is NeedMore with len < total <= full");
    let tls12 = embed_file("../data/s12_openssl_tls12.bin");
    prefixes_ask_for_more(tls12, "S4 every prefix of the TLS 1.2 hello is NeedMore");
    check(is_found(tcprouter::parse_hello(tls12), "tls12.example.com"), "S4 the full TLS 1.2 hello is Found");
}

// --- S5: a ClientHello split over several records ----------------------------------------------

fn test_split_records() {
    var scratch: u8[16384] = [0; 16384];
    // Split points: inside the 4-byte handshake header, just after it, in the middle, near the end.
    for first in [1, 2, 4, 5, 700, 1500] {
        var split: u8[>..] = [];
        split_in_two(S1, first, split);
        let label = str("S5 split after ", first, " handshake bytes");
        check(is_found(tcprouter::parse_hello(split, scratch), "api.example.com"), label);
        check(is_invalid(tcprouter::parse_hello(split)), "S5/A1 without scratch a split hello is Invalid");

        // Short of the second record, the parser asks for more and never answers early.
        var bad: i64 = 0;
        for n in 1..split.len {
            let h = tcprouter::parse_hello(split[..n], scratch);
            if !needs_more(h, n, split.len) { bad++; }
        }
        check(bad == 0, str("S5 prefixes of the split-after-", first, " hello are NeedMore within the full length"));
    }

    // Many tiny records: 100 bytes per record, 7 bytes per record.
    for piece in [100, 7] {
        var many: u8[>..] = [];
        recut(S1, piece, many);
        check(is_found(tcprouter::parse_hello(many, scratch), "api.example.com"), str("S5 records of ", piece, " bytes"));
    }

    // A scratch buffer that is too small cannot hold the hello: Invalid, not an abort.
    var small: u8[64] = [0; 64];
    var split: u8[>..] = [];
    split_in_two(S1, 700, split);
    check(is_invalid(tcprouter::parse_hello(split, small)), "S5 scratch smaller than the hello is Invalid");
}

// --- S6: not TLS --------------------------------------------------------------------------------

fn test_not_tls() {
    let get = "GET / HTTP/1.1\r\nHost: x\r\n\r\n";
    check(is_not_tls(tcprouter::parse_hello(get[..1])), "S6 'G' is NotTls after one byte");
    check(is_not_tls(tcprouter::parse_hello(get)), "S6 an HTTP request is NotTls");
    check(is_not_tls(tcprouter::parse_hello("\x15\x03\x03\x00\x02\x02\x28")), "A3 a TLS alert record is NotTls");
    check(is_not_tls(tcprouter::parse_hello("\x80\x2e\x01\x03\x01")), "A3 an SSLv2-style hello is NotTls");
    check(is_not_tls(tcprouter::parse_hello("\x00")), "S6 a zero byte is NotTls");
    check(is_not_tls(tcprouter::parse_hello("SSH-2.0-OpenSSH_9.6\r\n")), "S6 an SSH banner is NotTls");
}

// --- S7: too big (RT-3f) ------------------------------------------------------------------------

fn test_too_big() {
    var scratch: u8[16384] = [0; 16384];
    // A record claiming 16385 bytes: more than the 16384 a record may hold. Invalid at once, from the header.
    check(is_invalid(tcprouter::parse_hello("\x16\x03\x01\x40\x01")), "S7 record length 16385 is Invalid from the header alone");
    check(is_invalid(tcprouter::parse_hello("\x16\x03\x01\xff\xff\x01\x00\x00")), "S7 record length 65535 is Invalid");
    // Exactly 16384 is allowed by the record layer; the parser waits for it (but never for more than that).
    check(needs_more(tcprouter::parse_hello("\x16\x03\x01\x40\x00"), 5, 5 + 16384), "S7 record length 16384 asks for at most 16389 bytes");

    // A handshake message that declares more than 16 KB is Invalid even when its first record is small.
    var msg: u8[>..] = [];
    msg.push(1); put24(msg, 20000); for i in 100 { msg.push(0); }
    var rec: u8[>..] = [];
    record(rec, msg);
    check(is_invalid(tcprouter::parse_hello(rec, scratch)), "RT-3f a handshake declaring 20000 bytes is Invalid");
    check(is_invalid(tcprouter::parse_hello(rec)), "RT-3f the same, without scratch");
}

// --- S8: lengths that lie -----------------------------------------------------------------------

fn test_lying_lengths() {
    var entries: u8[>..] = [];
    name_entry(entries, 0, "api.example.com");

    // The server_name extension claims 100 bytes more than the record has left.
    var exts: u8[>..] = [];
    put16(exts, 0); put16(exts, entries.len + 2 + 100); put16(exts, entries.len); exts.append(entries);
    var msg: u8[>..] = [];
    client_hello_message(msg, exts);
    var rec: u8[>..] = [];
    record(rec, msg);
    check(is_invalid(tcprouter::parse_hello(rec)), "S8 extension length past the end of the record");

    // The extensions block claims more than the hello has.
    var exts2: u8[>..] = [];
    sni_extension(exts2, entries);
    var msg2: u8[>..] = [];
    client_hello_message(msg2, exts2);
    msg2[msg2.len - exts2.len - 2] = 0x7f;       // high byte of the extensions length
    var rec2: u8[>..] = [];
    record(rec2, msg2);
    check(is_invalid(tcprouter::parse_hello(rec2)), "S8 extensions length past the end");

    // The server_name list claims more than its extension holds.
    var exts3: u8[>..] = [];
    put16(exts3, 0); put16(exts3, entries.len + 2); put16(exts3, entries.len + 50); exts3.append(entries);
    var msg3: u8[>..] = [];
    client_hello_message(msg3, exts3);
    var rec3: u8[>..] = [];
    record(rec3, msg3);
    check(is_invalid(tcprouter::parse_hello(rec3)), "S8 server_name list longer than its extension");

    // The host name claims more bytes than the list holds.
    var bad_entry: u8[>..] = [];
    bad_entry.push(0); put16(bad_entry, 200); bad_entry.append("api.example.com");
    var rec4: u8[>..] = [];
    hello_with_entries(rec4, bad_entry);
    check(is_invalid(tcprouter::parse_hello(rec4)), "S8 host name longer than its list");

    // Session id length past the end.
    var rec5: u8[>..] = [];
    hello_for(rec5, "api.example.com");
    rec5[5 + 4 + 2 + 32] = 250;                  // legacy_session_id length
    check(!is_found_any(tcprouter::parse_hello(rec5)), "S8 session id length past the end is not Found");
    check(!is_no_sni(tcprouter::parse_hello(rec5)), "S8 session id length past the end is not NoSni");

    // Not a client_hello: a ServerHello (type 2) in a handshake record.
    var rec6: u8[>..] = [];
    hello_for(rec6, "api.example.com");
    rec6[5] = 2;
    check(is_invalid(tcprouter::parse_hello(rec6)), "S8 handshake type 2 is Invalid");
}

// --- S9: server_name list order -----------------------------------------------------------------

fn test_name_list() {
    var entries: u8[>..] = [];
    name_entry(entries, 1, "junk");                         // a name type that is not host_name
    name_entry(entries, 0, "ok.example.com");               // then the host name
    var rec: u8[>..] = [];
    hello_with_entries(rec, entries);
    check(is_found(tcprouter::parse_hello(rec), "ok.example.com"), "S9 host name found after a non-host-name entry");

    var only_other: u8[>..] = [];
    name_entry(only_other, 1, "junk");
    var rec2: u8[>..] = [];
    hello_with_entries(rec2, only_other);
    check(is_no_sni(tcprouter::parse_hello(rec2)), "S9 a list with no host_name entry is NoSni");

    var empty_list: u8[>..] = [];
    var rec3: u8[>..] = [];
    hello_with_entries(rec3, empty_list);
    check(is_no_sni(tcprouter::parse_hello(rec3)), "S9 an empty server_name list is NoSni");
}

// --- S10: host name rules -----------------------------------------------------------------------

fn test_names() {
    var rec: u8[>..] = [];

    let n253 = name_of(253, 'a');
    hello_for(rec, n253);
    check(is_found(tcprouter::parse_hello(rec), n253), "S10 a 253-byte name is Found");

    rec.clear();
    hello_for(rec, name_of(254, 'a'));
    check(is_invalid(tcprouter::parse_hello(rec)), "S10 a 254-byte name is Invalid");

    rec.clear(); hello_for(rec, "bad_name.example.com");
    check(is_invalid(tcprouter::parse_hello(rec)), "S10 a name with '_' is Invalid");

    rec.clear(); hello_for(rec, "nul\x00byte.example.com");
    check(is_invalid(tcprouter::parse_hello(rec)), "S10 a name with a NUL is Invalid");

    rec.clear(); hello_for(rec, "caf\xc3\xa9.example.com");
    check(is_invalid(tcprouter::parse_hello(rec)), "S10 a name with non-ASCII bytes is Invalid");

    rec.clear(); hello_for(rec, "with space.example.com");
    check(is_invalid(tcprouter::parse_hello(rec)), "S10 a name with a space is Invalid");

    rec.clear(); hello_for(rec, "");
    check(is_no_sni(tcprouter::parse_hello(rec)), "S10 an empty name is NoSni");

    rec.clear(); hello_for(rec, "MiXeD.Example.COM");
    check(is_found(tcprouter::parse_hello(rec), "mixed.example.com"), "S10 names are lowercased");

    rec.clear(); hello_for(rec, "example.com.");
    check(is_found(tcprouter::parse_hello(rec), "example.com"), "S10 one trailing dot is dropped");

    rec.clear(); hello_for(rec, "a-b.example.com");
    check(is_found(tcprouter::parse_hello(rec), "a-b.example.com"), "S10 '-' is allowed");

    rec.clear(); hello_for(rec, "10.0.0.1");
    check(is_found(tcprouter::parse_hello(rec), "10.0.0.1"), "S10 digits and dots are allowed");
}

// --- S11: fuzz ----------------------------------------------------------------------------------

// The invariants every answer must satisfy, whatever the input.
fn sane(h: tcprouter::Hello, have: i64, max_total: i64) -> bool {
    return match h {
        Found f => {
            var ok = f.name.len >= 1 && f.name.len <= 253;
            for c in f.name {
                let good = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '-';
                if !good { ok = false; }
            }
            ok
        },
        NeedMore n => n.total > have && n.total <= max_total,
        _ => true,
    };
}

fn mutate(src: const u8[:], r: rng&, out: u8[>..]&) {
    out.append(src);
    let rounds = 1 + r.rand_int(4);
    for k in rounds {
        let what = r.rand_int(6);
        if what == 0 && out.len > 0 { out[r.rand_int(out.len)] = r.rand_int(256) as! u8; }
        else if what == 1 && out.len > 0 { out[r.rand_int(out.len)] ^= (1 << r.rand_int(8)) as! u8; }
        else if what == 2 && out.len > 1 { out.pop_n(1 + r.rand_int(out.len / 2)); }
        else if what == 3 { for j in 1 + r.rand_int(8) { out.push(r.rand_int(256) as! u8); } }
        else if what == 4 && out.len > 9 {
            // Lie in one of the first 60 bytes (record, handshake, version, session id, cipher suite lengths).
            out[r.rand_int(if out.len < 60 { out.len } else { 60 })] = (if r.rand_int(2) == 0 { 0 } else { 255 }) as! u8;
        }
    }
}

fn test_fuzz() {
    var split: u8[>..] = [];
    split_in_two(S1, 700, split);
    let bases: const u8[:][3] = [S1, S3, split];
    var r = rng { 20261104 };
    var scratch: u8[16384] = [0; 16384];
    var insane: i64 = 0;
    var found: i64 = 0;
    for i in 1000000 {
        let which = r.rand_int(4);
        var input: u8[>..] = [];
        if which == 3 {
            for j in r.rand_int(2000) { input.push(r.rand_int(256) as! u8); }   // pure noise
        } else {
            mutate(bases[which], r, input);
        }
        let max_total = 16384 * 6 + 9;
        let h = tcprouter::parse_hello(input, scratch);
        if !sane(h, input.len, max_total) { insane++; if insane <= 3 { print("  insane answer ", kind(h), " for input ", i); } }
        if is_found_any(h) { found++; }
        let h2 = tcprouter::parse_hello(input);           // the form without scratch must be as safe
        if !sane(h2, input.len, max_total) { insane++; }
    }
    check(insane == 0, "S11 1,000,000 mutated and random inputs: every answer satisfies its invariants, none aborts");
    // The fuzzer must reach the interesting code: if no mutation ever leaves a valid name, it tests nothing.
    check(found > 1000, "S11 the fuzzer still produces many valid ClientHellos (guards against a vacuous run)");
}

// --- S12: captured from real clients ------------------------------------------------------------

fn test_clients() {
    check(is_found(tcprouter::parse_hello(embed_file("../data/s12_curl_http1.bin")), "curl.example.com"), "S12 curl --http1.1");
    check(is_found(tcprouter::parse_hello(embed_file("../data/s12_curl_h2.bin")), "curlh2.example.com"), "S12 curl --http2");
    check(is_found(tcprouter::parse_hello(embed_file("../data/s12_python.bin")), "python.example.com"), "S12 python ssl");
    check(is_found(tcprouter::parse_hello(embed_file("../data/s12_node.bin")), "node.example.com"), "S12 node https");
    check(is_found(tcprouter::parse_hello(embed_file("../data/s12_wget_localhost.bin")), "localhost"), "S12 wget (GnuTLS)");
    check(is_found(tcprouter::parse_hello(embed_file("../data/s12_openssl_tls12.bin")), "tls12.example.com"), "S12 openssl -tls1_2");
    check(is_found(tcprouter::parse_hello(embed_file("../data/s12_openssl_tls13_alpn.bin")), "alpn.example.com"), "S12 openssl -tls1_3 with ALPN");
}

// --- extra: the edges of the contract ----------------------------------------------------------

fn test_edges() {
    check(needs_more(tcprouter::parse_hello(""), 0, 16384 * 6 + 9), "A2 empty input is NeedMore");
    check(needs_more(tcprouter::parse_hello("\x16"), 1, 16389), "a lone 0x16 byte is NeedMore, at most one record");
    check(is_invalid(tcprouter::parse_hello("\x16\x03\x01\x00\x00")), "an empty handshake record is Invalid");
}

fn main() {
    test_real();
    test_prefixes();
    test_split_records();
    test_not_tls();
    test_too_big();
    test_lying_lengths();
    test_name_list();
    test_names();
    test_clients();
    test_edges();
    test_fuzz();
    if failures > 0 {
        print(failures, " of ", checks, " checks FAILED");
        exit(1);
    }
    print("all ", checks, " checks passed");
}
