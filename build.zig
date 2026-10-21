const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "repro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/repro.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // Short test binaries finish while long ones, started alongside them,
    // are still running: the shape of the mox CI failure.
    const pairs = b.option(u32, "pairs", "short/long test binary pairs") orelse 8;
    const secs = b.option(i64, "secs", "how long each long test sleeps") orelse 75;
    const symptom = b.step("symptom", "run short and long test binaries at once");
    for (0..pairs) |i| {
        inline for (.{ "src/short_test.zig", "src/long_test.zig" }) |src| {
            const opts = b.addOptions();
            opts.addOption(u32, "id", @intCast(i));
            opts.addOption(i64, "secs", secs);
            const mod = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            });
            mod.addOptions("opts", opts);
            const t = b.addTest(.{ .root_module = mod });
            symptom.dependOn(&b.addRunArtifact(t).step);
        }
    }
}
