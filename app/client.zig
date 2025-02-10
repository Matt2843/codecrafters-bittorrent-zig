const std = @import("std");
const bee = @import("bee.zig");
const pee = @import("peer.zig");
const Torrent = @import("tor.zig");

const Self = @This();

allocator: std.mem.Allocator,

torrent: Torrent,
peer_id: [20]u8,

connections: std.ArrayList(std.net.Stream),
peers: []std.net.Address,

pub fn init(allocator: std.mem.Allocator, torrent: Torrent) !Self {
    const peer_id: [20]u8 = "-mab-ztorrent-001224".*;
    const peers = try discoverPeers(allocator, torrent, peer_id);
    var connections = std.ArrayList(std.net.Stream).init(allocator);
    for (peers) |peer| {
        const shake = try pee.handshake(torrent.info_hash, peer_id, peer);
        try pee.initPeer(allocator, shake.connection);
        try connections.append(shake.connection);
    }
    return .{
        .allocator = allocator,
        .peer_id = peer_id,
        .torrent = torrent,
        .connections = connections,
        .peers = peers,
    };
}

pub fn deinit(self: Self) void {
    self.allocator.free(self.peers);
    self.connections.deinit();
}

pub fn download(self: *Self, out: []const u8) !void {
    const full_buf: []u8 = try self.allocator.alloc(u8, self.torrent.info.length);
    //var pool: std.Thread.Pool = undefined;
    //const pieces: u32 = @intCast(self.torrent.info.piece_hashes.len);
    //try std.Thread.Pool.init(&pool, .{ .allocator = self.allocator, .n_jobs = pieces });
    var index: usize = 0;
    var full_blocks = std.mem.window(u8, full_buf, self.torrent.info.piece_length, self.torrent.info.piece_length);
    while (full_blocks.next()) |block| : (index += 1) {
        //std.debug.print("downloading piece {d}/{d}\n", .{ index, pieces - 1 });
        try self.downloadPiece(index, "", @constCast(block));
    }
    //pool.deinit();
    const pfile = try std.fs.createFileAbsolute(out, .{});
    defer pfile.close();
    try pfile.writeAll(full_buf);
}

fn downloadPieceThread(self: *Self, index: usize, full_block: []u8) void {
    self.downloadPiece(index, "", full_block) catch |e| {
        std.debug.print("failed to download piece={d} err={}\n", .{ index, e });
        unreachable;
    };
}

pub fn downloadPiece(self: *Self, index: usize, out: []const u8, full_block: ?[]u8) !void {
    if (index >= self.torrent.info.piece_hashes.len) return;

    const k16: usize = comptime 16 * 1024;
    const piece_size: usize = if (index == self.torrent.info.piece_hashes.len - 1) self.torrent.info.length % self.torrent.info.piece_length else self.torrent.info.piece_length;
    const piece_buf: []u8 = try self.allocator.alloc(u8, piece_size);
    defer self.allocator.free(piece_buf);

    //const count_blocks = (piece_size + k16 - 1) / k16;
    var pool: std.Thread.Pool = undefined;
    try std.Thread.Pool.init(&pool, .{ .allocator = self.allocator, .n_jobs = 16 });

    var mutex = std.Thread.Mutex{};

    var begin: usize = 0;
    var piece_blocks = std.mem.window(u8, piece_buf, k16, k16);
    while (piece_blocks.next()) |block| : (begin += k16) {
        while (self.connections.items.len == 0) {
            std.time.sleep(25 * std.time.ns_per_ms);
        }
        mutex.lock();
        const connection = self.connections.pop();
        mutex.unlock();
        try pool.spawn(downloadBlock, .{ self.allocator, connection, @as(i32, @intCast(index)), @as(i32, @intCast(begin)), @constCast(block), &mutex, &self.connections });
    }

    pool.deinit();

    var info_hash = std.crypto.hash.Sha1.init(.{});
    info_hash.update(piece_buf);
    const digest = info_hash.finalResult();

    std.debug.assert(std.mem.eql(u8, &digest, self.torrent.info.piece_hashes[@intCast(index)]));

    if (full_block) |fb| {
        @memcpy(fb, piece_buf);
    } else {
        const pfile = try std.fs.createFileAbsolute(out, .{});
        defer pfile.close();
        try pfile.writeAll(piece_buf);
    }
}

fn downloadBlock(allocator: std.mem.Allocator, connection: std.net.Stream, index: i32, begin: i32, block_buf: []u8, mutex: *std.Thread.Mutex, connections: *std.ArrayList(std.net.Stream)) void {
    std.debug.print("download block index={d} begin={d} len={d}\n", .{ index, begin, block_buf.len });
    const request = pee.PeerMessage.init(.request, .{ .request = .{ .index = index, .begin = begin, .length = @intCast(block_buf.len) } });
    request.send(connection) catch |e| {
        std.debug.print("failed sending request_msg: {}\n", .{e});
        unreachable;
    };

    const piece = pee.PeerMessage.receive(allocator, .piece, connection) catch |e| {
        std.debug.print("failed receiving piece: {}\n", .{e});
        unreachable;
    };
    defer piece.deinit();

    std.debug.assert(piece.message_type == .piece);
    std.debug.assert(piece.payload.piece.block.len == block_buf.len);

    @memcpy(block_buf, piece.payload.piece.block);

    mutex.lock();
    connections.append(connection) catch unreachable;
    mutex.unlock();
}

fn discoverPeers(allocator: std.mem.Allocator, torrent: Torrent, peer_id: [20]u8) ![]std.net.Address {
    const query_params = try buildPeersQueryParams(allocator, torrent, peer_id);
    defer allocator.free(query_params);
    std.debug.print("discovering peers @ {s}\n", .{std.fmt.fmtSliceHexLower(&torrent.info_hash)});

    var uri = try std.Uri.parse(torrent.announce);
    uri.query = .{ .raw = query_params };

    std.debug.print("{any}\n", .{uri});

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var server_header_buf: [4096]u8 = undefined;
    var request = try client.open(.GET, uri, .{ .server_header_buffer = &server_header_buf });
    defer request.deinit();

    try request.send();
    try request.finish();
    try request.wait();

    const body = try request.reader().readAllAlloc(allocator, comptime 10 * 1024 * 1024);
    defer allocator.free(body);

    var decoded = try bee.decode(allocator, body);
    defer decoded.deinit();

    var peers_arr = std.ArrayList(std.net.Address).init(allocator);
    const peers_raw = decoded.value.dict.get("peers") orelse {
        var base64file: [10 * 1024 * 1024]u8 = undefined;
        const enc = std.base64.url_safe_no_pad.Encoder.encode(&base64file, torrent.bytes);

        const stdout = std.io.getStdOut().writer();
        try decoded.value.dump(stdout);
        try stdout.print("\n", .{});
        try stdout.print("{any}\n", .{torrent.info});

        try stdout.print("\nFILE:\n", .{});
        try stdout.print("{s}\n", .{enc});
        unreachable;
    };
    var peers_window_it = std.mem.window(u8, peers_raw.string, 6, 6);
    while (peers_window_it.next()) |peer_raw| {
        var ip4: [4]u8 = undefined;
        @memcpy(ip4[0..], peer_raw[0..4]);
        const port = std.mem.readInt(u16, peer_raw[4..6], .big);
        try peers_arr.append(std.net.Address.initIp4(ip4, port));
    }
    return peers_arr.toOwnedSlice();
}

fn buildPeersQueryParams(allocator: std.mem.Allocator, torrent: Torrent, peer_id: [20]u8) ![]const u8 {
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
