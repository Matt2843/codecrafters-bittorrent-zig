const std = @import("std");
const bee = @import("bee.zig");
const Torrent = @import("tor.zig");

const Self = @This();

allocator: std.mem.Allocator,

torrent: Torrent, // TODO: remove later..
peer_id: [20]u8,
peers: []std.net.Address,

pub fn init(allocator: std.mem.Allocator, torrent: Torrent) !Self {
    const peer_id: [20]u8 = "-mab-ztorrent-001224".*;
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

pub fn downloadPiece(self: Self, index: u32) !void {
    _ = index;
    const peer = self.peers[0];
    const hs = try self.handshake(peer);

    const response = PeerMessage.receive(self.allocator, hs.connection);
    std.debug.print("{any}\n", .{response});
}

const PeerMessageType = enum(u8) {
    choke = 0,
    unchoke = 1,
    interested = 2,
    not_interested = 3,
    have = 4,
    bitfield = 5,
    request = 6,
    piece = 7,
    cancel = 8,
};

const PeerMessagePayload = union(PeerMessageType) {
    choke: void,
    unchoke: void,
    interested: void,
    not_interested: void,
    have: u32,
    bitfield: []u8,
    request: RequestPayload,
    piece: PiecePayload,
    cancel: RequestPayload,
};

const RequestPayload = extern struct {
    index: i32,
    begin: i32,
    lenght: i32,
};

const PiecePayload = struct { index: i32, begin: i32, block: []u8 };

const PeerMessage = struct {
    message_length: u32,
    message_type: PeerMessageType,
    payload: PeerMessagePayload,

    fn receive(_: std.mem.Allocator, connection: std.net.Stream) !PeerMessage {
        const reader = connection.reader();
        const message_length = try reader.readInt(u32, .big);
        const message_type = try reader.readEnum(PeerMessageType, .big);
        return PeerMessage{
            .message_length = message_length,
            .message_type = message_type,
            .payload = undefined,
        };
    }
};

pub fn handshake(self: Self, peer: std.net.Address) !struct { connection: std.net.Stream, peer_id: [20]u8 } {
    const connection = try std.net.tcpConnectToAddress(peer);
    const shake = Handshake{ .info_hash = self.torrent.info_hash, .peer_id = self.peer_id };
    try connection.writer().writeStruct(shake);
    const response = try connection.reader().readStruct(Handshake);
    return .{ .connection = connection, .peer_id = response.peer_id };
}

const Handshake = extern struct {
    length: u8 = 19,
    protocol: [19]u8 = "BitTorrent protocol".*,
    zeroes: [8]u8 = std.mem.zeroes([8]u8),
    info_hash: [20]u8 = undefined,
    peer_id: [20]u8 = undefined,
};

fn discoverPeers(allocator: std.mem.Allocator, peer_id: [20]u8, torrent: Torrent) ![]std.net.Address {
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

    var body: [10 * 1024 * 1024]u8 = undefined; // 10 MiB
    const read = try request.readAll(&body);

    var decoded = try bee.decode(allocator, body[0..read]);
    defer decoded.deinit();

    var peers_arr = std.ArrayList(std.net.Address).init(allocator);
    const peers_raw = decoded.value.dict.get("peers").?.string;
    var peers_window_it = std.mem.window(u8, peers_raw, 6, 6);
    while (peers_window_it.next()) |peer_raw| {
        var ip4: [4]u8 = undefined;
        @memcpy(ip4[0..], peer_raw[0..4]);
        const port = std.mem.readInt(u16, peer_raw[4..6], .big);
        try peers_arr.append(std.net.Address.initIp4(ip4, port));
    }
    return peers_arr.toOwnedSlice();
}

fn buildPeersQueryParams(allocator: std.mem.Allocator, peer_id: [20]u8, torrent: Torrent) ![]const u8 {
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
