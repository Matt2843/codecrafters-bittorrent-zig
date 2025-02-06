const std = @import("std");
const bee = @import("bee.zig");

const Command = enum {
    decode,
};

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_bittorrent.zig <command> <args>\n", .{});
        std.process.exit(1);
    }

    const command = std.meta.stringToEnum(Command, args[1]).?;

    switch (command) {
        .decode => {
            const decoded = try bee.decode(args[2]);
            try decoded.dump(stdout);
        },
    }
}
