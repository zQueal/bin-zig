const std = @import("std");
const config = @import("config.zig");

/// Mirrors cmd/pin.go / cmd/unpin.go.
pub fn pin(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, names: []const []const u8, value: bool) !void {
    var pinned = std.ArrayList([]const u8).empty;
    defer pinned.deinit(allocator);

    for (names) |name| {
        const bin = config.getBinPath(allocator, conf, env, name) catch |err| {
            std.log.err("error resolving binary {s}: {s}", .{ name, @errorName(err) });
            return err;
        };
        const b = conf.bins.get(bin).?;
        var updated = b;
        updated.pinned = value;
        try config.upsertBinary(conf, updated);
        try pinned.append(allocator, name);
    }

    if (pinned.items.len > 0) {
        const joined = try std.mem.join(allocator, " ", pinned.items);
        defer allocator.free(joined);
        if (value) {
            std.log.info("Pinned {s}", .{joined});
        } else {
            std.log.info("Unpinned {s}", .{joined});
        }
    }
}
