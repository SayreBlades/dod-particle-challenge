// layouts/common/devec.zig — the scalar de-vectorization barrier.
//
// `box` is an OPAQUE identity: the value emerges from an asm output operand,
// so the optimizer cannot prove it equals the input. That defeats LLVM's SLP
// auto-vectorizer — producer and consumer chains can't be packed across a box,
// which is what forces a loop to stay genuinely scalar (no q/y-register math).
//
// Used by the LP1-scalar algorithms to isolate the "schedule = scalar" axis
// from the algorithm-family axis: the boxed loop is otherwise identical to its
// auto-vec sibling, so any perf delta is attributable to vectorization alone.
// Box every scalar intermediate you want kept scalar; `box` compiles to a
// register move (or is elided into the surrounding code) at runtime — the cost
// is purely an optimization barrier, not a real instruction.
//
// The register-class constraint is arch-specific (NEON "w" on aarch64, SSE "x"
// on x86_64). The comptime switch means only the live arch's prong is
// semantically analyzed, so the others never need to link. An arch with no
// prong fails the build loudly (via @compileError) rather than silently letting
// the caller re-vectorize.
//
// f32 only for now — the asm constraints are single-precision. Add a comptime-T
// switch (with matching constraints per element type) if a double-precision or
// integer barrier is ever needed.

const std = @import("std");
const builtin = @import("builtin");

/// Opaque identity through a SIMD register: an optimization barrier that
/// prevents LLVM from proving `result == x`, so SLP can't vectorize across it.
/// Compiles to a register move (or is folded into the surrounding code) at
/// runtime — the cost is purely an optimization barrier, not a real instruction.
pub inline fn box(x: f32) f32 {
    return switch (builtin.cpu.arch) {
        // Input is tied to the output register via the matching constraint
        // "0": with an empty template the asm writes nothing, so UNTIED
        // operands (=x out + x in) would leave the output register as whatever
        // LLVM allocated (garbage) — which only happens to be correct when the
        // ReleaseFast coalescer assigns both to the same register. Tying here
        // forces input==output at the IR level, so the value is preserved in
        // EVERY build mode; the volatile asm still can't be optimized through,
        // so the barrier is intact.
        .aarch64 => asm volatile (""
            : [ret] "=w" (-> f32)
            : [in] "0" (x)
        ),
        .x86_64 => asm volatile (""
            : [ret] "=x" (-> f32)
            : [in] "0" (x)
        ),
        else => @compileError(std.fmt.comptimePrint(
            "devec.box() has no SIMD register constraint for {s} — add a prong " ++
                "keyed on builtin.cpu.arch. This guard exists so callers cannot " ++
                "silently re-vectorize across the barrier.",
            .{@tagName(builtin.cpu.arch)},
        )),
    };
}
