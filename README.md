# tcprouter

Fast TCP servers for Linux, in memory-safe Goose: listeners, one event loop per core, routing by port or
TLS server name (SNI, read without decrypting), byte-for-byte forwarding, and event handlers for
protocols of your own (an HTTP server, for example).

**Status:** under construction (milestone M1). The design is in [design/](design/README.md); every
behaviour is a numbered row in [design/05-requirements.md](design/05-requirements.md) and each row is
proved by a test under [tests/](tests/). Nothing is released.

```goose
import tcprouter from "github.com/bhare1985/tcprouter@v0";
```

Needs Goose (tested with `goose 751794c`), `git` to fetch the package, and a C compiler: the package carries
one small C file (`src/c_sys.c`).

## Examples

- [examples/forward_port.goose](examples/forward_port.goose): forward one port to two backends.
- [examples/sni_router.goose](examples/sni_router.goose): route TLS by server name, nothing decrypted.
- [examples/http_hello.goose](examples/http_hello.goose): an HTTP/1.1 keep-alive server on handler mode.

## Conventions for people reading or extending the code

Goose has no privacy and no nested namespaces: every declaration in a package is public. So that a reader can
tell the API from the machinery at a glance, names carry a marker, and the rule does not change:

| Name looks like | Meaning |
|---|---|
| `parse_hello`, `Config`, `Worker`, `Event`, `serve` | **Public API.** Documented in design/02 and covered by tests. |
| `_close_connection`, `_ConnectionSlot`, `_STATE_FORWARDING`, `_connection_slots` | **Private.** A leading underscore, then the name spelled out in full. May change or vanish in any release; do not use. (The underscore is this project's convention, not the language's: Goose has no privacy, and its own standard library uses no underscore names. Nothing stops `tcprouter::_close_connection`.) Functions are written as methods, `w._close_connection(i)`, because Goose resolves `x.f()` in the namespace of `x`'s type. |
| `c_listen`, `c_epoll_wait`, `c_EpollEvent`, `c_EAGAIN` | **Comes from C.** The functions in `src/c_sys.c` and their declarations in `sys.goose` (same names, no renaming), plus the constants and structs that mirror C's. A `c_` name at a call site tells you the call leaves Goose. |

Every file declares `namespace tcprouter;`.
Library code never reads files, environment variables or flags, never calls `abort` or `exit` because of
anything a peer or the operating system does, and range-checks every index that comes from the kernel or
the wire.

A **`return` inside a block you pass to `serve` returns from the function that contains the block**, not
from the block. Never put logic inline in the block: call a named function, as `examples/http_hello.goose`
does.

```goose
w.serve() { w, ev => if bad { return; } };      // WRONG: leaves the whole worker
w.serve() { w, ev => on_event(w, ev); };        // right: the logic is a function of its own
```

## Tests

```bash
tests/run_tests.sh          # builds every test with --debug and runs it
tests/coverage.sh           # requirement rows that no test proves yet
```
