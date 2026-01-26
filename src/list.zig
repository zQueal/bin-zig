const std = @import("std");
const config = @import("config.zig");

pub fn list(allocator: std.mem.Allocator, conf: *config.Config) !void {
    _ = allocator;
    if (conf.bins.count() == 0) {
        std.log.info("No binaries currently managed by bin-zig.", .{});
        return;
    }

    std.log.info("Managed binaries:", .{});
    var it = conf.bins.iterator();
    while (it.next()) |entry| {
        const bin = entry.value_ptr.*;
        std.log.info("  {s} (version: {s}, path: {s})", .{ bin.remote_name, bin.version, bin.path });
    }
}
