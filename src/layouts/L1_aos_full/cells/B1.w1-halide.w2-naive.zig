// Cell L1.B1.w1-halide.w2-naive — B1 (math+decide+respawn | render),
// walk 1 Halide branchless blend, walk 2 naive r0 render.
//
// Golden: statistical (different RNG model by design — per-particle hash RNG
// vs the branchy variant's ordered spawn stream). Diff vs B1.w1-naive.w2-naive:
// walk-1 impl zig → halide AND variant branchy → blend (isolates the
// impl+variant axes; the statistical golden is the cost of that isolation).

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const layout = @import("../data.zig");
const w1 = @import("../walks/w1-halide.zig");
const w2 = @import("../walks/w2-naive.zig");

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
