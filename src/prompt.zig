const std = @import("std");

/// Confirm prints a confirmation prompt for the given message and waits for
/// the user's input (mirrors prompt.Confirm: empty / y / yes continue,
/// anything else aborts with error.CommandAborted).
pub fn confirm(message: []const u8) !void {
    var out_buf: [1]u8 = undefined;
    var out = std.fs.File.stdout().writer(&out_buf);
    try out.interface.print("\n{s} [Y/n] ", .{message});
    try out.interface.flush();

    var in_buf: [1]u8 = undefined;
    var stdin = std.fs.File.stdin().reader(&in_buf);
    const line = try stdin.interface.takeDelimiter('\n') orelse return error.InvalidInput;
    const response = std.mem.trim(u8, line, " \t\r\n");

    if (response.len == 0 or std.ascii.eqlIgnoreCase(response, "y") or std.ascii.eqlIgnoreCase(response, "yes")) {
        return;
    }
    return error.CommandAborted;
}
