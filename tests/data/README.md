# Captured TLS ClientHellos

Real first flights from TLS clients, recorded by `capture.py` (a local listener that stores the first bytes and
closes). Regenerate with `python3 tests/data/capture.py`. Each file is exactly one TLS record holding the whole
ClientHello. The expected names were confirmed by an independent parser (a short Python script, not the Goose
code under test) when the files were captured.

| File | Client | Expected SNI |
|---|---|---|
| `s1_openssl.bin` | `openssl s_client -servername api.example.com` (OpenSSL 3.5.5) | `api.example.com` |
| `s2_openssl_upper_dot.bin` | `-servername API.Example.COM.` (sent as written) | `api.example.com` after lowercasing and dropping the dot |
| `s3_openssl_nosni.bin` | `-noservername` | none (`NoSni`) |
| `s12_openssl_tls12.bin` | `-tls1_2 -servername tls12.example.com` (217 bytes) | `tls12.example.com` |
| `s12_openssl_tls13_alpn.bin` | `-tls1_3 -alpn h2,http/1.1` | `alpn.example.com` |
| `s12_curl_http1.bin` | curl 8.18.0 `--http1.1` | `curl.example.com` |
| `s12_curl_h2.bin` | curl 8.18.0 `--http2` | `curlh2.example.com` |
| `s12_python.bin` | Python 3.14 `ssl` | `python.example.com` |
| `s12_node.bin` | Node `https` | `node.example.com` |
| `s12_wget_localhost.bin` | wget 1.25.0 (GnuTLS) | `localhost` |

The OpenSSL 3.5 family sends a post-quantum key share, so most hellos are about 1.5 KB. **Not captured:** Chrome,
Firefox and Go are not installed on the development host. Add their files here (and a line to `sni_test.goose`'s
`test_clients`) when someone can capture them; Chrome's ClientHello also carries GREASE values and extension
padding that the other clients do not.
