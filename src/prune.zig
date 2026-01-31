const std = @import("std");
const config = @import("config.zig");

pub fn prune(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.Environ, io: std.Io) !void {
    std.log.info("Pruning configuration...", .{});
    var it = conf.bins.iterator();
    var to_remove: std.ArrayList([]const u8) = .empty;
    defer to_remove.deinit(allocator);

    while (it.next()) |entry| {
        const bin = entry.value_ptr.*;
        const f = std.Io.Dir.openFileAbsolute(io, bin.path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.log.info("Binary {s} missing at {s}, removing from config.", .{ bin.remote_name, bin.path });
                try to_remove.append(allocator, entry.key_ptr.*);
            } else {
                std.log.warn("Could not verify binary {s} at {s}: {}", .{ bin.remote_name, bin.path, err });
            }
            continue;
        };
        f.close(io);
    }

    for (to_remove.items) |key| {
        _ = conf.bins.remove(key);
    }

    if (to_remove.items.len > 0) {
        try config.save(conf, env, io);
        std.log.info("Pruned {} entries.", .{to_remove.items.len});
    } else {
        std.log.info("Nothing to prune.", .{});
    }
}
