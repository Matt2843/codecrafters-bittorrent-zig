const std = @import("std");
const bee = @import("bee.zig");
const pee = @import("peer.zig");
const tor = @import("tor.zig");
const BitTorrentClient = @import("client.zig");

const Command = enum { decode, info, peers, handshake, download_piece, download };

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    //var buffer: [10 * 1024 * 1024]u8 = undefined;
    //var fba = std.heap.FixedBufferAllocator.init(&buffer);
    //const allocator = fba.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_bittorrent.zig <command> <args>\n", .{});
        std.process.exit(1);
    }

    const command = std.meta.stringToEnum(Command, args[1]).?;
    switch (command) {
        .decode => {
            const decoded = try bee.decode(allocator, args[2]);
            defer decoded.deinit();
            try decoded.value.dump(stdout);
            try stdout.print("\n", .{});
        },
        .info => {
            const torrent = try tor.init(allocator, args[2]);
            defer torrent.deinit();
            try torrent.dump(stdout);
        },
        .peers => {
            const torrent = try tor.init(allocator, args[2]);
            defer torrent.deinit();
            const client = try BitTorrentClient.init(allocator, torrent);
            //defer client.deinit();
            for (client.peers) |p| {
                try stdout.print("{any}\n", .{p});
            }
        },
        .handshake => {
            const torrent = try tor.init(allocator, args[2]);
            defer torrent.deinit();
            const client = try BitTorrentClient.init(allocator, torrent);
            //defer client.deinit();

            var split = std.mem.splitScalar(u8, args[3], ':');
            const ip = split.next().?;
            const port = try std.fmt.parseInt(u16, split.next().?, 10);
            const peer = try std.net.Address.parseIp4(ip, port);

            const handshake = try pee.handshake(torrent.info_hash, client.peer_id, peer);
            defer handshake.connection.close();
            try stdout.print("Peer ID: {s}\n", .{std.fmt.fmtSliceHexLower(&handshake.peer_id)});
        },
        .download_piece => {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const index = try std.fmt.parseInt(usize, args[5], 10);

            const torrent = try tor.init(arena_allocator, args[4]);
            defer torrent.deinit();

            var client = try BitTorrentClient.init(arena_allocator, torrent);
            //defer client.deinit();

            try client.downloadPiece(index, args[3], null);
        },
        .download => {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_allocator = arena.allocator();

            const torrent = try tor.init(arena_allocator, args[4]);
            defer torrent.deinit();

            var client = try BitTorrentClient.init(arena_allocator, torrent);
            //defer client.deinit();

            try client.download(args[3]);
        },
    }
}
