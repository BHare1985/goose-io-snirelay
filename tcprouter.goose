// tcprouter: fast TCP servers for Linux: listeners, one event loop per core, routing by port or TLS
// server name (SNI), byte-for-byte forwarding, and event handlers for protocols of your own.
//
//     import tcprouter from "github.com/bhare1985/tcprouter@v0";
//
// Status: skeleton (milestone M0). The design is in design/; the behaviour is the numbered rows in
// design/05-requirements.md, each proved by a test under tests/. Nothing here is usable yet.
//
// Layout (all files declare `namespace tcprouter;`; internal names start with `c_`, see README.md):
//
//     sni.goose   the TLS ClientHello parser (design/04-sni.md)
//     types.goose router.goose handler.goose messages.goose   the router, generic over a goose-io event loop
namespace tcprouter;

import .sni;
import .config;
import .route;
import .address;
import .check;
import .types;
import .router;
import .handler;
import .messages;
