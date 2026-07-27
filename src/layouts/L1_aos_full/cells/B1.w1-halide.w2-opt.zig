// Cell L1.B1.w1-halide.w2-opt — B1 (math+decide+respawn | render),
// walk 1 Halide branchless blend, walk 2 optimized r1 render.
//
// Golden: statistical. The w1-halide + w2-opt combination — fills the gap
// (r1 render available with the Halide walk). Diff vs B1.w1-halide.w2-naive:
// walk-2 schedule r0 → r1.

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const layout = @import("../data.zig");
const w1 = @import("../walks/w1-halide.zig");
const w2 = @import("../walks/w2-opt.zig");

const Data = layout.Data;

pub const H = struct {
    pub const cell_decl: fw.CellDecl = .{
        .layout = "L1_aos_full",
        .blueprint = .B1,
        .ordering = .identity,
        .intermediates = .none,
        .walks = &.{ w1.decl, w2.decl },
        .golden = .statistical,
        .halide_expressible = "walk1 yes (branchless blend, per-particle hash RNG); walk2 n/a (render)",
    };
    pub const step = w1.step;
    pub const render = w2.render;
};

pub const Sim = fw.Strategy(Data, H);
