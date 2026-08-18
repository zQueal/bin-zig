const std = @import("std");

fn stdoutWriter() std.fs.File.Writer {
    var buf: [1]u8 = undefined;
    return std.fs.File.stdout().writer(&buf);
}

/// Reads one line from stdin, trimming trailing whitespace. Returns null on EOF.
fn readLine(allocator: std.mem.Allocator) !?[]const u8 {
    var buf: [1]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&buf);
    const line = try stdin.interface.takeDelimiter('\n') orelse return null;
    return try allocator.dupe(u8, std.mem.trimRight(u8, line, " \t\r\n"));
}

/// Select prompts the user which of the available options is the desired one
/// through STDIN and returns the selected one (mirrors options.Select).
pub fn select(msg: []const u8, opts: []const []const u8) ![]const u8 {
    return selectWithDefault(msg, opts, null);
}

/// SelectWithDefault behaves like Select but, when default_idx is set, marks
/// that option as the default and returns it when the user submits an empty
/// line (just presses Enter). A null default_idx means no default, in which
/// case empty input is rejected (mirrors options.SelectWithDefault).
pub fn selectWithDefault(msg: []const u8, opts: []const []const u8, default_idx: ?usize) ![]const u8 {
    const allocator = std.heap.page_allocator;
    if (opts.len == 1) return opts[0];

    var out_buf: [1]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    try out.interface.print("\n{s}\n", .{msg});
    for (opts, 0..) |o, i| {
        if (default_idx != null and i == default_idx.?) {
            try out.interface.print("\n [{d}] {s} (default)", .{ i + 1, o });
        } else {
            try out.interface.print("\n [{d}] {s}", .{ i + 1, o });
        }
    }

    while (true) {
        if (default_idx) |d| {
            try out.interface.print("\n Select an option [{d}]: ", .{d + 1});
        } else {
            try out.interface.print("\n Select an option: ", .{});
        }
        try out.interface.flush();

        const input = try readLine(allocator) orelse {
            if (default_idx != null) return opts[default_idx.?];
            return error.EndOfStream;
        };
        defer allocator.free(input);

        if (input.len == 0) {
            if (default_idx) |d| return opts[d];
            try out.interface.writeAll("Invalid option");
            continue;
        }

        const opt = std.fmt.parseInt(usize, input, 10) catch {
            try out.interface.writeAll("Invalid option");
            continue;
        };
        if (opt < 1 or opt > opts.len) {
            try out.interface.writeAll("Invalid option");
            continue;
        }
        return opts[opt - 1];
    }
}

/// SelectCustom prompts the user which of the available options is the desired
/// one, or accepts a custom typed value (mirrors options.SelectCustom).
pub fn selectCustom(msg: []const u8, opts: []const []const u8) ![]const u8 {
    const allocator = std.heap.page_allocator;
    if (opts.len == 1) return opts[0];

    var out_buf: [1]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    try out.interface.print("\n{s}\n", .{msg});
    for (opts, 0..) |o, i| {
        try out.interface.print("\n [{d}] {s}", .{ i + 1, o });
    }

    while (true) {
        try out.interface.print("\n Select an option or type a custom value: ", .{});
        try out.interface.flush();

        const line = try readLine(allocator) orelse return error.EndOfStream;
        defer allocator.free(line);

        // Go's fmt.Scanln reads a single whitespace-delimited token.
        const token = std.mem.trim(u8, line, " \t");
        if (token.len == 0) continue;

        const v = std.fmt.parseInt(usize, token, 10) catch {
            return try allocator.dupe(u8, token);
        };

        if (v < 1 or v > opts.len) {
            try out.interface.writeAll("Invalid option");
            continue;
        }
        return opts[v - 1];
    }
}
