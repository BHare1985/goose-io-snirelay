// Route TLS connections on port 443 by server name, without decrypting anything:
// api.example.com and *.example.com go to different backends, everything else is closed.
//
//     goose build examples/sni_router.goose && ./examples/sni_router
//
import tcprouter from "..";

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var w = tcprouter::Worker { .. };
    if !tcprouter::start(w, cfg, index) { print(w.error); return; }
    tcprouter::serve(w) { w, ev => };
}

fn main() {
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener {
        id: 1, addr: tcprouter::addr("0.0.0.0:443"), inspect: tcprouter::Inspect.Sni,
    });
    // First match wins: exact, then the longest suffix, then NoSni, then Any.
    let api = tcprouter::add_target(cfg, tcprouter::target(["10.0.1.10:443", "10.0.1.11:443"]));
    let web = tcprouter::add_target(cfg, tcprouter::target(["10.0.2.10:443"]));
    cfg.routes.push(tcprouter::sni_route(cfg, 1, "api.example.com", tcprouter::Action.Forward { to: api }));
    cfg.routes.push(tcprouter::sni_suffix_route(cfg, 1, "*.example.com", tcprouter::Action.Forward { to: web }));
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Close));    // unknown name

    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) { print(problems); exit(2); }
    tcprouter::spawn(cfg, tcprouter::cpu_count(), worker);
    tcprouter::wait_for_signal_then_drain(30000);
}
