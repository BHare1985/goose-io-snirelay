// Proves: contract 0.5 declarations (supporting: the router requires eleven capabilities of its loop)
// Checks that the loop tcprouter runs on supplies the eleven capabilities the router needs (contract 0.5): all but unix and name resolution.
// Build and run:  goose build tests/unit/capabilities_test.goose -o /tmp/capabilities_test && /tmp/capabilities_test
import std;
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";

fn supplied<S>(s: S) -> bool {
    const if same<S, goose_io::Supplied> { return true; } else { return false; }
}

fn main() {
    var io = epoll_ext::Loop { .. };
    assert(goose_io::VERSION_MAJOR == 0 && goose_io::VERSION_MINOR == 5);
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
    assert(supplied(goose_io::has_shared_listen(io)));
    assert(!supplied(goose_io::has_name_resolution(io)));
    print("capabilities: 11 supplied, 2 absent");
}
