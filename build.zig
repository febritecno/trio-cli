const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });

    // Default config and prompts are compiled into the binary.
    const embedded = [_][2][]const u8{
        .{ "defaults_config", "defaults/config.json" },
        .{ "defaults_builder", "defaults/prompts/builder.md" },
        .{ "defaults_scout", "defaults/prompts/scout.md" },
        .{ "defaults_advisor", "defaults/prompts/advisor.md" },
    };
    for (embedded) |e| mod.addAnonymousImport(e[0], .{ .root_source_file = b.path(e[1]) });

    const exe = b.addExecutable(.{ .name = "trio", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run trio").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}
