const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tsan = b.option(bool, "tsan", "Build tests with ThreadSanitizer") orelse false;

    const mod = b.addModule("spectrolith", .{
        .root_source_file = b.path("src/spectrolith.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true, // file I/O and locks go straight to libc
    });

    // Unit tests (all `test` blocks reachable from spectrolith.zig).
    const unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/spectrolith.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_thread = tsan,
    }) });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // Crash test: fork, write, SIGKILL, reopen, verify.
    const crash = b.addExecutable(.{
        .name = "crashtest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/crashtest.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "spectrolith", .module = mod }},
        }),
    });
    b.installArtifact(crash);
    const crash_run = b.addRunArtifact(crash);
    crash_run.addPassthruArgs();
    const crash_step = b.step("crashtest", "Run the kill -9 crash test (args: rounds seed)");
    crash_step.dependOn(&crash_run.step);

    // Numerical check: solve on a snapshot, export both for scipy to compare.
    const check = b.addExecutable(.{
        .name = "fiedlercheck",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fiedlercheck.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "spectrolith", .module = mod }},
        }),
    });
    b.installArtifact(check);

    // Benchmarks. -Drocksdb=true links the baseline; `rocksdb_prefix` says where
    // its headers and library live if the system does not know.
    const rocksdb = b.option(bool, "rocksdb", "Link RocksDB into the benchmark baseline") orelse false;
    const rocksdb_prefix = b.option([]const u8, "rocksdb_prefix", "Install prefix of RocksDB");
    const bench_options = b.addOptions();
    bench_options.addOption(bool, "rocksdb", rocksdb);
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = rocksdb,
        .imports = &.{.{ .name = "spectrolith", .module = mod }},
    });
    bench_mod.addOptions("bench_options", bench_options);
    if (rocksdb) {
        const rocksdb_c = b.addTranslateC(.{
            .root_source_file = b.addWriteFiles().add("rocksdb_c.h", "#include <rocksdb/c.h>\n"),
            .target = target,
            .optimize = optimize,
        });
        if (rocksdb_prefix) |p| {
            rocksdb_c.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{p}) });
            bench_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{p}) });
        }
        bench_mod.addImport("rocksdb_c", rocksdb_c.createModule());
        bench_mod.linkSystemLibrary("rocksdb", .{});
    }
    b.installArtifact(b.addExecutable(.{ .name = "bench", .root_module = bench_mod }));
}
