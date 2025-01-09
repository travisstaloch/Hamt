const std = @import("std");
const assert = std.debug.assert;

const StringHamt = @import("static-hamt").StringHamt;

const TestKV = struct { []const u8, u8 };
const kvs = blk: {
    const kvs_len = @import("build-options").kvs_len orelse 100;
    @setEvalBranchQuota(10 * kvs_len * kvs_len);

    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();
    const wordlist = @import("build-options").wordlist;
    if (wordlist.len > 0) {
        var res: [kvs_len]TestKV = undefined;
        for (0..kvs_len) |j| {
            res[j] = .{ wordlist[rand.intRangeLessThan(usize, 0, wordlist.len)], rand.int(u8) };
        }
        const fin_res = res;
        break :blk &fin_res;
    } else {
        const alphabet = "abcdefghijklmnopqrstuvwxyz";
        var res: [kvs_len]TestKV = undefined;
        const max_len = @import("build-options").max_len orelse 15;
        const min_len = @import("build-options").min_len orelse 2;
        for (0..kvs_len) |j| {
            const len = rand.intRangeAtMostBiased(u8, min_len, max_len);
            var buf: [max_len]u8 = undefined;
            for (0..len) |i| {
                buf[i] = alphabet[rand.intRangeLessThan(u8, 0, alphabet.len)];
            }
            const cbuf = buf;
            res[j] = .{ cbuf[0..len], rand.int(u8) };
        }
        const fin_res = res;
        break :blk &fin_res;
    }
};

const test_hamt = StringHamt(u8, .{}).initComptime(kvs);
const static_map = std.StaticStringMap(u8).initComptime(kvs);
const num_iters = @import("build-options").num_iters orelse 100;

/// hamt and std_static_map use initComptime() and don't include time of init()
const Bench = enum {
    hamt,
    hamt_runtime_init,
    std_static_map,
    std_static_map_runtime_init,
    std_string_hashmap_runtime_init,
};

fn usage(args: []const []const u8) void {
    std.log.err("Usage: {s} {s}\n", .{ std.fs.path.basename(args[0]), std.meta.fieldNames(Bench) });
}

pub fn main() !void {
    var gpa = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    if (args.len < 2) {
        usage(args);
        return error.MissingArg;
    }
    const bench = std.meta.stringToEnum(Bench, args[1]) orelse {
        usage(args);
        return error.InvalidArg;
    };
    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();
    switch (bench) {
        .hamt => run(test_hamt, bench, rand),
        .hamt_runtime_init => {
            const map = try StringHamt(u8, .{}).init(alloc, kvs);
            run(map, bench, rand);
        },
        .std_static_map => run(static_map, bench, rand),
        .std_static_map_runtime_init => {
            const map = try std.StaticStringMap(u8).init(kvs, alloc);
            run(map, bench, rand);
        },
        .std_string_hashmap_runtime_init => {
            var map = std.StringHashMap(u8).init(alloc);
            for (kvs) |kv| {
                try map.put(kv[0], kv[1]);
            }
            run(map, bench, rand);
        },
    }

    // for (kvs) |kv| std.debug.print("{s}:{}\n", .{ kv[0], kv[1] });
}

fn run(map: anytype, bench: Bench, rand: std.Random) void {
    var timer = std.time.Timer.start() catch unreachable;
    for (0..num_iters) |_| {
        for (kvs) |kv| {
            if (rand.boolean()) {
                const mv = map.get(kv[0]);
                std.mem.doNotOptimizeAway(mv);
                assert(mv != null);
            } else {
                var buf: [32]u8 = undefined;
                @memcpy(buf[0..kv[0].len], kv[0]);
                @memcpy(buf[kv[0].len..][0..3], "foo");
                const mv = map.get(buf[0 .. kv[0].len + 3]);
                std.mem.doNotOptimizeAway(mv);
                assert(mv == null);
            }
        }
    }
    std.debug.print("{s} took {}\n", .{ @tagName(bench), std.fmt.fmtDuration(timer.lap()) });
}
