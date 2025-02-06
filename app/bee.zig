const std = @import("std");

const Value = union(enum) {
    const Self = @This();

    string: []const u8,
    int: i64,
    list: std.ArrayList(Value),
    dict: std.StringArrayHashMap(Value),
    end,

    pub fn encode(self: Self, writer: anytype) !void {
        return switch (self) {
            .string => |s| try writer.print("{d}:{s}", .{ s.len, s }),
            .int => |i| try writer.print("i{d}e", .{i}),
            .list => |l| {
                try writer.print("l", .{});
                for (l.items) |i| try encode(i, writer);
                try writer.print("e", .{});
            },
            .dict => |d| {
                try writer.print("d", .{});
                var it = d.iterator();
                while (it.next()) |kv| {
                    try encode(.{ .string = kv.key_ptr.* }, writer);
                    try encode(kv.value_ptr.*, writer);
                }
                try writer.print("e", .{});
            },
            .end => unreachable,
        };
    }

    pub fn deinit(self: Self) void {
        switch (self) {
            .list => |l| {
                for (l.items) |i| i.deinit();
                l.deinit();
            },
            .dict => |d| {
                var it = d.iterator();
                while (it.next()) |kv| kv.value_ptr.*.deinit();
                var d_mut = d;
                d_mut.deinit();
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
            .dict => |d| {
                try writer.print("{{", .{});
                var it = d.iterator();
                var first = true;
                while (it.next()) |kv| {
                    if (!first) try writer.print(",", .{});
                    first = false;
                    const k = Value{ .string = kv.key_ptr.* };
                    try k.dump(writer);
                    try writer.print(":", .{});
                    try kv.value_ptr.*.dump(writer);
                }
                try writer.print("}}", .{});
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
        'd' => try decodeDict(allocator, bencode),
        'e' => .{ .value = .end, .read = 1 },
        else => {
            std.debug.print("\ninvalid bencode start: {s}\n", .{bencode});
            unreachable;
        },
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

inline fn decodeDict(allocator: std.mem.Allocator, bencode: []const u8) !Bee {
    var dict = std.StringArrayHashMap(Value).init(allocator);
    var read: usize = 1;
    var key = try decode(allocator, bencode[1..]);
    while (key.value != .end) : (key = try decode(allocator, bencode[read..])) {
        read += key.read;
        const value = try decode(allocator, bencode[read..]);
        read += value.read;
        try dict.put(key.value.string, value.value);
    }
    return .{ .allocator = allocator, .value = .{ .dict = dict }, .read = read + 1 };
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

test "decode int" {
    const actual = try decode(tally, "i32e");
    defer actual.deinit();
    try testing.expect(32 == actual.value.int);
}

test "decode int negative" {
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

test "encode string" {
    const actual = Value{ .string = "hello" };
    defer actual.deinit();

    var buf: [7]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try actual.encode(writer);

    try testing.expectEqualStrings("5:hello", &buf);
}

test "encode int" {
    const actual = Value{ .int = 52 };
    defer actual.deinit();

    var buf: [4]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try actual.encode(writer);

    try testing.expectEqualStrings("i52e", &buf);
}

test "encode list" {
    var list = std.ArrayList(Value).init(tally);
    defer list.deinit();
    try list.append(.{ .int = 52 });
    try list.append(.{ .string = "hello" });
    try list.append(.{ .string = "zig" });
    const actual = Value{ .list = list };

    var buf: [18]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try actual.encode(writer);

    try testing.expectEqualStrings("li52e5:hello3:zige", &buf);
}

test "encode dict" {
    var dict = std.StringArrayHashMap(Value).init(tally);
    defer dict.deinit();
    try dict.put("zig", .{ .int = 52 });
    try dict.put("world", .{ .string = "hello" });
    const actual = Value{ .dict = dict };

    var buf: [25]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try actual.encode(writer);

    try testing.expectEqualStrings("d3:zigi52e5:world5:helloe", &buf);
}

test "dump string" {
    const actual = try decode(tally, "5:hello");
    defer actual.deinit();

    var buf: [7]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try actual.value.dump(writer);

    try testing.expectEqualStrings("\"hello\"", &buf);
}

test "dump int" {
    const actual = try decode(tally, "i52e");
    defer actual.deinit();

    var buf: [2]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try actual.value.dump(writer);

    try testing.expectEqualStrings("52", &buf);
}

test "dump list" {
    const actual = try decode(tally, "l5:helloi52ee");
    defer actual.deinit();

    var buf: [12]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try actual.value.dump(writer);

    try testing.expectEqualStrings("[\"hello\",52]", &buf);
}

test "dump dictionary" {
    const actual = try decode(tally, "d3:foo3:bar5:helloi52ee");
    defer actual.deinit();

    var buf: [24]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();
    try actual.value.dump(writer);

    try testing.expectEqualStrings("{\"foo\":\"bar\",\"hello\":52}", &buf);
}
