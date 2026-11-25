// Route TLS connections on port 443 by server name, without decrypting anything:
// api.example.com and *.example.com go to different backends, everything else is closed.
//
//     goose build examples/sni_router.goose && ./examples/sni_router
//
import tcprouter from "..";
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var io = epoll_ext::Loop { .. };
    var w = tcprouter::Worker { .. };
    if !w.start(io, cfg, index) { print(w.error); return; }
    io.attach(index);
    io.serve() { io, ev => w.on_event(io, ev); };
}

fn main() {
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener {
        id: 1, addr: tcprouter::addr("0.0.0.0:443"), inspect: tcprouter::Inspect.Sni,
    });
    // First match wins: exact, then the longest suffix, then NoSni, then Any.
    cfg.routes.push(tcprouter::sni_route(1, "api.example.com", tcprouter::Action.Forward { to: tcprouter::add_target(cfg, tcprouter::target(["10.0.1.10:443", "10.0.1.11:443"])) }));
    var web = tcprouter::Match.SniSuffix { name: [] };
    web.name.append("example.com");
    cfg.routes.push(tcprouter::Route { listener: 1, on: web, action: tcprouter::Action.Forward {
        to: tcprouter::add_target(cfg, tcprouter::target(["10.0.2.10:443"])),
    }});
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Close));    // unknown name

    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { print(problems); exit(2); }
    epoll_ext::spawn(epoll_ext::cpu_count(), cfg, worker);
    epoll_ext::wait_for_signal_then_drain(30000);
}
