// Experiment: a package with separately compiled C (c_sources), the goose-libdeflate pattern.
namespace cpkg;

struct Info { count: i64, sum: i64 }

// Slices arrive in C as { data, len }; a struct reference as a pointer; a builder as gs_rref.
extern fn cpkg_sum(xs: const i32[:]) -> i64;
extern fn cpkg_fill(xs: const i32[:], out: Info&);
extern fn cpkg_describe(out: u8[>..]&, n: i64);
// An opaque C handle crosses as i64, like goose-libdeflate does with its compressors.
extern fn cpkg_open(seed: i64) -> i64;
extern fn cpkg_next(h: i64) -> i64;
extern fn cpkg_close(h: i64);

fn sum(xs: const i32[:]) -> i64 { cpkg_sum(xs) }
