# router-on-goose-io Specification

## Purpose
A TCP router and forwarder that behaves and performs like tcprouter and is built on the goose-io contract, so that one router runs on any event loop that
offers the groups it requires.

## Requirements

### Requirement: Same behaviour as tcprouter
goose-io-tcpproxy SHALL pass every test file of goose-io-tcpproxy at its current HEAD (46 files, 0 failed) without any of them being edited, on goose-io-epoll-ext.

#### Scenario: The suite runs unchanged
- **WHEN** `tests/run_tests.sh` runs on the ported tree
- **THEN** the same 46 test files run, none is edited, and none fails

#### Scenario: A test cannot be met by the contract
- **WHEN** a test fails because the contract or the loop cannot express what it checks
- **THEN** the gap is recorded, the contract or the loop is changed with its own conformance check, and the test is still not edited

### Requirement: Same public API
The ported library SHALL keep the API shape of tcprouter (Worker, `start`, `serve` in both forms, Conn, Event, Config with Listener, Route, Target and Limits,
`Message`, `spawn`, `stats`) so that existing programs and examples build unchanged.

#### Scenario: Examples build
- **WHEN** each program in `examples/` is built against the ported library
- **THEN** it builds without a source change and its example test passes

### Requirement: No loss of speed
The ported router on goose-io-epoll-ext SHALL be no slower than the current goose-io-tcpproxy on the workloads of `bench/RESULTS.md` (11 B at 64 and 512
connections, a new connection per request, 16 KiB, 64 KiB, 1 MiB, web mix), measured on the same host back to back, and SHALL use no more memory per idle
connection than 1.25 times the current figure.

#### Scenario: Throughput
- **WHEN** `bench/run_m6.sh` runs for the current tree and the ported tree back to back
- **THEN** each workload's median requests per second for the ported tree is at least 95% of the current tree's

#### Scenario: Memory
- **WHEN** `bench/memory.py` measures idle connections for both trees
- **THEN** the ported tree's bytes per idle connection are at most 1.25 times the current tree's

### Requirement: Built only on the contract
The router SHALL touch the network and the clock only through the goose-io contract. It SHALL contain no socket, epoll or libc network calls, and it SHALL
state at start which groups it requires and fail at once if the loop lacks one.

#### Scenario: Missing group
- **WHEN** the router is started on a loop that does not offer a group it requires
- **THEN** the start fails before any listener is opened and names the group

#### Scenario: No network code of its own
- **WHEN** the library files and `src/` of the ported tree are searched for socket, epoll, accept, recv, send and connect calls
- **THEN** there are none

### Requirement: Self-contained repository
goose-io-tcpproxy SHALL build and test from a fresh clone with no path into the goose-io repository; goose-io-epoll-ext and goose-io are pinned by git import.

#### Scenario: Fresh clone
- **WHEN** the repository is cloned to an empty directory and `tests/run_tests.sh` runs
- **THEN** the dependencies are fetched by pinned import and the suite passes

### Requirement: Gaps become contract additions
Anything the router needs that the contract lacks SHALL be added to the contract as an optional group (or an addition to one) with conformance checks, and
SHALL NOT be worked around in the router.

#### Scenario: A gap is found
- **WHEN** the port needs an operation or event the contract does not have
- **THEN** an `add-*` change records it with the router behaviour that needs it, the memory loop and goose-io-epoll-ext implement it, and the router uses it
