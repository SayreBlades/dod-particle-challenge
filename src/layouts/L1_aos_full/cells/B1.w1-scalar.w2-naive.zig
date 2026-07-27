// Cell L1.B1.w1-scalar.w2-naive — B1 (math+decide+respawn | render),
// walk 1 scalar-forced branchy, walk 2 naive r0 render.
//
// The de-vectorization control. Golden: bit-exact. Diff vs B1.w1-naive.w2-naive:
// walk-1 schedule auto → scalar (isolates the step-schedule axis).

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const layout = @import("../data.zig");
const w1 = @import("../walks/w1-scalar.zig");
const w2 = @import("../walks/w2-naive.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B1,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{ w1.decl, w2.decl },
        .golden = .bit_exact,
        .halide_expressible = "walk1 no (branchy respawn, de-vec control); walk2 n/a (render)",
    };
    pub const step = w1.step;
    pub const render = w2.render;
};

pub const Sim = fw.Strategy(Data, H);
