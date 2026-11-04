// M0 O-2 and O-4.
//   O-4: a thread_fn takes (config value, index); the config is a ~70 KB flat struct with enums and limited arrays.
//   O-2: typed queues deliver each message to ONE receiver; broadcast needs a pipe per worker.
//        Main makes the pipes before spawning and hands each worker its read end as an argument.
//   ../../bin/goose build o24_workers_broadcast.goose && ./o24_workers_broadcast
import std;

extern fn pipe2(fds: i32[2]&, flags: i32) -> i32;
extern fn write(fd: i32, buf: const u8&, n: u64) -> i64;
extern fn read(fd: i32, buf: u8&, n: u64) -> i64;

enum Match { Any, Sni { name: u8[..253] }, NoSni }
struct Route { listener: u16, on: Match, to: u16 }
struct Config { routes: Route[..256], nroutes_hint: i64 = 0 }

struct Msg { kind: u8, a: i64, b: i64 }          // flat, 17 bytes: a pipe write this small is atomic
struct Report { worker: i64, saw_routes: i64, got_kind: u8 }
struct Job { n: i64 }
struct JobDone { worker: i64 }

let N = 4;

thread_fn worker(cfg: Config, index: i64, msg_fd: i32) {
    // 1. the config arrived intact
    var sni = 0;
    for r in cfg.routes {
        match r.on { Sni s => { sni++; }, _ => {} }
    }
    // 2. broadcast: block on my own pipe
    var m = Msg { 0, 0, 0 };
    var raw: u8[17] = [0; 17];
    let n = read(msg_fd, raw[0], 17);
    assert(n == 17);
    m.kind = raw[0];
    qput(Report { worker: index, saw_routes: cfg.routes.len, got_kind: m.kind });
    // 3. queue: compete for jobs
    let j = qget<Job>();
    qput(JobDone { worker: index });
}

fn post(fds: i32[N], kind: u8) {
    var raw: u8[17] = [0; 17];
    raw[0] = kind;
    for i in N { write(fds[i], raw[0], 17); }
}

fn main() {
    var cfg = Config { routes: [] };
    for i in 200 {
        if i % 2 == 0 { cfg.routes.push(Route { listener: 1, on: Match.Sni { name: "api.example.com" }, to: i as u16 }); }
        else { cfg.routes.push(Route { listener: 1, on: Match.Any, to: i as u16 }); }
    }
    print("Config size in bytes: ", bytes_of([cfg]).len);

    var rd: i32[N] = [0; N];
    var wr: i32[N] = [0; N];
    for i in N {
        var p: i32[2] = [0, 0];
        assert(pipe2(p, 0) == 0);
        rd[i] = p[0]; wr[i] = p[1];
    }
    var ids: i64[>..] = [];
    for i in N { ids.push(thread_spawn(worker, cfg, i, rd[i])); }

    post(wr, 7);                                      // one broadcast
    var seen: i64[N] = [0; N];
    for i in N { let r = qget<Report>(); seen[r.worker]++; assert(r.got_kind == 7 && r.saw_routes == 200); }
    print("broadcast reached each worker exactly once: ", seen);

    for i in N { qput(Job { n: i }); }                // N jobs on the shared queue
    var done: i64[N] = [0; N];
    for i in N { let d = qget<JobDone>(); done[d.worker]++; }
    print("queue jobs per worker (work-stealing, NOT broadcast): ", done);
    for id in ids { thread_wait(id); }
}
