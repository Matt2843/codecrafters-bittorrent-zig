const std = @import("std");
const bee = @import("bee.zig");
const Torrent = @import("tor.zig");

pub const PeerMessageType = enum(u8) {
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

pub const PeerMessagePayload = union(enum) {
    none,
    have: u32,
    bitfield: []u8,
    request: RequestPayload,
    piece: PiecePayload,
    cancel: RequestPayload,
};

pub const RequestPayload = extern struct {
    index: i32,
    begin: i32,
    length: i32,
};

pub const PiecePayload = struct { index: i32, begin: i32, block: []u8 };

pub const PeerMessage = struct {
    const Self = @This();
    allocator: std.mem.Allocator = undefined,

    message_length: u32,
    message_type: PeerMessageType,
    payload: PeerMessagePayload,

    pub fn init(message_type: PeerMessageType, payload: PeerMessagePayload) PeerMessage {
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

    pub fn deinit(self: Self) void {
        switch (self.payload) {
            .bitfield => |b| self.allocator.free(b),
            .piece => |p| self.allocator.free(p.block),
            else => {},
        }
    }

    pub fn send(self: Self, connection: std.net.Stream) !void {
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

    pub fn receive(allocator: std.mem.Allocator, msg_type: PeerMessageType, connection: std.net.Stream) !Self {
        const reader = connection.reader();
        const message_length = try reader.readInt(u32, .big);
        const message_type = try reader.readEnum(PeerMessageType, .big);
        std.debug.assert(msg_type == message_type);
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

const Handshake = extern struct {
    length: u8 = 19,
    protocol: [19]u8 = "BitTorrent protocol".*,
    zeroes: [8]u8 = std.mem.zeroes([8]u8),
    info_hash: [20]u8 = undefined,
    peer_id: [20]u8 = undefined,
};

pub fn initPeer(allocator: std.mem.Allocator, connection: std.net.Stream) !void {
    const bitfield = try PeerMessage.receive(allocator, .bitfield, connection);
    defer bitfield.deinit();

    const interested = PeerMessage.init(.interested, .none);
    try interested.send(connection);

    const unchoke = try PeerMessage.receive(allocator, .unchoke, connection);
    defer unchoke.deinit();
}

pub fn handshake(info_hash: [std.crypto.hash.Sha1.digest_length]u8, client_id: [20]u8, peer: std.net.Address) !struct { connection: std.net.Stream, peer_id: [20]u8 } {
    const connection = try std.net.tcpConnectToAddress(peer);
    const shake = Handshake{ .info_hash = info_hash, .peer_id = client_id };
    try connection.writer().writeStruct(shake);
    const response = try connection.reader().readStruct(Handshake);
    return .{ .connection = connection, .peer_id = response.peer_id };
}
