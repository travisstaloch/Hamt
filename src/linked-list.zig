//! an index based linked list backed by an array

const std = @import("std");
const mem = std.mem;
const assert = std.debug.assert;
const testing = std.testing;
const talloc = testing.allocator;

pub const Id = enum(u32) {
    null = std.math.maxInt(u32),
    _,

    pub inline fn fromInt(i: u32) Id {
        return @enumFromInt(i);
    }
    pub inline fn int(id: Id) u32 {
        return @intFromEnum(id);
    }
};

/// a generic, intrusive linked list backed by an array of nodes.  it returns
/// and uses node Ids which are also indexes into the 'nodes' field.
///
/// node Ids are meant to be stable so nodes shouldn't usually be removed from the nodes array
///
/// methods which accept and allocator are runtime only.  comptime only methods
/// have a 'Comptime' suffix.
pub fn ArrayLinkedList(T: type) type {
    return struct {
        nodes: Nodes,
        first: Id,

        const Self = @This();
        const Nodes = std.ArrayListUnmanaged(Node);

        pub const empty: Self = .{
            .nodes = .{},
            .first = .null,
        };
        pub const Node = struct { value: T, next: Id };

        pub fn init(first: Id, nodes: Nodes) Self {
            return .{ .first = first, .nodes = nodes };
        }

        pub fn deinit(list: *Self, allocator: mem.Allocator) void {
            list.nodes.deinit(allocator);
        }

        pub fn subListFrom(list: *const Self, first: Id) Self {
            return .{ .first = first, .nodes = list.nodes };
        }

        /// insert an existing node at the start of the list
        pub fn insertFirst(list: *Self, node: Id) void {
            list.nodes.items[node.int()].next = list.first;
            list.first = node;
        }

        /// insert existing node_b after existing node_a
        pub fn insertAfter(list: *Self, node_a: Id, node_b: Id) void {
            list.nodes.items[node_b.int()].next = list.nodes.items[node_a.int()].next;
            list.nodes.items[node_a.int()].next = node_b;
        }

        /// create a new node from value but don't insert it
        pub fn append(list: *Self, allocator: mem.Allocator, value: T) !Id {
            const len = list.nodes.items.len;
            const id = Id.fromInt(@intCast(len));
            try list.nodes.append(allocator, .{ .next = .null, .value = value });
            return id;
        }

        /// append value and then insert it at the start of the list
        pub fn appendFirst(list: *Self, allocator: mem.Allocator, value: T) !Id {
            const new = try list.append(allocator, value);
            list.insertFirst(new);
            return new;
        }

        /// append value and then insert it after node
        pub fn appendAfter(list: *Self, allocator: mem.Allocator, node: Id, value: T) !Id {
            assert(node.int() < list.nodes.items.len);
            const new = try list.append(allocator, value);
            list.insertAfter(node, new);
            return new;
        }

        /// append value and then insert it at offset
        pub fn appendAt(list: *Self, allocator: mem.Allocator, offset: u32, value: T) !Id {
            if (offset == 0)
                return list.appendFirst(allocator, value)
            else {
                const id = list.nthId(offset - 1) orelse return error.OutOfBounds;
                return list.appendAfter(allocator, id, value);
            }
        }

        /// remove the node after 'node' and return its id.  the returned node's next field is set to null.
        pub fn removeNext(list: *Self, node: Id) ?Id {
            const next = list.nodes.items[node.int()].next;
            if (next == .null) return null;
            list.nodes.items[node.int()].next = list.nodes.items[next.int()].next;
            list.nodes.items[next.int()].next = .null;
            return next;
        }

        /// Remove a node from the list.  node's next field is set to null.
        pub fn remove(list: *Self, node: Id) void {
            assert(node != .null);

            if (list.first == node) {
                list.first = list.nodes.items[node.int()].next;
            } else {
                var current_elm = list.first;
                while (list.nodes.items[current_elm.int()].next != node) {
                    current_elm = list.nodes.items[current_elm.int()].next;
                }
                list.nodes.items[current_elm.int()].next = list.nodes.items[node.int()].next;
            }
            list.nodes.items[node.int()].next = .null;
        }

        /// remove and return the first node in the list.
        pub fn popFirst(list: *Self) ?Id {
            const first = list.first;
            if (first == .null) return null;
            list.first = list.nodes.items[list.first.int()].next;
            list.nodes.items[first.int()].next = .null;
            return first;
        }

        /// return the node with the given id or null
        pub fn at(list: Self, id: Id) ?Node {
            if (id.int() >= list.nodes.items.len) return null;
            return list.nodes.items[id.int()];
        }

        /// return the node with the given id or null
        pub fn atUnchecked(list: Self, id: Id) Node {
            return list.nodes.items.ptr[id.int()];
        }

        /// return a node pointer with the given id or null
        pub fn atPtr(list: Self, id: Id) ?*Node {
            if (id.int() >= list.nodes.items.len) return null;
            return &list.nodes.items[id.int()];
        }

        /// get the value at offset from start.  this method loops following node.next.
        pub fn nthAfter(list: Self, start: Id, offset: u32) ?T {
            const id = list.nthIdAfter(start, offset);
            return if (list.at(id)) |n| n.value else null;
        }

        /// get the value at offset from start.  this method loops following node.next.
        pub fn nthAfterUnchecked(list: Self, start: Id, offset: u32) T {
            const id = list.nthIdAfterUnchecked(start, offset);
            return list.atUnchecked(id).value;
        }

        /// get the value at offset from list.first.  this method loops following node.next.
        pub fn nth(list: Self, offset: u32) ?T {
            return list.nthAfter(list.first, offset);
        }

        /// get the value at offset from list.first.  this method loops following node.next.
        pub fn nthUnchecked(list: Self, offset: u32) T {
            return list.nthAfterUnchecked(list.first, offset);
        }

        /// get Id at offset from start.  this method loops following node.next.
        pub fn nthIdAfter(list: Self, start: Id, offset: u32) Id {
            if (offset == 0) return start;
            var j = offset;
            var id = start;
            while (j > 0) {
                j -= 1;
                id = (list.at(id) orelse return .null).next;
            }
            return id;
        }

        /// get Id at offset from start.  this method loops following node.next.
        pub fn nthIdAfterUnchecked(list: Self, start: Id, offset: u32) Id {
            if (offset == 0) return start;
            var j = offset;
            var id = start;
            while (j > 0) {
                j -= 1;
                id = (list.atUnchecked(id)).next;
            }
            return id;
        }

        /// get the id at offset from list.first.  this method loops following node.next.
        pub fn nthId(list: Self, offset: u32) ?Id {
            return list.nthIdAfter(list.first, offset);
        }

        pub inline fn appendComptime(comptime list: *Self, comptime value: T) Id {
            comptime {
                const id = Id.fromInt(list.nodes.items.len);
                var nodes = list.nodes.items[0..].* ++ [1]Node{.{ .next = .null, .value = value }};
                list.nodes.items = &nodes;
                return id;
            }
        }

        pub inline fn appendFirstComptime(comptime list: *Self, comptime value: T) Id {
            const id = list.appendComptime(value);
            list.insertFirst(id);
            return id;
        }

        pub inline fn appendAfterComptime(comptime list: *Self, comptime node: Id, comptime value: T) Id {
            const id = list.appendComptime(value);
            list.insertAfter(node, id);
            return id;
        }

        pub inline fn appendAtComptime(comptime list: *Self, comptime offset: u32, comptime value: T) Id {
            if (offset == 0)
                return list.appendFirstComptime(value)
            else {
                const cid = list.nthId(offset - 1).?;
                return list.appendAfterComptime(cid, value);
            }
        }

        pub fn fmt(list: Self) Fmt {
            return .{ .list = list };
        }

        pub const Fmt = struct {
            list: Self,
            pub fn format(f: Fmt, comptime _fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
                try writer.writeAll(".{ ");
                var i: u32 = 0;
                var mn = f.list.at(f.list.first);
                while (mn) |n| : (mn = f.list.at(n.next)) {
                    if (i != 0) try writer.writeAll(", ");
                    try std.fmt.formatType(n.value, _fmt, options, writer, 1);
                    i += 1;
                }
                try writer.writeAll(" }");
            }
        };
    };
}

test ArrayLinkedList {
    comptime try testLL(undefined);
    try testLL(talloc);
}

fn testLL(alloc: mem.Allocator) !void {
    const L = ArrayLinkedList([]const u8);
    const is_comptime = @inComptime();
    var l: L = .empty;
    defer if (!is_comptime) l.deinit(alloc);

    const id0 = if (is_comptime) l.appendFirstComptime("0") else try l.appendFirst(alloc, "0");
    if (!is_comptime)
        try testing.expectFmt(".{ 0 }", "{s}", .{l.fmt()});

    const id2 = if (is_comptime) l.appendAfterComptime(id0, "2") else try l.appendAfter(alloc, id0, "2");
    if (!is_comptime)
        try testing.expectFmt(".{ 0, 2 }", "{s}", .{l.fmt()});

    const id1 = if (is_comptime) l.appendAfterComptime(id2, "1") else try l.appendAfter(alloc, id2, "1");
    if (!is_comptime)
        try testing.expectFmt(".{ 0, 2, 1 }", "{s}", .{l.fmt()});

    l.remove(id2);
    if (!is_comptime)
        try testing.expectFmt(".{ 0, 1 }", "{s}", .{l.fmt()});
    l.insertAfter(id1, id2);
    if (!is_comptime)
        try testing.expectFmt(".{ 0, 1, 2 }", "{s}", .{l.fmt()});

    try testing.expectEqualStrings("0", l.nthAfter(id0, 0).?);
    try testing.expectEqualStrings("1", l.nthAfter(id0, 1).?);
    try testing.expectEqualStrings("2", l.nthAfter(id0, 2).?);

    try testing.expectEqualStrings("0", l.nth(0).?);
    try testing.expectEqualStrings("1", l.nth(1).?);
    try testing.expectEqualStrings("2", l.nth(2).?);

    try testing.expectEqualStrings("0", l.at(id0).?.value);
    try testing.expectEqualStrings("1", l.at(id1).?.value);
    try testing.expectEqualStrings("2", l.at(id2).?.value);

    _ = if (is_comptime) l.appendAfterComptime(id1, "1.5") else try l.appendAfter(alloc, id1, "1.5");
    if (!is_comptime)
        try testing.expectFmt(".{ 0, 1, 1.5, 2 }", "{s}", .{l.fmt()});

    try testing.expectEqual(id0, l.popFirst());
    if (!is_comptime)
        try testing.expectFmt(".{ 1, 1.5, 2 }", "{s}", .{l.fmt()});
}

test "addAfter" {
    const L = ArrayLinkedList(u32);
    var l = L.empty;
    try testing.expectEqual(.null, l.first);
    defer l.deinit(talloc);
    const id0 = try l.appendFirst(talloc, 0);
    try testing.expectEqual(.null, l.at(id0).?.next);
    const id1 = try l.appendAfter(talloc, id0, 1);
    try testing.expectEqual(.null, l.at(id1).?.next);
    const id2 = try l.appendAfter(talloc, id1, 3);
    try testing.expectEqual(.null, l.at(id2).?.next);
    _ = try l.appendAfter(talloc, id1, 2);
    const id4 = try l.appendAfter(talloc, id2, 4);

    try testing.expectEqual(0, l.nth(0).?);
    try testing.expectEqual(1, l.nth(1).?);
    try testing.expectEqual(2, l.nth(2).?);
    try testing.expectEqual(3, l.nth(3).?);
    try testing.expectEqual(4, l.nth(4).?);
    _ = l.atPtr(id4).?.next;
    try testing.expectEqual(.null, l.at(id4).?.next);
    try testing.expectEqual(null, l.nth(5));

    try testing.expectFmt(".{ 0, 1, 2, 3, 4 }", "{}", .{l.fmt()});
}

test "appendAt" {
    const L = ArrayLinkedList(u32);
    var l = L.empty;
    try testing.expectEqual(.null, l.first);
    defer l.deinit(talloc);
    const id0 = try l.appendAt(talloc, 0, 0);
    try testing.expectEqual(.null, l.at(id0).?.next);
    const id1 = try l.appendAt(talloc, 1, 1);
    try testing.expectEqual(.null, l.at(id1).?.next);
    const id2 = try l.appendAt(talloc, 2, 3);
    try testing.expectEqual(.null, l.at(id2).?.next);
    _ = try l.appendAt(talloc, 2, 2);
    const id4 = try l.appendAt(talloc, 4, 4);

    try testing.expectEqual(0, l.nth(0).?);
    try testing.expectEqual(1, l.nth(1).?);
    try testing.expectEqual(2, l.nth(2).?);
    try testing.expectEqual(3, l.nth(3).?);
    try testing.expectEqual(4, l.nth(4).?);
    _ = l.atPtr(id4).?.next;
    try testing.expectEqual(.null, l.at(id4).?.next);
    try testing.expectEqual(null, l.nth(5));

    try testing.expectFmt(".{ 0, 1, 2, 3, 4 }", "{}", .{l.fmt()});
}

test {
    const L = ArrayLinkedList(u32);
    var l: L = .empty;
    defer l.deinit(talloc);
    const iters = 10;
    const xs: [iters]u32 = std.simd.iota(u32, iters);
    for (xs, 0..) |v, i| {
        const idx: u32 = if (i & 1 == 0) 0 else @intCast(l.nodes.items.len);
        _ = try l.appendAt(talloc, idx, v);
    }
    try testing.expectFmt(".{ 8, 6, 4, 2, 0, 1, 3, 5, 7, 9 }", "{}", .{l.fmt()});
}

test "multiple lists backed by one nodes list" {
    const L = ArrayLinkedList(u32);
    var l: L = .empty;
    defer l.deinit(talloc);

    _ = try l.appendAt(talloc, 0, 0);
    _ = try l.appendAt(talloc, 1, 1);
    try testing.expectFmt(".{ 0, 1 }", "{}", .{l.fmt()});
    var l2 = l.subListFrom(.null);
    _ = try l2.appendAt(talloc, 0, 2);
    _ = try l2.appendAt(talloc, 1, 3);
    try testing.expectFmt(".{ 2, 3 }", "{}", .{l2.fmt()});
}
