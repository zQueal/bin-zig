const std = @import("std");
const config = @import("config.zig");

pub fn remove(allocator: std.mem.Allocator, conf: *config.Config, name: []const u8, env: std.process.Environ, io: std.Io) !void {
    _ = allocator;
    
    var it = conf.bins.iterator();
    var bin_to_remove: ?config.Binary = null;
    var key_to_remove: ?[]const u8 = null;
    
    var input_clean = name;
    if (std.mem.endsWith(u8, name, ".exe")) {
        input_clean = name[0 .. name.len - 4];
    }
    
    while (it.next()) |entry| {
        var remote_clean = entry.value_ptr.remote_name;
        if (std.mem.endsWith(u8, remote_clean, ".exe")) {
            remote_clean = remote_clean[0..remote_clean.len-4];
        }

        if (std.mem.eql(u8, remote_clean, input_clean)) {
            bin_to_remove = entry.value_ptr.*;
            key_to_remove = entry.key_ptr.*;
            break;
        }
    }
    
    if (bin_to_remove == null) {
        std.log.err("Binary '{s}' not found in managed list.", .{name});
        return error.BinaryNotFound;
    }
    
    // Remove file
    // Use std.fs.deleteFileAbsolute
    std.Io.Dir.deleteFileAbsolute(io, bin_to_remove.?.path) catch |err| {
        std.log.warn("Could not delete file {s}: {}", .{ bin_to_remove.?.path, err });
    };
    
    // Remove from config
    _ = conf.bins.remove(key_to_remove.?);
    try config.save(conf, env, io);
    
    std.log.info("Successfully removed '{s}'", .{name});
}
