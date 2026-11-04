// Route matching (design/02-api.md section 2, RT-3a, RT-3b). Pure: no sockets, no allocation.
// STUB: the final signature, no behaviour yet, so tests compile and fail (red gate).
namespace tcprouter;

import .config;
import .sni;

// Which route takes a new connection on `listener`, given what its first bytes were (`hello`, from
// parse_hello; ignored on a listener whose `inspect` is None). Returns a reference to the winning
// route inside `cfg` (its index is `cfg.routes.index_of(route)`), or null when no route matches, which
// means the connection is closed. A hello that is NeedMore or Invalid never matches: the first is not
// routable yet, the second is a client the engine closes (RT-3f).
fn match_route(cfg: const Config&, listener: u16, hello: Hello) -> const Route? {
    return null;
}
