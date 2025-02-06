const std = @import("std");
const bee = @import("bee.zig");
const Torrent = @import("tor.zig");

const Self = @This();

allocator: std.mem.Allocator,

torrent: Torrent, // TODO: maybe remove?
peer_id: []const u8,
peers: []std.net.Address,

pub fn init(allocator: std.mem.Allocator, torrent: Torrent) !Self {
    const peer_id = "-mab-ztorrent-001224";
    const peers = try discoverPeers(allocator, peer_id, torrent);
    return .{
        .allocator = allocator,
        .peer_id = peer_id,
        .torrent = torrent,
        .peers = peers,
    };
}

pub fn deinit(self: Self) void {
    self.allocator.free(self.peers);
}

fn discoverPeers(allocator: std.mem.Allocator, peer_id: []const u8, torrent: Torrent) ![]std.net.Address {
    const query_params = try buildPeersQueryParams(allocator, peer_id, torrent);
    defer allocator.free(query_params);
    var uri = try std.Uri.parse(torrent.announce);
    uri.query = .{ .raw = query_params };

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var server_header_buf: [4096]u8 = undefined;
    var request = try client.open(.GET, uri, .{ .server_header_buffer = &server_header_buf });
    defer request.deinit();

    try request.send();
    try request.finish();
    try request.wait();

    var body: [10 * 1024 * 1024]u8 = undefined;
    const read = try request.readAll(&body);

    var decoded = try bee.decode(allocator, body[0..read]);
    defer decoded.deinit();

    var peers_arr = std.ArrayList(std.net.Address).init(allocator);
    const peers_raw = decoded.value.dict.get("peers").?.string;
    var peers_window_it = std.mem.window(u8, peers_raw, 6, 6);
    while (peers_window_it.next()) |peer_raw| {
        //Each peer is represented using 6 bytes. The first 4 bytes are the peer's IP address and the last 2 bytes are the peer's port number.
        var ip4: [4]u8 = undefined;
        @memcpy(ip4[0..], peer_raw[0..4]);
        const port = std.mem.readInt(u16, peer_raw[4..6], .big);
        try peers_arr.append(std.net.Address.initIp4(ip4, port));
    }
    return peers_arr.toOwnedSlice();
}

fn buildPeersQueryParams(allocator: std.mem.Allocator, peer_id: []const u8, torrent: Torrent) ![]const u8 {
    var query_params = std.ArrayList(u8).init(allocator);
    const writer = query_params.writer();
    try writer.print("info_hash={s}", .{torrent.info_hash});
    try writer.print("&peer_id={s}", .{peer_id});
    try writer.print("&port={d}", .{6881});
    try writer.print("&uploaded={d}", .{0});
    try writer.print("&downloaded={d}", .{0});
    try writer.print("&left={d}", .{torrent.info.length});
    try writer.print("&compact={d}", .{1});
    return query_params.toOwnedSlice();
}
