const std = @import("std");
const config = @import("config.zig");

pub fn clean(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.Environ, io: std.Io) !void {
    _ = env;
    const cache_dir = try std.fs.path.join(allocator, &[_][]const u8{ std.fs.path.dirname(conf.bin_dir) orelse ".", "cache" });
    defer allocator.free(cache_dir);

    std.log.info("Cleaning cache directory: {s}", .{cache_dir});

    var dir = std.Io.Dir.openDirAbsolute(io, cache_dir, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.log.info("Cache directory does not exist. Nothing to clean.", .{});
            return;
        }
        return err;
    };
    defer dir.close(io);

    var it = dir.iterate();
    var deleted_count: usize = 0;
    var total_size: u64 = 0;

    while (try it.next(io)) |entry| {
        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ cache_dir, entry.name });
        defer allocator.free(full_path);

        if (entry.kind == .directory) {
            // Recursive delete for directories like tmp_extract
            const dir_size = deleteDirRecursive(full_path, io) catch |err| {
                std.log.warn("Could not delete directory {s}: {}", .{ entry.name, err });
                continue;
            };
            total_size += dir_size;
        } else {
            const file = std.Io.Dir.openFileAbsolute(io, full_path, .{}) catch |err| {
                std.log.warn("Could not open file {s}: {}", .{ entry.name, err });
                continue;
            };
            const stat = file.stat(io) catch {
                file.close(io);
                std.log.warn("Could not stat file {s}", .{entry.name});
                continue;
            };
            file.close(io);
            total_size += stat.size;
            std.Io.Dir.deleteFileAbsolute(io, full_path) catch |err| {
                std.log.warn("Could not delete file {s}: {}", .{ entry.name, err });
                continue;
            };
        }
        deleted_count += 1;
    }

    if (deleted_count == 0) {
        std.log.info("Cache is already empty.", .{});
    } else {
        std.log.info("Successfully cleaned {} items ({d} bytes).", .{ deleted_count, total_size });
    }
}

fn deleteDirRecursive(path: []const u8, io: std.Io) !u64 {
    var dir = try std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true });
    defer dir.close(io);

    var total_size: u64 = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var sub_path_buf: [4096]u8 = undefined;
        const sub_path = try std.fmt.bufPrint(&sub_path_buf, "{s}/{s}", .{ path, entry.name });

        if (entry.kind == .directory) {
            total_size += try deleteDirRecursive(sub_path, io);
        } else {
            const file = std.Io.Dir.openFileAbsolute(io, sub_path, .{}) catch |err| {
                std.log.warn("Could not open file {s}: {}", .{ entry.name, err });
                try std.Io.Dir.deleteFileAbsolute(io, sub_path);
                continue;
            };
            const stat = file.stat(io) catch {
                file.close(io);
                try std.Io.Dir.deleteFileAbsolute(io, sub_path);
                continue;
            };
            file.close(io);
            total_size += stat.size;
            try std.Io.Dir.deleteFileAbsolute(io, sub_path);
        }
    }
    try std.Io.Dir.deleteDirAbsolute(io, path);
    return total_size;
}
