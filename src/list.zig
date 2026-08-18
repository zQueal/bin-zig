const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");

/// Mirrors cmd/list.go: prints a table of managed binaries with version, URL
/// and status, sorted by path. Headers are magenta-italic, status is green
/// "OK" or red "missing <path>" (fatih/color), matching the reference.
pub fn list(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap) !void {
    var out_buf: [1]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);

    var paths = std.ArrayList([]const u8).empty;
    defer paths.deinit(allocator);
    var it = conf.bins.iterator();
    while (it.next()) |entry| try paths.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    // Column widths (matching the reference binary's list output).
    var p_len: usize = 0;
    var v_len: usize = 0;
    var u_len: usize = 0;
    for (paths.items) |p| {
        const b = conf.bins.get(p).?;
        const ep = config.expandEnv(allocator, b.path, env) catch b.path;
        defer allocator.free(ep);
        p_len = @max(p_len, ep.len);
        v_len = @max(v_len, b.version.len);
        u_len = @max(u_len, b.url.len);
    }

    // Header (magenta italic, matching the reference).
    const header = try std.fmt.allocPrint(allocator, "\n{s}  {s}  {s}  {s}", .{
        cli.magentaItalic(padRight(allocator, "Path", p_len)),
        cli.magentaItalic(padRight(allocator, "Version", v_len)),
        cli.magentaItalic(padRight(allocator, "URL", u_len)),
        cli.magentaItalic("Status"),
    });
    defer allocator.free(header);
    try out.interface.writeAll(header);

    for (paths.items) |p| {
        const b = conf.bins.get(p).?;
        const ep = try config.expandEnv(allocator, b.path, env);
        defer allocator.free(ep);

        var status: []const u8 = undefined;
        if (std.fs.cwd().statFile(ep)) |_| {
            status = cli.green("OK");
        } else |_| {
            const missing_msg = try std.fmt.allocPrint(allocator, "missing {s}", .{ep});
            defer allocator.free(missing_msg);
            status = cli.red(missing_msg);
        }

        const marker = if (b.pinned) "*" else "";
        const version_col = try std.fmt.allocPrint(allocator, "{s}{s}", .{ marker, b.version });
        defer allocator.free(version_col);

        const row = try std.fmt.allocPrint(allocator, "\n{s}  {s}  {s}  {s}", .{
            padRight(allocator, ep, p_len),
            padRight(allocator, version_col, v_len),
            padRight(allocator, b.url, u_len),
            status,
        });
        defer allocator.free(row);
        try out.interface.writeAll(row);
    }
    try out.interface.print("\n\n", .{});
}

fn padRight(allocator: std.mem.Allocator, s: []const u8, width: usize) []const u8 {
    if (s.len >= width) return s;
    const padded = allocator.alloc(u8, width) catch return s;
    @memcpy(padded[0..s.len], s);
    @memset(padded[s.len..], ' ');
    return padded;
}
