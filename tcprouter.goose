// tcprouter: fast TCP servers for Linux: listeners, one event loop per core, routing by port or TLS
// server name (SNI), byte-for-byte forwarding, and event handlers for protocols of your own.
//
//     import tcprouter from "github.com/bhare1985/tcprouter@v0";
//
// Status: skeleton (milestone M0). The design is in design/; the behaviour is the numbered rows in
// design/05-requirements.md, each proved by a test under tests/. Nothing here is usable yet.
//
// Layout (all files declare `namespace tcprouter;`, except the libc bindings in sys.goose, which are
// internal and live in `tcprouter_sys` so that `close` and `send` never clash with the API):
//
//     sni.goose   the TLS ClientHello parser (design/04-sni.md)
//     sys.goose   libc and the small C layer in src/tr_sys.c
namespace tcprouter;

import .sni;
import .sys;
import .config;
import .engine;
import .route;
