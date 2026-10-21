//! Does a process spawned on one thread keep another thread's child's
//! output pipe open?
//!
//!   repro race N     run a quick child N times while a second thread keeps
//!                    spawning children that live `sleeper_s` seconds
//!   repro usage: repro race|control|held N  the same with no second thread
//!   repro held N     each quick child leaves a sleeper holding its stdout,
//!                    so every run must count as slow: proves the detector
//!
//! Each quick child exits at once, and std.process.run returns once both of
//! its pipes reach EOF. A run that takes longer than `slow_s` waited for a
//! pipe end held by some other process, which only a long-lived sleeper can
//! be. Exit 0 always; the verdict is in the output.
const std = @import("std");
const Io = std.Io;

const sleeper_s = 5;
const slow_s = 2;
const spawn_gap_ms = 10;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "quick")) return 0;
    if (args.len >= 2 and std.mem.eql(u8, args[1], "holder")) {
        const self = try std.process.executablePathAlloc(io, a);
        _ = try std.process.spawn(io, .{ .argv = &.{ self, "sleep", "5" }, .stdin = .ignore });
        return 0;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "sleep")) {
        const s = try std.fmt.parseInt(i64, args[2], 10);
        try io.sleep(.fromSeconds(s), .awake);
        return 0;
    }
    if (args.len < 3) return usage();
    const race = std.mem.eql(u8, args[1], "race");
    const held = std.mem.eql(u8, args[1], "held");
    if (!race and !held and !std.mem.eql(u8, args[1], "control")) return usage();
    const n = try std.fmt.parseInt(usize, args[2], 10);
    const self = try std.process.executablePathAlloc(io, a);

    var spawner: Spawner = .{ .io = io, .self = self };
    const thread = if (race) try std.Thread.spawn(.{}, Spawner.loop, .{&spawner}) else null;

    var slow: usize = 0;
    var max_ns: i96 = 0;
    for (0..n) |_| {
        const t0 = Io.Clock.awake.now(io);
        const r = try std.process.run(a, io, .{
            .argv = &.{ self, if (held) "holder" else "quick" },
        });
        const dt = t0.durationTo(Io.Clock.awake.now(io)).nanoseconds;
        if (r.term != .exited or r.term.exited != 0) return error.QuickChildFailed;
        if (dt > max_ns) max_ns = dt;
        if (dt > slow_s * std.time.ns_per_s) slow += 1;
    }

    spawner.stop.store(true, .release);
    if (thread) |t| t.join();
    std.debug.print("{s}: {d} quick runs, {d} took over {d}s (slowest {d}ms); {d} sleepers spawned\n", .{
        args[1], n, slow, slow_s, @divTrunc(max_ns, std.time.ns_per_ms), spawner.spawned,
    });
    return 0;
}

fn usage() u8 {
    std.debug.print("usage: repro race|control N\n", .{});
    return 2;
}

const Spawner = struct {
    io: Io,
    self: []const u8,
    stop: std.atomic.Value(bool) = .init(false),
    spawned: usize = 0,

    fn loop(s: *Spawner) void {
        var buf: [16]u8 = undefined;
        const secs = std.fmt.bufPrint(&buf, "{d}", .{sleeper_s}) catch unreachable;
        while (!s.stop.load(.acquire)) {
            var child = std.process.spawn(s.io, .{
                .argv = &.{ s.self, "sleep", secs },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            }) catch |e| std.debug.panic("spawn sleeper: {t}", .{e});
            s.spawned += 1;
            // Reaped by a detached waiter so this thread keeps spawning.
            const t = std.Thread.spawn(.{}, reap, .{ s.io, child }) catch {
                _ = child.wait(s.io) catch {};
                continue;
            };
            t.detach();
            s.io.sleep(.fromMilliseconds(spawn_gap_ms), .awake) catch {};
        }
    }

    fn reap(io: Io, child_in: std.process.Child) void {
        var child = child_in;
        _ = child.wait(io) catch {};
    }
};
