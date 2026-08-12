// Minimal persistent worker pool for .par cells (layout-matrix.md §2.7, §4.7).
//
// This Zig 0.17-dev std has no Thread.Pool / Mutex / Condition / Futex, so
// this is a hand-rolled barrier-dispatch pool on raw std.Thread + the macOS
// ulock primitives directly (the same syscalls the old std.Thread.Futex used
// on Darwin). The design:
//
//   - Persistent workers spawned at create() (n_workers - 1 threads; the
//     caller participates as worker 0, so a 10-worker run uses 9 spawned
//     threads). The Pool is heap-allocated at a STABLE address — workers
//     hold a pointer to it (an earlier version returned the struct by value
//     after spawning: dangling stack pointer, segfault/hang. Don't do that.)
//   - run() publishes ONE task (a function + context); every worker executes
//     it for its own worker index. The task computes its chunk from
//     (worker, n_workers) — keeps the pool policy-free.
//   - generation counter + ulock wake-all for dispatch; done counter + ulock
//     for completion. A short spin precedes each futex wait (dispatch
//     latency matters at small N).
//   - run() is NOT re-entrant; the next run() starts only after the previous
//     done barrier (all workers accounted for), so there are no
//     missed-generation races.
//
// Determinism contract for .par cells: tasks must not draw from the sim's
// spawn RNG. Kill decisions under q>0 use per-chunk kill RNGs
// (deterministic per chunk, independent of scheduling).

const std = @import("std");
const builtin = @import("builtin");

extern "c" fn __ulock_wait(op: u32, addr: *const anyopaque, value: u64, timeout_us: u32) c_int;
extern "c" fn __ulock_wake(op: u32, addr: *const anyopaque, wake_value: u64) c_int;

const UL_COMPARE_AND_WAIT: u32 = 1;
const ULF_WAKE_ALL: u32 = 0x00000100;
const SPIN: usize = 200; // spin iterations before futex wait (~sub-µs)

pub const TaskFn = fn (ctx: *anyopaque, worker: usize, n_workers: usize) void;

pub const Pool = struct {
    threads: []std.Thread,
    n_workers: usize, // total participants (spawned threads + caller)
    generation: std.atomic.Value(u32) = .init(0),
    done_count: std.atomic.Value(u32) = .init(0),
    shutdown: std.atomic.Value(bool) = .init(false),
    task_fn: ?*const TaskFn = null,
    task_ctx: *anyopaque = undefined,

    /// Create a pool with n_workers - 1 persistent threads at a stable heap
    /// address. n_workers <= 1 is legal (no threads; run() executes inline).
    pub fn create(alloc: std.mem.Allocator, n_workers: usize) !*Pool {
        const self = try alloc.create(Pool);
        self.* = .{
            .threads = &.{},
            .n_workers = @max(n_workers, 1),
        };
        if (self.n_workers <= 1) return self;
        self.threads = try alloc.alloc(std.Thread, self.n_workers - 1);
        var spawned: usize = 0;
        errdefer {
            self.shutdown.store(true, .monotonic);
            _ = self.generation.fetchAdd(1, .release);
            wakeAll(&self.generation);
            for (self.threads[0..spawned]) |t| t.join();
            alloc.free(self.threads);
            alloc.destroy(self);
        }
        for (self.threads, 1..) |*t, idx| {
            t.* = try std.Thread.spawn(.{}, workerMain, .{ self, idx });
            spawned += 1;
        }
        return self;
    }

    /// Execute `f(ctx, worker, n_workers)` on every worker (0..n_workers),
    /// returning when all have finished. Caller participates as worker 0.
    pub fn run(self: *Pool, ctx: *anyopaque, comptime f: TaskFn) void {
        if (self.n_workers == 1) {
            f(ctx, 0, 1);
            return;
        }
        self.task_ctx = ctx;
        self.task_fn = f;
        self.done_count.store(0, .monotonic);
        _ = self.generation.fetchAdd(1, .release); // publish task
        wakeAll(&self.generation);

        f(ctx, 0, self.n_workers); // caller is worker 0

        // Done barrier: wait for the spawned workers.
        const want: u32 = @intCast(self.n_workers - 1);
        var spins: usize = 0;
        while (true) {
            const cur = self.done_count.load(.acquire);
            if (cur == want) break;
            if (spins < SPIN) {
                std.atomic.spinLoopHint();
                spins += 1;
            } else {
                waitWhile(&self.done_count, cur); // sleep only while still `cur`
            }
        }
    }

    pub fn destroy(self: *Pool, alloc: std.mem.Allocator) void {
        if (self.threads.len != 0) {
            self.shutdown.store(true, .monotonic);
            _ = self.generation.fetchAdd(1, .release);
            wakeAll(&self.generation);
            for (self.threads) |t| t.join();
            alloc.free(self.threads);
        }
        alloc.destroy(self);
    }

    fn workerMain(self: *Pool, idx: usize) void {
        var seen: u32 = 0;
        while (true) {
            // Wait for a new generation (or shutdown).
            var spins: usize = 0;
            while (true) {
                const g = self.generation.load(.acquire);
                if (g != seen) {
                    seen = g;
                    break;
                }
                if (spins < SPIN) {
                    std.atomic.spinLoopHint();
                    spins += 1;
                } else {
                    waitWhile(&self.generation, g);
                }
            }
            if (self.shutdown.load(.acquire)) return;
            const f = self.task_fn.?;
            f(self.task_ctx, idx, self.n_workers);
            _ = self.done_count.fetchAdd(1, .release);
            wakeAll(&self.done_count); // wake the waiter (cheap if none)
        }
    }
};

fn waitWhile(v: *const std.atomic.Value(u32), cur: u32) void {
    // Sleep only if the value is still `cur` (race-free re-check inside the
    // syscall). Returns on any change, spurious wake, or error — the caller
    // re-reads. Only the branch for THIS OS is analyzed (comptime switch), so
    // the ulock externs are never referenced on Linux and the futex call is
    // never referenced on macOS.
    switch (builtin.os.tag) {
        .macos => {
            _ = __ulock_wait(UL_COMPARE_AND_WAIT, @ptrCast(&v.raw), cur, 0);
        },
        .linux => {
            const op: std.os.linux.FUTEX_OP = .{ .cmd = .WAIT, .private = true };
            _ = std.os.linux.futex_3arg(@ptrCast(&v.raw), op, cur);
        },
        // No parking primitive: callers already spin (SPIN) before reaching here,
        // so a no-op keeps the pool correct (busy) on other OSes.
        else => {},
    }
}

fn wakeAll(v: *const std.atomic.Value(u32)) void {
    switch (builtin.os.tag) {
        .macos => {
            _ = __ulock_wake(UL_COMPARE_AND_WAIT | ULF_WAKE_ALL, @ptrCast(&v.raw), 0);
        },
        .linux => {
            const op: std.os.linux.FUTEX_OP = .{ .cmd = .WAKE, .private = true };
            _ = std.os.linux.futex_3arg(@ptrCast(&v.raw), op, std.math.maxInt(u32));
        },
        else => {},
    }
}
