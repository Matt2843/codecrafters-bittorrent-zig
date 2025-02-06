const std = @import("std");
const bee = @import("bee.zig");
const Self = @This();

allocator: std.mem.Allocator,
bytes: []u8,

announce: []const u8,
info: Info,

pub fn init(allocator: std.mem.Allocator, rel_path: []const u8) !Self {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, rel_path, comptime 10 * 1024 * 1024);
    const decoded = try bee.decode(allocator, bytes);
    defer decoded.deinit();
    const dict = decoded.value.dict;

    const announce = dict.get("announce").?.string;
    const info_dict = dict.get("info").?.dict;
    return .{ .allocator = allocator, .bytes = bytes, .announce = announce, .info = .{
        .length = @intCast(info_dict.get("length").?.int),
        .name = info_dict.get("name").?.string,
        .piece_length = @intCast(info_dict.get("piece length").?.int),
        .pieces = info_dict.get("pieces").?.string,
    } };
}

pub fn deinit(self: Self) void {
    self.allocator.free(self.bytes);
}

const Info = struct { length: usize, name: []const u8, piece_length: usize, pieces: []const u8 };

// ############## TESTS ################
const testing = std.testing;
const tally = testing.allocator;
test "init sample.torrent" {
    const torrent = try init(tally, "sample.torrent");
    defer torrent.deinit();
    try testing.expectEqualStrings("http://bittorrent-test-tracker.codecrafters.io/announce", torrent.announce);
    try testing.expect(92063 == torrent.info.length);
    try testing.expectEqualStrings("sample.txt", torrent.info.name);
    try testing.expect(32768 == torrent.info.piece_length);
}
