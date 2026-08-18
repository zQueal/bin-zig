const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");

/// Mirrors cmd/remove.go.
pub fn remove(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, names: []const []const u8) !void {
    var to_remove = std.ArrayList([]const u8).empty;
    defer to_remove.deinit(allocator);

    for (names) |name| {
        const bp = config.getBinPath(allocator, conf, env, name) catch |err| switch (err) {
            error.FileNotFound => {
                cli.stderrLine("binary {s} not found in PATH, skipping\n", .{name});
                continue;
            },
            else => return err,
        };
        const ebp = try config.expandEnv(allocator, bp, env);
        defer allocator.free(ebp);

        if (conf.bins.contains(ebp)) {
            try to_remove.append(allocator, try allocator.dupe(u8, ebp));
            std.fs.cwd().deleteFile(ebp) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {
                    std.log.err("error removing path {s}: {s}", .{ ebp, @errorName(err) });
                    return err;
                },
            };
        }
    }

    try config.removeBinaries(conf, to_remove.items);
}
