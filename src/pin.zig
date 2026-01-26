const std = @import("std");
const config = @import("config.zig");

pub fn pin(allocator: std.mem.Allocator, conf: *config.Config, name: []const u8, env: std.process.Environ, io: std.Io) !void {
    _ = allocator;
    var it = conf.bins.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.remote_name, name)) {
            entry.value_ptr.pinned = true;
            try config.save(conf, env, io);
            std.log.info("Pinned {s} to version {s}", .{ name, entry.value_ptr.version });
            return;
        }
    }
    std.log.err("Binary '{s}' not found.", .{name});
    return error.BinaryNotFound;
}

pub fn unpin(allocator: std.mem.Allocator, conf: *config.Config, name: []const u8, env: std.process.Environ, io: std.Io) !void {
    _ = allocator;
    var it = conf.bins.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.value_ptr.remote_name, name)) {
            entry.value_ptr.pinned = false;
            try config.save(conf, env, io);
            std.log.info("Unpinned {s}", .{name});
            return;
        }
    }
    std.log.err("Binary '{s}' not found.", .{name});
    return error.BinaryNotFound;
}
