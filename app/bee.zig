const std = @import("std");

const Self = @This();

const Value = union(enum) {
    string: []const u8,
    int: i64,
    list: std.ArrayList(Value),
    dict: std.StringHashMap(Value),

    pub fn dump(value: Value, writer: anytype) !void {
        switch (value) {
            .string => |s| try writer.print("\"{s}\"\n", .{s}),
            .int => |i| try writer.print("{d}\n", .{i}),
            else => unreachable,
        }
    }
};

pub fn decode(bencode: []const u8) !Value {
    return switch (bencode[0]) {
        '0'...'9' => .{ .string = (try decodeString(bencode)).value },
        'i' => .{ .int = (try decodeInt(bencode)).value },
        else => unreachable,
    };
}

fn decodeString(bencode: []const u8) !struct { value: []const u8, read: usize } {
    const col = std.mem.indexOf(u8, bencode, ":").?;
    const len = try std.fmt.parseInt(usize, bencode[0..col], 10);
    return .{ .value = bencode[col + 1 .. col + 1 + len], .read = col + len };
}

fn decodeInt(bencode: []const u8) !struct { value: i64, read: usize } {
    const end = std.mem.indexOf(u8, bencode, "e").?;
    const int = try std.fmt.parseInt(i64, bencode[1..end], 10);
    return .{ .value = int, .read = end };
}

const testing = std.testing;
test "decode string" {
    const actual = try decode("5:hello");
    try testing.expectEqualStrings("hello", actual.string);
}

test "decode string empty" {
    const actual = try decode("0:");
    try testing.expectEqualStrings("", actual.string);
}

test "decode integer" {
    const actual = try decode("i32e");
    try testing.expect(32 == actual.int);
}

test "decode integer negative" {
    const actual = try decode("i-98e");
    try testing.expect(-98 == actual.int);
}
