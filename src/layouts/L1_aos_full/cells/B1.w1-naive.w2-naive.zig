// Cell L1.B1.w1-naive.w2-naive — B1 (math+decide+respawn | render),
// walk 1 naive branchy, walk 2 naive r0 render.
//
// The reference sim (generates golden/stage1.bin). Golden: bit-exact.
// Same blueprint as the other B1 cells; differs only in walk attributes
// (read the declaration diff for the attribution).

const std = @import("std");
const fw = @import("../../../framework/sim.zig");
const layout = @import("../data.zig");
const w1 = @import("../walks/w1-naive.zig");
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
        .halide_expressible = "walk1 no (branchy respawn — select is branchless); walk2 n/a (render)",
    };
    pub const step = w1.step;
    pub const render = w2.render;
};

pub const Sim = fw.Strategy(Data, H);
