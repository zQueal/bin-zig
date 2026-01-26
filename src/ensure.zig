const std = @import("std");
const config = @import("config.zig");
const install = @import("install.zig");

pub fn ensure(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.Environ, io: std.Io) !void {
    std.log.info("Ensuring all managed binaries are present...", .{});
    var it = conf.bins.iterator();
    while (it.next()) |entry| {
        const bin = entry.value_ptr.*;
        // Check if file exists
        const f = std.Io.Dir.openFileAbsolute(io, bin.path, .{}) catch |err| {
            if (err == error.FileNotFound) {
                std.log.info("Binary {s} missing at {s}, reinstalling...", .{ bin.remote_name, bin.path });
                try install.install(allocator, conf, bin.url, env, io, .{ .alias = bin.remote_name });
            }
            continue;
        };
        f.close(io);
    }
}
