// Test root for `zig build test`. Rooting the test module at src/ keeps all
// relative imports inside the module path; the comptime reference pulls the
// target file's tests into the build.
comptime {
    _ = @import("layouts/common/render_opt.zig");
}
