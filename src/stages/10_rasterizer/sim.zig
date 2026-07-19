// Stage 10: the renderer is data too (P11) — same sim as stage 9, optimized render.
//
// The Sim is byte-for-byte stage 9's synthesis (reused, not copied — the
// layout lesson is done; `git diff` against 09 shows only the render swap).
// What changes is the RENDERER: render() dispatches to this stage's own
// render.zig — the optimized rasterizer — instead of the shared naive one.
// Everything else (step, snapshot, bytesPerParticle, dumpFields) forwards to
// stage 9's Sim untouched, so the golden check and the step-side bench
// numbers are stage 9's by construction. The render-side win is measured by
// `zig build -Dmode=bench -- --render` (stage 9 vs stage 10).

const std = @import("std");
const fw = @import("../../framework/sim.zig");
const s9 = @import("../09_synthesis/sim.zig");
const opt_render = @import("render.zig");

pub const Sim = struct {
    alloc: std.mem.Allocator,
    inner: *s9.Sim,
    n: usize, // mirrored: play/bench/correctness read sim.n directly

    pub fn init(alloc: std.mem.Allocator, desc: fw.Desc) anyerror!*@This() {
        const self = try alloc.create(@This());
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .inner = try s9.Sim.init(alloc, desc),
            .n = desc.n,
        };
        return self;
    }

    pub fn step(self: *@This(), dt: f32) void {
        self.inner.step(dt);
    }

    /// The stage-10 override: optimized rasterizer over stage 9's SoA streams.
    /// Byte-identical output to the naive pipeline (proven by render.zig's
    /// tests); the win is pure renderer-side throughput.
    pub fn render(self: *const @This(), fb: []u8, w: u32, h: u32) void {
        const inner = self.inner;
        opt_render.renderScene(
            inner.pos_x[0..inner.n],
            inner.pos_y[0..inner.n],
            inner.kind[0..inner.n],
            fb,
            w,
            h,
        );
    }

    pub fn deinit(self: *@This()) void {
        self.inner.deinit();
        self.alloc.destroy(self);
    }

    pub fn snapshot(self: *const @This(), out: []f32) void {
        self.inner.snapshot(out);
    }

    pub fn bytesPerParticle(self: *const @This()) usize {
        return self.inner.bytesPerParticle();
    }

    pub fn dumpFields(self: *const @This(), alloc: std.mem.Allocator) ![]fw.FieldDump {
        return self.inner.dumpFields(alloc);
    }
};
