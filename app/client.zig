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

pub fn downloadPiece(self: Self, index: i32, rel_out: []const u8) !void {
    if (index >= self.torrent.info.piece_hashes.len) return;

    const peer = self.peers[0];
    const hs = try self.handshake(peer);
    //  Wait for a bitfield message from the peer indicating which pieces it has
    //      The message id for this message type is 5.
    //      You can read and ignore the payload for now, the tracker we use for this challenge ensures that all peers have all pieces available.
    const bitfield = try PeerMessage.receive(self.allocator, hs.connection);
    defer bitfield.deinit();
    //  Send an interested message
    //      The message id for interested is 2.
    //      The payload for this message is empty.
    const interested = PeerMessage.init(.interested, .none);
    try interested.send(hs.connection);
    //  Wait until you receive an unchoke message back
    //      The message id for unchoke is 1.
    //      The payload for this message is empty.
    const unchoke = try PeerMessage.receive(self.allocator, hs.connection);
    defer unchoke.deinit();
    //  Break the piece into blocks of 16 kiB (16 * 1024 bytes) and send a request message for each block

    //      The message id for request is 6.
    //      The payload for this message consists of:
    //          index: the zero-based piece index
    //          begin: the zero-based byte offset within the piece
    //              This'll be 0 for the first block, 2^14 for the second block, 2*2^14 for the third block etc.
    //          length: the length of the block in bytes
    //              This'll be 2^14 (16 * 1024) for all blocks except the last one.
    //              The last block will contain 2^14 bytes or less, you'll need calculate this value using the piece length.

    //  Wait for a piece message for each block you've requested

    //      The message id for piece is 7.
    //      The payload for this message consists of:
    //          index: the zero-based piece index
    //          begin: the zero-based byte offset within the piece
    //          block: the data for the piece, usually 2^14 bytes long
    const k16: i32 = 16 * 1024;
    var begin: i32 = 0;

    const index_usize: usize = @intCast(index);
    const max_piece_length: usize = @intCast(self.torrent.info.piece_length);
    const min_piece_length: usize = @intCast(self.torrent.info.length % self.torrent.info.piece_length);
    const piece_length: usize = if (index_usize == self.torrent.info.piece_hashes.len - 1) min_piece_length else max_piece_length;

    var left: i32 = @intCast(piece_length);
    var piece_buf = try self.allocator.alloc(u8, piece_length);
    defer self.allocator.free(piece_buf);
    while (left > 0) {
        const length = if (left > k16) k16 else left;
        const request = PeerMessage.init(.request, .{ .request = .{ .index = index, .begin = begin, .length = length } });
        try request.send(hs.connection);

        const piece = try PeerMessage.receive(self.allocator, hs.connection);
        defer piece.deinit();

        std.debug.assert(length == piece.payload.piece.block.len);

        const bs: usize = @intCast(piece.payload.piece.begin);
        const ls: usize = @intCast(piece.payload.piece.block.len);

        @memcpy(piece_buf[bs .. bs + ls], piece.payload.piece.block);

        begin += k16;
        left -= length;
    }
    var info_hash = std.crypto.hash.Sha1.init(.{});
    info_hash.update(piece_buf);
    const digest = info_hash.finalResult();
    std.debug.assert(std.mem.eql(u8, &digest, self.torrent.info.piece_hashes[@intCast(index)]));

    const slash = if (std.mem.endsWith(u8, rel_out, "/")) "" else "/";
    const path = try std.mem.concat(self.allocator, u8, &[_][]const u8{ rel_out, slash, self.torrent.info.name });
    std.debug.print("saving to path: {s}\n", .{path});
    defer self.allocator.free(path);

    const pfile = try std.fs.cwd().createFile(path, .{});
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

    const stdout = std.io.getStdOut().writer();
    try decoded.value.dump(stdout);
    try stdout.print("\n", .{});

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
