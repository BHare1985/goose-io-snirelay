// The forwarding server of the seam proof: the epoll event loop with tcprouter's forward pump added back (epoll_forward/forward.goose),
// forwarding every connection of its listener to one target. It takes the flags of tcprouter's tests/net/harness/forward_server.goose
// that the gates and the correctness checks use:
//
//     forward_server --listen 127.0.0.1:9000 --to 127.0.0.1:9100 [--workers 1] [--buffers 4096] [--buffer-size 32768] [--stat-ms N]
//
// (--stat-ms is accepted and ignored.) Stops on SIGTERM or SIGINT, draining for up to five seconds.
import std;
import os;
import goose_io from "../../..";
import epoll from "../../../examples/loops/epoll";
import tcproxy from "../ext";

var listen_addr: u8[>..] = [];
var target_addr: u8[>..] = [];
var buffers:     i64     = 4096;
var buffer_size: i64     = 32768;

thread_fn worker(index: i64) {
    var io = epoll::Loop { .. };
    io.limits.buffers_per_loop = buffers;
    io.limits.buffer_size = buffer_size;
    let l, err = io.listen(listen_addr[..]);
    if goose_io::failed(err) { print("cannot listen on ", listen_addr); epoll::report_failed_start(); return; }
    var fwd = tcproxy::Forwarder { .. };
    tcproxy::route(fwd, l, target_addr[..]);
    io.attach(index);
    io.serve(fwd) { io, ev => };
}

fn main() {
    var workers = 1;
    var k = 1;
    while k < arg_count() {
        var flag: u8[>..] = [];
        arg(k, flag);
        var value: u8[>..] = [];
        if k + 1 < arg_count() { arg(k + 1, value); }
        k += 2;
        let n, ok = parse_int(value[..]);
        if flag == "--listen" { listen_addr.append(value[..]); }
        else if flag == "--to" { target_addr.append(value[..]); }
        else if flag == "--workers" && ok { workers = n; }
        else if flag == "--buffers" && ok { buffers = n; }
        else if flag == "--buffer-size" && ok { buffer_size = n; }
    }
    epoll::spawn(workers, worker);
    epoll::wait_for_signal_then_drain(5000);
}
