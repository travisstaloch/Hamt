const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("static-hamt", .{
        .root_source_file = b.path("src/hamt.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("static-hamt", mod);
    tests.filters = if (b.option([]const u8, "test-filters", "test filters")) |f| b.dupeStrings(&.{f}) else &.{};
    b.installArtifact(tests);
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const tests_ll = b.addTest(.{
        .name = "test-ll",
        .root_source_file = b.path("src/linked-list.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_ll.filters = tests.filters;
    const run_tests_ll = b.addRunArtifact(tests_ll);
    test_step.dependOn(&run_tests_ll.step);

    const bench = b.addExecutable(.{
        .name = "bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench.root_module.addImport("static-hamt", mod);
    const options = b.addOptions();
    options.addOption(?usize, "kvs_len", b.option(usize, "kvs_len", "number of key/value entries to generate"));
    options.addOption(?usize, "max_len", b.option(usize, "max_len", "max key len"));
    options.addOption(?usize, "min_len", b.option(usize, "min_len", "min key len"));
    options.addOption(?usize, "num_iters", b.option(usize, "num_iters", "number of iterations"));
    const wordlist = if (b.option([]const u8, "wordlist_path", "used in bench.zig. path to a wordlist. otherwise random words are used.")) |wlist_path| blk: {
        const f = try std.fs.openFileAbsolute(wlist_path, .{});
        defer f.close();
        const content = try f.readToEndAlloc(b.allocator, std.math.maxInt(u32));
        const count = std.mem.count(u8, content, "\n");
        const res = try b.allocator.alloc([]const u8, count);
        var iter = std.mem.tokenizeScalar(u8, content, '\n');
        for (0..count) |i| res[i] = iter.next().?;
        break :blk res;
    } else &.{};
    options.addOption([]const []const u8, "wordlist", wordlist);
    bench.root_module.addImport("build-options", options.createModule());
    bench.root_module.strip = false;
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run bench");
    if (b.args) |args| run_bench.addArgs(args);
    bench_step.dependOn(&run_bench.step);

    b.installArtifact(bench);
}
