// Forward one TCP port to two backends, round robin: the smallest tcprouter program.
//
//     goose build examples/forward_port.goose && ./examples/forward_port
//
import tcprouter from "..";

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var w = tcprouter::Worker { .. };
    if !tcprouter::start(w, cfg, index) {
        print("worker ", index, ": ", w.error);
        return;
    }
    tcprouter::serve(w) { w, ev => };          // forward-only: nothing to handle
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
    tcprouter::spawn(cfg, tcprouter::cpu_count(), worker);
    tcprouter::wait_for_signal_then_drain(30000);
}
