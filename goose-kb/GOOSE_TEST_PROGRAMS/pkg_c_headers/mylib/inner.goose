namespace mylib;
// Declared in namespace mylib even though it is a separate file; callers see mylib::inner::... no:
// the import path does not create a namespace, so this is simply mylib::twice.
fn twice(x: i64) -> i64 { x * 2 }
