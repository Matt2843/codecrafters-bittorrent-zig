const std = @import("std");

const Value = union(enum) {
    const Self = @This();

    string: []const u8,
    int: i64,
    list: std.ArrayList(Value),
    dict: std.StringHashMap(Value),
    end,

    pub fn deinit(self: Self) void {
        switch (self) {
            .list => |l| {
                for (l.items) |i| i.deinit();
                l.deinit();
            },
            else => {},
        }
    }

    pub fn dump(self: Self, writer: anytype) !void {
        switch (self) {
            .string => |s| try writer.print("\"{s}\"", .{s}),
            .int => |i| try writer.print("{d}", .{i}),
            .list => |l| {
                try writer.print("[", .{});
                for (l.items, 0..) |item, i| {
                    try dump(item, writer);
                    if (i < l.items.len - 1) try writer.print(",", .{});
                }
                try writer.print("]", .{});
            },
            else => unreachable,
        }
    }
};

pub const Bee = struct {
    const Self = @This();

    allocator: std.mem.Allocator = undefined,

    value: Value,
    read: usize,

    pub fn deinit(self: Self) void {
        self.value.deinit();
    }
};

pub fn decode(allocator: std.mem.Allocator, bencode: []const u8) anyerror!Bee {
    return switch (bencode[0]) {
        '0'...'9' => try decodeString(bencode),
        'i' => try decodeInt(bencode),
        'l' => try decodeList(allocator, bencode),
        'e' => .{ .value = .end, .read = 1 },
        else => unreachable,
    };
}

inline fn decodeString(bencode: []const u8) !Bee {
    const col = std.mem.indexOf(u8, bencode, ":").?;
    const len = try std.fmt.parseInt(usize, bencode[0..col], 10);
    return .{ .value = .{ .string = bencode[col + 1 .. col + 1 + len] }, .read = col + 1 + len };
}

inline fn decodeInt(bencode: []const u8) !Bee {
    const end = std.mem.indexOf(u8, bencode, "e").?;
    const int = try std.fmt.parseInt(i64, bencode[1..end], 10);
    return .{ .value = .{ .int = int }, .read = end + 1 };
}

inline fn decodeList(allocator: std.mem.Allocator, bencode: []const u8) !Bee {
    var list = std.ArrayList(Value).init(allocator);
    var read: usize = 1;
    var decoded = try decode(allocator, bencode[1..]);
    while (decoded.value != .end) : (decoded = try decode(allocator, bencode[read..])) {
        try list.append(decoded.value);
        read += decoded.read;
    }
    return .{ .allocator = allocator, .value = .{ .list = list }, .read = read + 1 };
}

// ############## TESTS ################
const testing = std.testing;
const tally = testing.allocator;
test "decode string" {
    const actual = try decode(tally, "5:hello");
    defer actual.deinit();
    try testing.expectEqualStrings("hello", actual.value.string);
}

test "decode string empty" {
    const actual = try decode(tally, "0:");
    defer actual.deinit();
    try testing.expectEqualStrings("", actual.value.string);
}

test "decode integer" {
    const actual = try decode(tally, "i32e");
    defer actual.deinit();
    try testing.expect(32 == actual.value.int);
}

test "decode integer negative" {
    const actual = try decode(tally, "i-98e");
    defer actual.deinit();
    try testing.expect(-98 == actual.value.int);
}

test "decode list" {
    var expected = std.ArrayList(Value).init(tally);
    defer expected.deinit();
    try expected.append(.{ .int = 32 });
    try expected.append(.{ .string = "hello" });
    try expected.append(.{ .int = -2 });
    try expected.append(.{ .string = "zig" });

    const actual = try decode(tally, "li32e5:helloi-2e3:zige");
    defer actual.deinit();

    try testing.expectEqualDeep(expected, actual.value.list);
}

test "decode list nested" {
    var expected = std.ArrayList(Value).init(tally);
    var expected_nested = std.ArrayList(Value).init(tally);
    var expected_nested_nested = std.ArrayList(Value).init(tally);
    defer expected_nested_nested.deinit();
    defer expected_nested.deinit();
    defer expected.deinit();

    try expected.append(.{ .int = -32 });
    try expected_nested.append(.{ .int = 1 });
    try expected_nested.append(.{ .int = 2 });
    try expected_nested_nested.append(.{ .string = "zig" });
    try expected_nested.append(.{ .list = expected_nested_nested });
    try expected_nested.append(.{ .string = "hell" });
    try expected.append(.{ .list = expected_nested });
    try expected.append(.{ .int = 54 });

    const actual = try decode(tally, "li-32eli1ei2el3:zige4:hellei54ee");
    defer actual.deinit();

    try testing.expectEqualDeep(expected, actual.value.list);
}
