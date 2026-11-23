# tcprouter

Fast TCP servers for Linux, in memory-safe Goose: listeners, one event loop per core, routing by port or
TLS server name (SNI, read without decrypting), byte-for-byte forwarding, and event handlers for
protocols of your own (an HTTP server, for example).

**Status:** v0.1.0 candidate. The engine, SNI routing, handler mode, deadlines/fences and draining are built and tested;
see [docs/status.md](docs/status.md) for what is verified, what is not, and what is open. Every behaviour is a numbered row in
[design/05-requirements.md](design/05-requirements.md) and each row is proved by a test under [tests/](tests/).

```goose
import tcprouter from "github.com/bhare1985/tcprouter@v0";
```

Needs Goose (tested with `goose 751794c`), `git` to fetch the package, and a C compiler: the package carries
one small C file (`src/c_sys.c`). Linux only.

## Start here

| You want to | Read |
|---|---|
| write an HTTP server (or any protocol of your own) | [docs/building-an-http-server.md](docs/building-an-http-server.md), then copy [examples/http_server.goose](examples/http_server.goose) |
| forward ports or route TLS by server name (nothing decrypted) | [examples/forward_port.goose](examples/forward_port.goose), [examples/sni_router.goose](examples/sni_router.goose) |
| know what is verified, measured and open | [docs/status.md](docs/status.md), [bench/RESULTS.md](bench/RESULTS.md) |
| plan Gatekeeper's next step | [docs/gatekeeper-next-step.md](docs/gatekeeper-next-step.md) |
| see the API | [design/02-api.md](design/02-api.md) |

## The smallest program

Forward one port to two backends (this is `examples/forward_port.goose`, copied here by hand; `tests/net/readme_test.py` fails if the two differ):

```goose
// Forward one TCP port to two backends, round robin: the smallest tcprouter program.
//
//     goose build examples/forward_port.goose && ./examples/forward_port
//
import tcprouter from "..";
import goose_io from "github.com/BHare1985/goose-io@v0.3";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var io = epoll_ext::Loop { .. };
    var w = tcprouter::Worker { .. };
    if !w.start(io, cfg, index) {
        print("worker ", index, ": ", w.error);
        return;
    }
    io.attach(index);
    io.serve() { io, ev => w.on_event(io, ev); };          // forward-only: nothing to handle
}

fn main() {
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr("0.0.0.0:5432") });
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: tcprouter::add_target(cfg, tcprouter::target(["10.0.0.5:5432", "10.0.0.6:5432"])) }));

    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) {
        print(problems);
        exit(2);
    }
    epoll_ext::spawn(epoll_ext::cpu_count(), cfg, worker);
    epoll_ext::wait_for_signal_then_drain(30000);
}
```

## Examples

- [examples/forward_port.goose](examples/forward_port.goose): forward one port to two backends.
- [examples/sni_router.goose](examples/sni_router.goose): route TLS by server name, nothing decrypted.
- [examples/http_hello.goose](examples/http_hello.goose): the smallest HTTP/1.1 keep-alive server on handler mode (every request gets "hello").
- [examples/http_server.goose](examples/http_server.goose): a complete HTTP/1.1 server (bodies of any size, files, HEAD, pipelining, backpressure) that the benchmarking guides use; same behaviour as `bench/backend.c`.

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

## Licence

SPDX-License-Identifier: `MIT OR Apache-2.0`. Choose either: see [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE).
Code you import keeps its own licence. **gslib** (github.com/SorinS/gslib), used only by the TLS support check in `tests/net/harness/tls_server.goose` and described in
[docs/tls-support.md](docs/tls-support.md), is now licensed Apache-2.0 upstream (LICENSE added in its commit 84ac839; check the version you pin). It is still never vendored here.
