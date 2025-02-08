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

fn downloadBlock(allocator: std.mem.Allocator, connection: std.net.Stream, request: RequestPayload, block: []u8) !void {
    std.debug.print("block stuff begin={d} len={d}\n", .{ request.begin, block.len });
    const request_msg = PeerMessage.init(.request, .{ .request = request });
    try request_msg.send(connection);

    const piece = try PeerMessage.receive(allocator, connection);
    defer piece.deinit();

    std.debug.assert(request.length == piece.payload.piece.block.len);
    @memcpy(block, piece.payload.piece.block);
}

pub fn downloadPiece(self: Self, index: i32, rel_out: []const u8) !void {
    if (index >= self.torrent.info.piece_hashes.len) return;
    const peer = self.peers[0];
    const hs = try self.handshake(peer);

    const bitfield = try PeerMessage.receive(self.allocator, hs.connection);
    defer bitfield.deinit();

    const interested = PeerMessage.init(.interested, .none);
    try interested.send(hs.connection);

    const unchoke = try PeerMessage.receive(self.allocator, hs.connection);
    defer unchoke.deinit();

    var begin: i32 = 0;
    const k16 = 1024 * 16;
    const piece_length = if (index == self.torrent.info.piece_hashes.len - 1) self.torrent.info.length % self.torrent.info.piece_length else self.torrent.info.piece_length;
    std.debug.print("piece length={d}\n", .{piece_length});
    const piece_buf = try self.allocator.alloc(u8, piece_length);
    defer self.allocator.free(piece_buf);
    var piece_blocks = std.mem.window(u8, piece_buf, k16, k16);
    while (piece_blocks.next()) |block| {
        const request = RequestPayload{ .index = index, .begin = begin, .length = @intCast(block.len) };
        try downloadBlock(self.allocator, hs.connection, request, @constCast(block));
        begin += k16;
    }

    //  var info_hash = std.crypto.hash.Sha1.init(.{});
    //  info_hash.update(piece_buf);

    //  const digest = info_hash.finalResult();
    //  std.debug.assert(std.mem.eql(u8, &digest, self.torrent.info.piece_hashes[@intCast(index)]));

    const pfile = try std.fs.createFileAbsolute(rel_out, .{});
    defer pfile.close();
    try pfile.writeAll(piece_buf);
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

const PeerMessagePayload = union(enum) {
    none,
    have: u32,
    bitfield: []u8,
    request: RequestPayload,
    piece: PiecePayload,
    cancel: RequestPayload,
};

const RequestPayload = extern struct {
    index: i32,
    begin: i32,
    length: i32,
};

const PiecePayload = struct { index: i32, begin: i32, block: []u8 };

const PeerMessage = struct {
    allocator: std.mem.Allocator = undefined,

    message_length: u32,
    message_type: PeerMessageType,
    payload: PeerMessagePayload,

    fn init(message_type: PeerMessageType, payload: PeerMessagePayload) PeerMessage {
        const payload_length: u32 = switch (payload) {
            .have => 4,
            .bitfield => |bf| @intCast(bf.len),
            .request, .cancel => 12,
            .piece => |p| 8 + @as(u32, @intCast(p.block.len)),
            .none => 0,
        };
        return .{
            .message_length = payload_length + 1,
            .message_type = message_type,
            .payload = payload,
        };
    }

    fn deinit(self: PeerMessage) void {
        switch (self.payload) {
            .bitfield => |b| self.allocator.free(b),
            .piece => |p| self.allocator.free(p.block),
            else => {},
        }
    }

    fn send(self: PeerMessage, connection: std.net.Stream) !void {
        const writer = connection.writer();
        try writer.writeInt(u32, self.message_length, .big);
        try writer.writeByte(@intFromEnum(self.message_type));
        if (self.message_length <= 1) return;
        switch (self.payload) {
            .have => |h| try writer.writeInt(u32, h, .big),
            .bitfield => |bf| try writer.writeAll(bf),
            .request, .cancel => |r| {
                try writer.writeInt(i32, r.index, .big);
                try writer.writeInt(i32, r.begin, .big);
                try writer.writeInt(i32, r.length, .big);
            },
            .piece => |p| {
                try writer.writeInt(i32, p.index, .big);
                try writer.writeInt(i32, p.begin, .big);
                try writer.writeAll(p.block);
            },
            .none => {},
        }
    }

    fn receive(allocator: std.mem.Allocator, connection: std.net.Stream) !PeerMessage {
        const reader = connection.reader();
        const message_length = try reader.readInt(u32, .big);
        const message_type = try reader.readEnum(PeerMessageType, .big);
        var payload: PeerMessagePayload = undefined;
        switch (message_type) {
            .have => payload = .{ .have = try connection.reader().readInt(u32, .big) },
            .bitfield => {
                const buf = try allocator.alloc(u8, message_length - 1);
                const read = try connection.reader().readAll(buf);
                std.debug.assert(buf.len == read);
                payload = .{ .bitfield = buf };
            },
            .request, .cancel => payload = .{ .request = try connection.reader().readStruct(RequestPayload) },
            .piece => {
                const index = try connection.reader().readInt(i32, .big);
                const begin = try connection.reader().readInt(i32, .big);
                const block = try allocator.alloc(u8, message_length - 9);
                const read = try connection.reader().readAll(block);
                std.debug.assert(block.len == read);
                payload = .{ .piece = .{
                    .index = index,
                    .begin = begin,
                    .block = block,
                } };
            },
            else => payload = .none,
        }
        return PeerMessage{
            .allocator = allocator,
            .message_length = message_length,
            .message_type = message_type,
            .payload = payload,
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

    const body = try request.reader().readAllAlloc(allocator, comptime 100 * 1024 * 1024);
    defer allocator.free(body);

    var decoded = try bee.decode(allocator, body);
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
