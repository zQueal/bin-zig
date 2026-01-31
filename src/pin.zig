const std = @import("std");
const config = @import("config.zig");

pub fn pin(allocator: std.mem.Allocator, conf: *config.Config, names: []const []const u8, env: std.process.Environ, io: std.Io) !void {
    var successes: usize = 0;
    var failures = std.ArrayList([]const u8).empty;
    defer failures.deinit(allocator);

    for (names) |name| {
        var found = false;
        var it = conf.bins.iterator();

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
                entry.value_ptr.pinned = true;
                std.log.info("Pinned {s} to version {s}", .{ entry.value_ptr.remote_name, entry.value_ptr.version });
                successes += 1;
                found = true;
                break;
            }
        }

        if (!found) {
            std.log.warn("Binary '{s}' not found.", .{name});
            try failures.append(allocator, name);
        }
    }

    if (successes > 0) {
        try config.save(conf, env, io);
        std.log.info("Successfully pinned {d} binary(s)", .{successes});
    }
    if (failures.items.len > 0) {
        for (failures.items) |f| {
            std.log.warn("Failed to pin: {s}", .{f});
        }
    }

    return if (successes == 0) error.AllOperationsFailed else if (failures.items.len > 0) error.SomeOperationsFailed else {};
}

pub fn unpin(allocator: std.mem.Allocator, conf: *config.Config, names: []const []const u8, env: std.process.Environ, io: std.Io) !void {
    var successes: usize = 0;
    var failures = std.ArrayList([]const u8).empty;
    defer failures.deinit(allocator);

    for (names) |name| {
        var found = false;
        var it = conf.bins.iterator();

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
                entry.value_ptr.pinned = false;
                std.log.info("Unpinned {s}", .{entry.value_ptr.remote_name});
                successes += 1;
                found = true;
                break;
            }
        }

        if (!found) {
            std.log.warn("Binary '{s}' not found.", .{name});
            try failures.append(allocator, name);
        }
    }

    if (successes > 0) {
        try config.save(conf, env, io);
        std.log.info("Successfully unpinned {d} binary(s)", .{successes});
    }
    if (failures.items.len > 0) {
        for (failures.items) |f| {
            std.log.warn("Failed to unpin: {s}", .{f});
        }
    }

    return if (successes == 0) error.AllOperationsFailed else if (failures.items.len > 0) error.SomeOperationsFailed else {};
}
