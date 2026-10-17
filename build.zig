const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The CLI and its tests run on the machine doing the build, not on the
    // resolved target: a consumer cross-compiles its own artifacts and still
    // needs to RUN this linter over its tree.
    const host = b.graph.host;

    _ = b.addModule("zginlint", .{
        .root_source_file = b.path("src/zginlint.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zginlint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = host,
            .optimize = optimize,
        }),
    });
    // `installArtifact` is what makes a consumer's
    // `b.dependency("zginlint", ...).artifact("zginlint")` resolve.
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_root.zig"),
            .target = host,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run the zginlint unit tests").dependOn(&run_tests.step);

    // The linter's own gate: zero findings on this repository's source.
    // `has_side_effects` is load-bearing — a Run step is keyed by its binary
    // and argv, NOT by the tree it reads.

    const lint = b.step("lint", "Lint this repository's own source (zero findings)");
    const run_lint = b.addRunArtifact(exe);
    run_lint.setCwd(b.path("."));
    run_lint.addArgs(&.{ "src", "build.zig" });
    run_lint.has_side_effects = true;
    lint.dependOn(&run_lint.step);
}
