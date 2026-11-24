// Proves: contract 0.4 declarations (supporting: the router requires ten capabilities of its loop)
// Checks that the loop tcprouter runs on supplies the ten capabilities the router needs (contract 0.4): all but unix.
// Build and run:  goose build tests/unit/capabilities_test.goose -o /tmp/capabilities_test && /tmp/capabilities_test
import std;
import goose_io from "github.com/BHare1985/goose-io@v0.4";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";

fn supplied<S>(s: S) -> bool {
    const if same<S, goose_io::Supplied> { return true; } else { return false; }
}

fn main() {
    var io = epoll_ext::Loop { .. };
    assert(goose_io::VERSION_MAJOR == 0 && goose_io::VERSION_MINOR == 4);
    assert(supplied(goose_io::has_half_close(io)));
    assert(supplied(goose_io::has_sizing(io)));
    assert(supplied(goose_io::has_abort(io)));
    assert(supplied(goose_io::has_inspection(io)));
    assert(supplied(goose_io::has_batching(io)));
    assert(!supplied(goose_io::has_unix(io)));
    assert(supplied(goose_io::has_relay(io)));
    assert(supplied(goose_io::has_peek(io)));
    assert(supplied(goose_io::has_revoke(io)));
    assert(supplied(goose_io::has_wake(io)));
    assert(supplied(goose_io::has_limits(io)));
    print("capabilities: 10 supplied, 1 absent");
}
