const std = @import("std");
const config = @import("config.zig");

pub fn remove(allocator: std.mem.Allocator, conf: *config.Config, names: []const []const u8, env: std.process.Environ, io: std.Io) !void {
    var successes: usize = 0;
    var failures = std.ArrayList([]const u8).empty;
    defer failures.deinit(allocator);

    for (names) |name| {
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
                remote_clean = remote_clean[0 .. remote_clean.len - 4];
            }

            if (std.mem.eql(u8, remote_clean, input_clean)) {
                bin_to_remove = entry.value_ptr.*;
                key_to_remove = entry.key_ptr.*;
                break;
            }
        }

        if (bin_to_remove == null) {
            std.log.warn("Binary '{s}' not found in managed list.", .{name});
            try failures.append(allocator, name);
            continue;
        }

        // Remove file
        std.Io.Dir.deleteFileAbsolute(io, bin_to_remove.?.path) catch |err| {
            std.log.warn("Could not delete file {s}: {}", .{ bin_to_remove.?.path, err });
            try failures.append(allocator, name);
            continue;
        };

        // Remove from config
        _ = conf.bins.remove(key_to_remove.?);
        std.log.info("Successfully removed '{s}'", .{name});
        successes += 1;
    }

    // Save config once after all operations
    if (successes > 0) {
        try config.save(conf, env, io);
    }

    // Report summary
    if (successes > 0) {
        std.log.info("Successfully removed {d} binary(s)", .{successes});
    }
    if (failures.items.len > 0) {
        for (failures.items) |f| {
            std.log.warn("Failed to remove: {s}", .{f});
        }
    }

    return if (successes == 0) error.AllOperationsFailed else if (failures.items.len > 0) error.SomeOperationsFailed else {};
}
