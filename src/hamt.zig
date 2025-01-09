const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const assert = std.debug.assert;

const ll = @import("array-linked-list.zig");

pub const Options = struct {
    max_collisions: u8 = 8,
    reHash: fn (context: anytype, key: anytype, prev_hash: u32) u32 = reHash,
};

/// hashFn possibilities
/// * std.hash.Wyhash.hash
/// * std.hash.Murmur2_32.hash
/// * std.hash.Adler32.hash
/// * std.hash.Fnv1a_32.hash
/// * std.hash.CityHash32.hash
/// * std.hash.Murmur3_32.hash
/// * hashKey,
pub fn StringContext(comptime hashFn: fn ([]const u8) u32) type {
    return struct {
        pub fn hash(_: @This(), s: []const u8) u32 {
            return hashFn(s);
        }

        pub fn eql(_: @This(), a: []const u8, b: []const u8, b_index: u32) bool {
            _ = b_index;
            return mem.eql(u8, a, b);
        }
    };
}

pub fn hashString(s: []const u8) u32 {
    var h: u32 = @truncate(s.len);
    for (s) |c| {
        h = h *% 31 +% c;
    }
    return h;
}

// no idea if this hash fn is any good. found here:
// from https://infoscience.epfl.ch/server/api/core/bitstreams/f66a3023-2cd0-4b26-af6e-91a9a6ae7450/content
fn hashKey(key: []const u8) u32 {
    var a: u32 = 31415;
    const b = 27183;
    var h: u32 = 0;
    for (key) |c| {
        h = a *% h +% c;
        a *%= b;
    }
    return h;
}

fn reHash(context: anytype, key: anytype, prev_hash: u32) u32 {
    return prev_hash ^ context.hash(key);
}

const Id = enum(u32) {
    null = std.math.maxInt(u32),
    _,

    pub fn fromInt(i: u32) Id {
        return @enumFromInt(i);
    }
    pub fn int(id: Id) u32 {
        return @intFromEnum(id);
    }
};

pub fn AutoHamt(comptime K: type, comptime V: type, comptime options: Options) type {
    return Hamt(K, V, std.array_hash_map.AutoContext(K), options);
}

pub fn StringHamt(comptime V: type, comptime options: Options) type {
    return Hamt([]const u8, V, std.array_hash_map.StringContext, options);
}

pub fn Hamt(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
    comptime options: Options,
) type {
    return struct {
        /// branch and node indices combined.  msb of each u32 indicates branch
        /// or leaf where 0 is branch and 1 is leaf.
        nodes: std.ArrayListUnmanaged(u32),
        branches: std.ArrayListUnmanaged(Branch),
        leaves: std.ArrayListUnmanaged(KV),
        /// Branch.first is a reference into this list.
        /// storing branch_nodes in a single array list reduces memory usage by
        /// around 3x vs each Branch having its own linked list in the test "memory usage".
        branch_nodes: ll.ArrayLinkedList(u32),
        context: Context,

        const Self = @This();
        const leaf_mask: u32 = 1 << 31;
        const leaf_mask_complement = ~leaf_mask;
        const is_ctx_zero_sized = @sizeOf(Context) == 0;

        pub const Branch = struct {
            /// a bitset of which child nodes are present
            bits: u32,
            /// id of the first of child in the 'branch_nodes' linked list.
            first: ll.Id,
            pub const empty: Branch = .{ .bits = 0, .first = .null };
        };
        pub const KV = struct { K, V };

        pub fn init(allocator: Allocator, entries: []const KV) !Self {
            if (!is_ctx_zero_sized) @compileError("Context not zero sized.  use initContext() instead.");
            return try initContext(allocator, entries, undefined);
        }

        pub fn deinit(hamt: *Self, allocator: Allocator) void {
            hamt.nodes.deinit(allocator);
            hamt.branches.deinit(allocator);
            hamt.leaves.deinit(allocator);
            hamt.branch_nodes.deinit(allocator);
        }

        pub fn initContext(allocator: Allocator, entries: []const KV, context: Context) !Self {
            var hamt: Self = .{
                .nodes = .{},
                .branches = .{},
                .leaves = .{},
                .branch_nodes = .empty,
                .context = context,
            };
            errdefer hamt.deinit(allocator);

            try hamt.nodes.append(allocator, 0);
            try hamt.branches.append(allocator, .{ .bits = 0, .first = .null });
            if (entries.len == 0) return hamt;

            // FIXME - calc better caps
            try hamt.nodes.ensureTotalCapacity(allocator, entries.len);
            try hamt.branches.ensureTotalCapacity(allocator, entries.len);
            try hamt.leaves.ensureTotalCapacity(allocator, entries.len);

            for (entries) |e| {
                try hamt.put(allocator, e[0], e[1]);
            }

            return hamt;
        }

        pub fn put(hamt: *Self, allocator: Allocator, key: K, value: V) !void {
            debug("-- put(" ++ kfmt ++ ", {})\n", .{ key, value });
            const gop = try hamt.getOrPut(allocator, key);
            gop.kv_ptr[1] = value;
        }

        const GetOrPutResult = struct {
            found_existing: bool,
            kv_ptr: *KV,
        };

        pub fn getOrPut(hamt: *Self, allocator: Allocator, key: K) !GetOrPutResult {
            debug("-- getOrPut(" ++ kfmt ++ ")\n", .{key});
            var prev_hash: u32 = 0;
            var collisions: u8 = 0;
            while (collisions < options.max_collisions) : (collisions += 1) {
                const hash = options.reHash(hamt.context, key, 0);
                return hamt.getOrPutHash(allocator, hash, key) catch |e| switch (e) {
                    error.Collision => {
                        prev_hash = hash;
                        continue;
                    },
                    else => {
                        if (!@import("builtin").is_test)
                            std.log.err("{s}. key " ++ kfmt, .{ @errorName(e), key });
                        return e;
                    },
                };
            }
            return error.TooManyCollisions;
        }

        fn getOrPutHash(
            hamt: *Self,
            allocator: Allocator,
            hash: u32,
            key: K,
        ) !GetOrPutResult {
            debug("  getOrPutHash(" ++ kfmt ++ ", {})\n", .{ key, hash });
            var h = hash;
            var node_idx: u32 = 0;

            while (h > 0) {
                const chunk = h & 0b11111;
                const id = hamt.nodes.items[node_idx];
                debug(
                    "  id {} idx {}/{} bs {} ls {} chunk {} h {}/{}\n",
                    .{ id, node_idx, hamt.nodes.items.len, hamt.branches.items.len, hamt.leaves.items.len, chunk, h, h >> 5 },
                );
                h >>= 5;
                if (id < leaf_mask) { // branch
                    const bit = @as(u32, 1) << @intCast(chunk);
                    const branch = hamt.branches.items[id];
                    const child_index = @popCount(branch.bits & (bit - 1));
                    var children = hamt.branch_nodes.subListFrom(branch.first);
                    // debug("bitset {b:0>32}\n   bit {b:0>32}\n", .{ branch.bits, bit });
                    // debug("  mask {b:0>32}\n index {}/{}\n", .{ bit - 1, index, @popCount(branch.bits) });
                    debug("  child_index {}/{} existing {}\n", .{ child_index, @popCount(branch.bits), branch.bits & bit != 0 });

                    if (branch.bits & bit != 0) {
                        // existing child
                        node_idx = children.nth(child_index).?;
                        const nextid = hamt.nodes.items[node_idx];
                        if (h == 0 and nextid >= leaf_mask) {
                            const lid = nextid ^ leaf_mask;
                            debug("  nextid 0x{x}:{b} lid {}\n", .{ nextid, nextid, lid });
                            return if (hamt.context.eql(key, hamt.leaves.items[lid][0], lid))
                                .{
                                    .found_existing = true,
                                    .kv_ptr = &hamt.leaves.items[lid],
                                }
                            else
                                error.Collision;
                        }
                    } else {
                        // insert new child
                        const new_node: u32 = if (h == 0) blk: {
                            const len: u32 = @intCast(hamt.leaves.items.len);
                            assert(len < leaf_mask);
                            break :blk len | leaf_mask;
                        } else blk: {
                            const len = hamt.branches.items.len;
                            assert(len < leaf_mask); // msb must be clear
                            try hamt.branches.append(allocator, .empty);
                            break :blk @intCast(len);
                        };
                        debug("  index {} branch children {}\n", .{ child_index, children.fmt() });

                        node_idx = @intCast(hamt.nodes.items.len);
                        _ = try children.appendAt(allocator, child_index, node_idx);
                        hamt.branches.items[id] = .{ .bits = branch.bits | bit, .first = children.first };
                        hamt.branch_nodes.nodes = children.nodes;
                        try hamt.nodes.append(allocator, new_node);
                    }
                } else return error.Leaf;
            }

            debug("  node_idx {} appending leaf " ++ kfmt ++ "\n", .{ node_idx, key });
            const len = hamt.leaves.items.len;
            try hamt.leaves.append(allocator, .{ key, undefined });

            return .{
                .found_existing = false,
                .kv_ptr = &hamt.leaves.items[len],
            };
        }

        pub fn get(hamt: Self, key: K) ?V {
            return if (hamt.getIndex(key)) |i| hamt.leaves.items[i][1] else null;
        }

        /// return an index into hamt.leaves
        pub fn getIndex(hamt: Self, key: K) ?u32 {
            var prev_hash: u32 = 0;
            var collisions: u8 = 0;
            while (collisions < options.max_collisions) : (collisions += 1) {
                const hash = options.reHash(hamt.context, key, prev_hash);
                debug("get(" ++ kfmt ++ ") {} hashes {}/{}\n", .{ key, collisions, hash, prev_hash });
                return hamt.getIndexImpl(key, hash) catch |e| switch (e) {
                    error.Missing => return null,
                    error.Collision => {
                        prev_hash = hash;
                        continue;
                    },
                    // else => std.debug.panic("unexpected error {s}", .{@errorName(e)}),
                };
            }
            return null;
        }

        fn getIndexImpl(hamt: Self, key: K, init_hash: u32) !u32 {
            var h = init_hash;
            var id: u32 = undefined;
            var node_idx: u32 = 0;
            debug("get(" ++ kfmt ++ ")\n", .{key});
            while (true) {
                const chunk: u5 = @truncate(h);
                debug("-- chunk {} h {} --\n", .{ chunk, h });
                h >>= 5;
                id = hamt.nodes.items[node_idx];
                debug("-- id {} leaf {}--\n", .{ id, id >= leaf_mask });
                if (id < leaf_mask) {
                    const branch = hamt.branches.items[id];
                    const bit = @as(u32, 1) << chunk;
                    const bitset = branch.bits;
                    const len = @popCount(branch.bits);
                    const children = hamt.branch_nodes.subListFrom(branch.first);
                    debug("bitset {b:0>32}\n   bit {b:0>32}\n", .{ bitset, bit });
                    if (bitset & bit != 0) {
                        //found
                        const index = @popCount(bitset & (bit - 1));
                        // debug("  mask {b:0>32}\n index {}/{}\n", .{ bit - 1, index, len });
                        debug("  index {}/{} node_idx {} children {}\n", .{ index, len, node_idx, children.fmt() });
                        // TODO optimize. maybe use nthUnchecked() when trusted
                        node_idx = children.nth(index).?;
                    } else break;
                } else break; // leaf
            }

            if (h == 0) {
                const idx = id & leaf_mask_complement;
                const kv = hamt.leaves.items[idx];
                return if (hamt.context.eql(kv[0], key, idx))
                    idx
                else
                    error.Collision;
            } else return error.Missing;
        }

        pub inline fn initComptime(comptime entries: anytype) Self {
            if (!is_ctx_zero_sized) @compileError("Context not zero sized.  use initContextComptime() instead.");
            return initContextComptime(entries, undefined);
        }

        const kfmt = if (K == []const u8 or K == []u8) "'{s}'" else "{}";

        pub inline fn initContextComptime(comptime entries: anytype, comptime context: Context) Self {
            comptime {
                @setEvalBranchQuota(entries.len * 300);

                var hamt: Self = .{
                    .nodes = .{},
                    .branches = .{},
                    .leaves = .{},
                    .branch_nodes = .empty,
                    .context = context,
                };
                var init_ns = [1]u32{0};
                var init_bs = [1]Branch{Branch.empty};
                hamt.nodes.items = &init_ns;
                hamt.branches.items = &init_bs;

                for (entries, 0..) |e, ei| {
                    debug("-- inserting {} " ++ kfmt ++ ": {}\n", .{ ei, e[0], e[1] });
                    hamt.putComptime(e[0], e[1]);
                }

                const fin_branches = hamt.branches.items[0..].*;
                const fin_leaves = hamt.leaves.items[0..].*;
                const fin_nodes = hamt.nodes.items[0..].*;
                hamt.branches.items = @constCast(&fin_branches);
                hamt.leaves.items = @constCast(&fin_leaves);
                hamt.nodes.items = @constCast(&fin_nodes);
                return hamt;
            }
        }

        // TODO add getOrPutComptime() and use it here
        pub inline fn putComptime(
            comptime hamt: *Self,
            comptime key: K,
            comptime value: V,
        ) void {
            var prev_hash: u32 = 0;
            var collisions: u8 = 0;
            while (collisions < options.max_collisions) : (collisions += 1) {
                const hash = options.reHash(hamt.context, key, prev_hash);
                const merr = hamt.putHashComptime(hash, key, value);
                merr catch |e| if (e == error.Collision) {
                    prev_hash = hash;
                    continue;
                } else {
                    @compileError(std.fmt.comptimePrint("error {s}. key " ++ kfmt ++ "", .{ @errorName(e), key }));
                };
                return;
            }
            @compileError(std.fmt.comptimePrint("too many collisions. key " ++ kfmt ++ "", .{key}));
        }

        inline fn putHashComptime(
            comptime hamt: *Self,
            comptime init_hash: u32,
            comptime key: K,
            comptime value: V,
        ) !void {
            var node_idx: u32 = 0;
            var h = init_hash;
            while (h > 0) {
                const chunk = h & 0b11111;
                h >>= 5;
                const id = hamt.nodes.items[node_idx];
                debug(
                    "  id {} {}/{}/{}/{} chunk/h {}/{}\n",
                    .{ id, node_idx, hamt.nodes.items.len, hamt.branches.items.len, hamt.leaves.items.len, chunk, h },
                );
                if (id < leaf_mask) { // branch
                    const bit = 1 << chunk;
                    var branch = hamt.branches.items[id];
                    const child_index = @popCount(branch.bits & (bit - 1));
                    debug("bit  {b:0>32}\n", .{bit});
                    debug("bits {b:0>32}\n", .{branch.bits});
                    var children = hamt.branch_nodes.subListFrom(branch.first);
                    if (branch.bits & bit != 0) {
                        // existing child

                        node_idx = children.nth(child_index).?;
                        if (h == 0 and hamt.nodes.items[node_idx] & leaf_mask != 0) {
                            return error.Collision;
                        }
                    } else {
                        // insert new child
                        const new_node: u32 = if (h == 0) blk: {
                            const len = hamt.leaves.items.len;
                            assert(len < leaf_mask);
                            break :blk len | leaf_mask;
                        } else blk: {
                            const len = hamt.branches.items.len;
                            assert(len < leaf_mask); // msb must be clear
                            var nbs = hamt.branches.items[0..].* ++ [1]Branch{Branch.empty};
                            hamt.branches.items = &nbs;
                            break :blk len;
                        };

                        node_idx = @intCast(hamt.nodes.items.len);
                        _ = children.appendAtComptime(child_index, node_idx);
                        debug("  index {} branch first {} children {}\n", .{ child_index, branch.first.int(), children.fmt() });
                        const cs = children.nodes.items[0..].*;
                        hamt.branch_nodes.nodes.items = @constCast(&cs);
                        hamt.branches.items[id] = .{ .bits = branch.bits | bit, .first = children.first };
                        var nodes = hamt.nodes.items[0..].* ++ .{new_node};
                        hamt.nodes.items = &nodes;
                    }
                } else return error.Leaf;
            }

            var leaves = hamt.leaves.items[0..].* ++ [1]KV{.{ key, value }};
            hamt.leaves.items = &leaves;
        }
    };
}

fn debug(comptime fmt: []const u8, args: anytype) void {
    if (true) return;
    if (@inComptime()) {
        // @compileLog(std.fmt.comptimePrint(fmt, args));
    } else {
        std.debug.print(fmt, args);
    }
}
