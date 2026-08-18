const std = @import("std");
const config = @import("config.zig");
const prompt = @import("prompt.zig");

/// Mirrors cmd/prune.go: removes config entries whose binary is missing from
/// disk, asking for confirmation unless --force.
pub fn prune(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, force: bool) !void {
    var to_del = std.ArrayList([]const u8).empty;
    defer to_del.deinit(allocator);

    var it = conf.bins.iterator();
    while (it.next()) |entry| {
        const b = entry.value_ptr.*;
        const ep = try config.expandEnv(allocator, b.path, env);
        defer allocator.free(ep);
        if (std.fs.cwd().statFile(ep)) |_| {
            // exists
        } else |_| {
            std.log.info("{s} not found removing", .{ep});
            try to_del.append(allocator, b.path);
        }
    }

    if (to_del.items.len == 0) return;

    if (!force) {
        try prompt.confirm("The following paths will be removed. Continue?");
    }

    try config.removeBinaries(conf, to_del.items);
}
