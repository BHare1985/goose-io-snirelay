import cpkg from "..";
fn main() {
    let xs: i32[4] = [1, 2, 3, 4];
    var info = cpkg::Info { 0, 0 };
    cpkg::cpkg_fill(xs, info);
    var s: u8[>..] = [];
    s.append("pre:");
    cpkg::cpkg_describe(s, 16);
    let h = cpkg::cpkg_open(7);
    let a = cpkg::cpkg_next(h); let b = cpkg::cpkg_next(h);
    cpkg::cpkg_close(h);
    print(cpkg::sum(xs), " ", info, " ", s, " ", a != b);
}
