const std = @import("std");
const testing = std.testing;
const talloc = testing.allocator;

const hamt = @import("static-hamt");
const Hamt = hamt.Hamt;

test "basic" {
    const Keyword = enum { let, function };
    var map = try hamt.StringHamt(Keyword, .{}).init(talloc, &.{
        .{ "let", .let },
        .{ "fn", .function },
    });
    defer map.deinit(talloc);
    try testing.expectEqual(null, map.get("foo"));
    try testing.expectEqual(.let, map.get("let"));
    try testing.expectEqual(.function, map.get("fn"));
    try testing.expectEqual(null, map.get("fnn"));
}

const TestKV = struct { []const u8, u8 };
const kvs = blk: {
    const kvs_len = 100;
    const alphabet = "abcdefghijklmnopqrstuvwxyz";

    @setEvalBranchQuota(kvs_len * kvs_len * 10);
    var prng = std.Random.DefaultPrng.init(0);
    const rand = prng.random();
    var res: []const TestKV = &.{};
    const max_len = 15;
    const min_len = 2;
    for (0..kvs_len) |_| {
        const len = rand.intRangeAtMostBiased(u8, min_len, max_len);
        var buf: [max_len]u8 = undefined;
        for (0..len) |i| {
            buf[i] = alphabet[rand.intRangeLessThan(u8, 0, alphabet.len)];
        }
        const cbuf = buf;
        res = res ++ .{.{ cbuf[0..len], rand.int(u8) }};
    }

    break :blk res;
};
const test_hamt = hamt.StringHamt(u8, .{}).initComptime(kvs);
const static_map = std.StaticStringMap(u8).initComptime(kvs);

fn validate(map: anytype) !void {
    for (kvs, 0..) |kv, index| {
        const mk = static_map.get(kv[0]);
        const tk = map.get(kv[0]);
        if (mk != tk) {
            std.debug.print("\nvalidate get() error: key: '{s}' kvs index {}, values: map:{?} != map:{?}\n", .{ kv[0], index, mk, tk });
            return error.Unexpected;
        }
    }
}

test test_hamt {
    try validate(test_hamt);
}

const wordlist = [_][]const u8{
    "Andes",                "Andes's",                "Andorra",    "Andorra's",  "Andre",      "Andrea",
    "Andrea's",             "Andrei",                 "Andrei's",   "Andre's",    "Andres",     "Andres's",
    "Andretti",             "Andretti's",             "Andrew",     "Andrew's",   "Andrews",    "Andrews's",
    "Andrianampoinimerina", "Andrianampoinimerina's", "Android",    "Android's",  "Andromache", "Andromache's",
    "Andromeda",            "Andromeda's",            "Andropov",   "Andropov's", "Andy",       "Andy's",
    "Angara",               "Angara's",               "Angel",      "Angela",     "Angela's",   "Angeles",
    "Angeles's",            "Angelia",                "Angelia's",  "Angelica",   "Angelica's", "Angelico",
    "Angelico's",           "Angelina",               "Angelina's", "Angeline",   "Angeline's", "Angelique",
    "Angelique's",          "Angelita",               "Angelita's", "Angelo",
};

test "wordlist" {
    comptime var wkvs: []const TestKV = &.{};
    inline for (wordlist, 0..) |w, i| {
        wkvs = wkvs ++ .{.{ w, i }};
    }
    var map = try hamt.StringHamt(u8, .{}).init(talloc, wkvs);
    defer map.deinit(talloc);
    for (wordlist, 0..) |w, i| {
        try testing.expectEqual(@as(u8, @intCast(i)), map.get(w));
    }
}

test "runtime init" {
    var map = try hamt.StringHamt(u8, .{}).init(talloc, kvs);
    defer map.deinit(talloc);
    try validate(map);
}

test "memory usage" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var ca = @import("CountingAllocator.zig").init(gpa.allocator(), .{ .timings = true });
    const alloc = ca.allocator();

    var map = try hamt.StringHamt(u8, .{}).init(alloc, kvs);
    // ca.printSummary(std.debug.print);

    map.deinit(alloc);
    // ca.printSummary(std.debug.print);
}

fn checkAllocs(alloc: std.mem.Allocator) !void {
    var map = try hamt.StringHamt(u8, .{}).init(alloc, kvs);
    try map.put(alloc, "foo", 1);
    _ = try map.getOrPut(alloc, "foo");
    defer map.deinit(talloc);
}

test "check alloc failures" {
    try std.testing.checkAllAllocationFailures(talloc, checkAllocs, .{});
}

test "int keys" {
    const Context = struct {
        pub fn hash(_: @This(), k: u8) u32 {
            return k;
        }
        pub fn eql(_: @This(), a: u8, b: u8, b_index: u32) bool {
            _ = b_index;
            return a == b;
        }
    };

    var map = try hamt.Hamt(u8, u8, Context, .{}).init(talloc, &.{
        .{ 0, 0 },
        .{ 1, 1 },
    });
    defer map.deinit(talloc);
    try testing.expectEqual(0, map.get(0));
    try testing.expectEqual(1, map.get(1));
    try testing.expectEqual(null, map.get(2));
}

test "enum keys" {
    const E = enum { foo, bar, baz };
    const Context = struct {
        pub fn hash(_: @This(), k: E) u32 {
            return @intFromEnum(k);
        }

        pub fn eql(_: @This(), a: E, b: E, b_index: u32) bool {
            _ = b_index;
            return a == b;
        }
    };

    var map = try hamt.Hamt(E, u8, Context, .{}).init(talloc, &.{
        .{ .foo, 0 },
        .{ .bar, 1 },
    });
    defer map.deinit(talloc);
    try testing.expectEqual(1, map.get(.bar));
    try testing.expectEqual(2, map.leaves.items.len);
    try testing.expectEqual(0, map.get(.foo));
    try testing.expectEqual(null, map.get(.baz));
}

test "std.array_hash_map.StringContext" {
    var map = try hamt.Hamt([]const u8, u8, std.array_hash_map.StringContext, .{}).init(talloc, kvs);
    defer map.deinit(talloc);
    try validate(map);
}

test "AutoHamt" {
    var map = try hamt.AutoHamt(u8, u8, .{}).init(talloc, &.{ .{ 0, 0 }, .{ 1, 1 } });
    defer map.deinit(talloc);
    try testing.expectEqual(0, map.get(0));
    try testing.expectEqual(1, map.get(1));
}

test "put, getOrPut" {
    var map = try hamt.StringHamt(u8, .{}).init(talloc, &.{});
    defer map.deinit(talloc);

    const key_a = "existing";
    try map.put(talloc, key_a, 1);
    try testing.expectEqual(1, map.get(key_a));
    const gop_a = try map.getOrPut(talloc, key_a);
    try testing.expect(gop_a.found_existing);
    gop_a.kv_ptr[1] = 10;
    try testing.expectEqual(10, map.get(key_a));

    const key_b = "new";
    const gop_b = try map.getOrPut(talloc, key_b);
    try testing.expect(!gop_b.found_existing);
    gop_b.kv_ptr[1] = 2;
    try testing.expectEqual(2, map.get(key_b));
}
