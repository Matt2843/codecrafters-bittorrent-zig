const std = @import("std");
const bee = @import("bee.zig");
const Self = @This();

allocator: std.mem.Allocator,
bytes: []u8,

announce: []const u8,
info: Info,
info_hash: [std.crypto.hash.Sha1.digest_length]u8,

pub fn init(allocator: std.mem.Allocator, rel_path: []const u8) !Self {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, rel_path, comptime 10 * 1024 * 1024);
    const decoded = try bee.decode(allocator, bytes);
    defer decoded.deinit();
    const dict = decoded.value.dict;

    const announce = dict.get("announce").?.string;
    const info = dict.get("info").?;

    var str = std.ArrayList(u8).init(allocator);
    defer str.deinit();
    try info.encode(str.writer());

    var info_hash = std.crypto.hash.Sha1.init(.{});
    info_hash.update(str.items);

    return .{ .allocator = allocator, .bytes = bytes, .announce = announce, .info = .{ .length = @intCast(info.dict.get("length").?.int), .name = info.dict.get("name").?.string, .piece_length = @intCast(info.dict.get("piece length").?.int), .pieces = info.dict.get("pieces").?.string }, .info_hash = info_hash.finalResult() };
}

pub fn deinit(self: Self) void {
    self.allocator.free(self.bytes);
}

const Info = struct {
    length: usize,
    name: []const u8,
    piece_length: usize,
    pieces: []const u8,

    pub fn pieceHashes(self: Info, writer: anytype) !void {
        var pieces_window = std.mem.window(u8, self.pieces, 20, 20);
        while (pieces_window.next()) |piece| {
            try writer.print("{s}\n", .{std.fmt.fmtSliceHexLower(piece)});
        }
    }
};

pub fn dump(self: Self, writer: anytype) !void {
    try writer.print("Tracker URL: {s}\n", .{self.announce});
    try writer.print("Length: {d}\n", .{self.info.length});
    try writer.print("Info Hash: {s}\n", .{std.fmt.fmtSliceHexLower(&self.info_hash)});
    try writer.print("Piece Length: {d}\n", .{self.info.piece_length});
    try writer.print("Piece Hashes:\n", .{});
    try self.info.pieceHashes(writer);
}

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
