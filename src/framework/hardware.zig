// hardware.zig — runtime cache/memory profile via sysctl.
// Printed at the start of every bench run so the numbers anchor the DOD story.
// (Consumed programmatically here; scripts/hardware_json.py is the JSON counterpart.)

const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");

pub const Facts = struct {
    cpu: [128]u8 = undefined,
    cpu_len: usize = 0,
    cachelinesize: u64 = 0,
    l1dcachesize: u64 = 0,
    l1icachesize: u64 = 0,
    l2cachesize: u64 = 0,
    l3cachesize: u64 = 0,
    pagesize: u64 = 0,
    memsize: u64 = 0,
    physicalcpu: u64 = 0,
    logicalcpu: u64 = 0,
};

pub fn detect() Facts {
    // Comptime switch: only the branch for THIS OS is semantically analyzed, so
    // the macOS sysctl calls (and the Linux syscall helpers) are never even
    // referenced on the other OS — which is what keeps this linking on both.
    var f = Facts{};
    switch (builtin.os.tag) {
        .macos => detectDarwin(&f),
        .linux => detectLinux(&f),
        // Other OSes: leave zeros — the authoritative profile is hardware.json
        // (scripts/hardware_json.py), which this in-process Facts only echoes.
        else => {},
    }
    return f;
}

fn detectDarwin(f: *Facts) void {
    f.cpu_len = readSysctlBytes("machdep.cpu.brand_string", &f.cpu);
    f.cachelinesize = readSysctlU64("hw.cachelinesize");
    f.l1dcachesize = readSysctlU64("hw.l1dcachesize");
    f.l1icachesize = readSysctlU64("hw.l1icachesize");
    f.l2cachesize = readSysctlU64("hw.l2cachesize");
    f.l3cachesize = readSysctlU64("hw.l3cachesize");
    f.pagesize = readSysctlU64("hw.pagesize");
    f.memsize = readSysctlU64("hw.memsize");
    f.physicalcpu = readSysctlU64("hw.physicalcpu");
    f.logicalcpu = readSysctlU64("hw.logicalcpu");
}

/// Linux: the bench binary stays I/O-free (no /proc parser in-process). The
/// authoritative cache/memory/cpu profile comes from scripts/hardware_json.py,
/// which already reads /proc/cpuinfo + /proc/meminfo + nproc. Here we fill only
/// what is free at runtime (page size, logical CPU count, the de-facto x86
/// cache-line size) so the binary links on Linux and the `--bandwidth` microbench
/// (which sizes its buffer off L3/L2 with a safe 256 MB floor, and strides by
/// cachelinesize or 64) runs correctly. (This function is never analyzed on macOS.)
fn detectLinux(f: *Facts) void {
    f.pagesize = @intCast(std.heap.pageSize());
    f.cachelinesize = 64; // x86_64 de-facto; hardware.json carries the real value.
    f.logicalcpu = linuxLogicalCpus();
    // sched_getaffinity returns LOGICAL cpus (SMT threads included), and there
    // is no I/O-free way to count physical cores on Linux. We deliberately set
    // physicalcpu = logicalcpu (so on an SMT part this over-reports physical
    // cores) rather than parse /sys — the authoritative value lives in
    // hardware.json (scripts/hardware_json.py). Treat in-process
    // Facts.physicalcpu on Linux as "logical only"; do NOT divide
    // logical/physical to detect SMT.
    f.physicalcpu = f.logicalcpu;
}

fn linuxLogicalCpus() u64 {
    var set: std.os.linux.cpu_set_t = std.mem.zeroes(std.os.linux.cpu_set_t);
    const size: u32 = @intCast(@sizeOf(std.os.linux.cpu_set_t));
    if (std.os.linux.sched_getaffinity(0, size, &set) != 0) return 0;
    var count: u64 = 0;
    for (set) |word| count += @intCast(@popCount(word));
    return count;
}

pub fn print(f: Facts) void {
    std.debug.print("=== Hardware ===\n\n", .{});
    std.debug.print("  cpu              : {s}\n", .{f.cpu[0..f.cpu_len]});
    std.debug.print("  cores            : physical={d} logical={d}\n", .{ f.physicalcpu, f.logicalcpu });
    std.debug.print("  hw.cachelinesize = {d}\n", .{f.cachelinesize});
    std.debug.print("  hw.l1dcachesize  = {d}\n", .{f.l1dcachesize});
    std.debug.print("  hw.l1icachesize  = {d}\n", .{f.l1icachesize});
    std.debug.print("  hw.l2cachesize   = {d}\n", .{f.l2cachesize});
    std.debug.print("  hw.l3cachesize   = {d}\n", .{f.l3cachesize});
    std.debug.print("  hw.pagesize      = {d}\n", .{f.pagesize});
    std.debug.print("  hw.memsize       = {d}\n", .{f.memsize});
    std.debug.print("\n", .{});
}

fn readSysctlU64(name: [:0]const u8) u64 {
    var value: u64 = 0;
    var size: usize = @sizeOf(u64);
    const c_name: [*:0]const u8 = name.ptr;
    if (std.c.sysctlbyname(c_name, @ptrCast(&value), &size, null, 0) != 0) return 0;
    return value;
}

fn readSysctlBytes(name: [:0]const u8, out: []u8) usize {
    var size: usize = out.len;
    const c_name: [*:0]const u8 = name.ptr;
    if (std.c.sysctlbyname(c_name, @ptrCast(out.ptr), &size, null, 0) != 0) return 0;
    if (size > 0 and size <= out.len) {
        // trim trailing null
        if (out[size - 1] == 0) size -= 1;
        return size;
    }
    return 0;
}
