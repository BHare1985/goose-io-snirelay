// Forward one TCP port to two backends, round robin: the smallest tcprouter program.
//
//     goose build examples/forward_port.goose && ./examples/forward_port
//
import tcprouter from "..";
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
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
