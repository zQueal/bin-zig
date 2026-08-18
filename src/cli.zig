//! CLI output formatting mirroring the reference implementation's look:
//! caarlos0/log v0.6.2 line style (`  • ` info / `  ⨯ ` error, bold colored
//! level symbols on stderr) and fatih/color message segments (yellow/green
//! versions, magenta-italic list headers) on stdout.

const std = @import("std");

/// Runtime debug-log gate (set from `--debug`).
pub var debug_enabled = false;

/// Color for the log level symbol (stderr writer, colorprofile behavior).
var log_color_enabled = false;
/// Color for fatih/color message segments (stdout writer).
var msg_color_enabled = false;

var global_arena: std.heap.ArenaAllocator = undefined;
var global_allocator: std.mem.Allocator = undefined;

/// Initializes color support and the formatting arena. Mirrors the reference:
/// CI / CLICOLOR_FORCE / FORCE_COLOR force color on, NO_COLOR and
/// TERM=dumb force it off, otherwise it depends on whether the stream is a TTY.
pub fn init(env: std.process.EnvMap) void {
    global_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    global_allocator = global_arena.allocator();

    const forced = env.get("CI") != null or
        (env.get("CLICOLOR_FORCE") orelse "").len > 0 or
        (env.get("FORCE_COLOR") orelse "").len > 0;
    const disabled = env.get("NO_COLOR") != null or
        std.mem.eql(u8, env.get("TERM") orelse "", "dumb");

    log_color_enabled = !disabled and (forced or std.fs.File.stderr().isTty());
    msg_color_enabled = !disabled and (forced or std.fs.File.stdout().isTty());
}

fn colorize(enabled: bool, code: []const u8, s: []const u8) []const u8 {
    if (!enabled) return s;
    return std.fmt.allocPrint(global_allocator, "\x1b[{s}m{s}\x1b[0m", .{ code, s }) catch s;
}

/// fatih/color.FgYellow (33) — current version in update lines.
pub fn yellow(s: []const u8) []const u8 {
    return colorize(msg_color_enabled, "33", s);
}

/// fatih/color.FgGreen (32) — new version in update lines, "OK" status.
pub fn green(s: []const u8) []const u8 {
    return colorize(msg_color_enabled, "32", s);
}

/// fatih/color.FgRed (31) — "missing ..." status.
pub fn red(s: []const u8) []const u8 {
    return colorize(msg_color_enabled, "31", s);
}

/// fatih/color FgMagenta + Italic (35;3) — list headers.
pub fn magentaItalic(s: []const u8) []const u8 {
    return colorize(msg_color_enabled, "35;3", s);
}

/// Serializes all stderr output: the log formatter allocates from a shared
/// arena and writes to stderr from worker threads during parallel updates, so
/// both the allocation and the write must be mutually exclusive.
var stderr_mutex: std.Thread.Mutex = .{};

/// Log renderer matching caarlos0/log v0.6.2:
///   "  • " (info/debug/warn) or "  ⨯ " (error), bold-colored, then message.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (level == .debug and !debug_enabled) return;

    stderr_mutex.lock();
    defer stderr_mutex.unlock();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(global_allocator);
    const w = out.writer(global_allocator);

    const symbol: []const u8 = if (level == .err) "⨯" else "•";
    if (log_color_enabled) {
        const code: []const u8 = switch (level) {
            .err => "1;91",
            .warn => "1;93",
            .info => "1;94",
            .debug => "1;97",
        };
        w.print("\x1b[{s}m  {s}\x1b[0m ", .{ code, symbol }) catch return;
    } else {
        w.print("  {s} ", .{symbol}) catch return;
    }
    w.print(format, args) catch return;
    w.print("\n", .{}) catch return;
    writeStderrLocked(out.items);
}

/// Renders the final "command failed" error line the way the reference does:
/// `  ⨯ <message>` padded to 48 columns, then ` error=<message>` with the key
/// styled like the level symbol.
pub fn errorLine(message: []const u8, err_msg: []const u8) void {
    stderr_mutex.lock();
    defer stderr_mutex.unlock();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(global_allocator);
    const w = out.writer(global_allocator);

    if (log_color_enabled) {
        w.print("\x1b[1;91m  ⨯\x1b[0m {s}", .{message}) catch return;
    } else {
        w.print("  ⨯ {s}", .{message}) catch return;
    }
    if (message.len < 48) {
        var i: usize = message.len;
        while (i < 48) : (i += 1) w.writeAll(" ") catch return;
    }
    if (log_color_enabled) {
        w.print(" \x1b[1;91merror\x1b[0m={s}\n", .{err_msg}) catch return;
    } else {
        w.print(" error={s}\n", .{err_msg}) catch return;
    }
    writeStderrLocked(out.items);
}

/// Writes a raw line to stderr (used for the unknown-command message, which
/// the reference prints to stderr without any log prefix).
pub fn stderrLine(comptime format: []const u8, args: anytype) void {
    stderr_mutex.lock();
    defer stderr_mutex.unlock();

    var out = std.ArrayList(u8).empty;
    defer out.deinit(global_allocator);
    const w = out.writer(global_allocator);
    w.print(format, args) catch return;
    writeStderrLocked(out.items);
}

/// Writes UTF-8 bytes to stderr. On Windows, when stderr is a real console,
/// the bytes are converted to UTF-16 and written via WriteConsoleW so that
/// non-ASCII glyphs (•, ⨯) render correctly regardless of the console code
/// page (raw UTF-8 bytes would be decoded as CP-437/CP-850 and mojibake).
/// Pipes and files keep the raw bytes (identical to the reference output).
/// Callers must hold stderr_mutex.
fn writeStderrLocked(bytes: []const u8) void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        const w = std.os.windows;
        const handle = w.GetStdHandle(w.STD_ERROR_HANDLE) catch {
            return writeStderrRaw(bytes);
        };
        var mode: w.DWORD = 0;
        if (w.kernel32.GetConsoleMode(handle, &mode) != 0) {
            const wide = std.unicode.utf8ToUtf16LeAlloc(global_allocator, bytes) catch {
                return writeStderrRaw(bytes);
            };
            defer global_allocator.free(wide);
            var written: w.DWORD = 0;
            _ = w.kernel32.WriteConsoleW(handle, wide.ptr, @intCast(wide.len), &written, null);
            return;
        }
    }
    writeStderrRaw(bytes);
}

fn writeStderrRaw(bytes: []const u8) void {
    const file = std.fs.File.stderr();
    var buf: [1]u8 = undefined;
    var w = file.writer(&buf);
    w.interface.writeAll(bytes) catch return;
    w.interface.flush() catch return;
}

// ---------------------------------------------------------------------------
// Download progress bar, mirroring cheggaaa/pb v2 (pb.Full preset):
//   "{counters} {bar} {percent} {speed} ETA {duration}"
//   e.g. " 12.3 MiB / 89.1 MiB [---->______] 13.80% 3.2 MiB/s ETA 25s"
// ---------------------------------------------------------------------------

const bar_refresh_ns = 200 * std.time.ns_per_ms;
const bar_default_width = 100;

pub const ProgressBar = struct {
    total: u64,
    started: i128 = 0,
    last_render: i128 = 0,
    active: bool = false,

    pub fn init(total: u64) ProgressBar {
        const now = std.time.nanoTimestamp();
        return .{
            .total = total,
            .started = now,
            .last_render = now,
            .active = std.fs.File.stderr().isTty(),
        };
    }

    /// Renders the current state (throttled to 200ms).
    pub fn update(self: *ProgressBar, current: u64) void {
        if (!self.active) return;
        const now = std.time.nanoTimestamp();
        if (now - self.last_render < bar_refresh_ns) return;
        self.last_render = now;
        self.writeLine(current, false);
    }

    /// Final render, then a newline.
    pub fn finish(self: *ProgressBar, current: u64) void {
        if (!self.active) return;
        self.writeLine(current, true);
        const file = std.fs.File.stderr();
        var buf: [1]u8 = undefined;
        var w = file.writer(&buf);
        w.interface.writeAll("\n") catch {};
        w.interface.flush() catch {};
    }

    fn writeLine(self: *ProgressBar, current: u64, finished: bool) void {
        var buf: [512]u8 = undefined;
        const elapsed_s = @as(f64, @floatFromInt(std.time.nanoTimestamp() - self.started)) / @as(f64, std.time.ns_per_s);
        const line = renderLine(&buf, self.total, current, finished, elapsed_s);
        const file = std.fs.File.stderr();
        var out_buf: [1]u8 = undefined;
        var w2 = file.writer(&out_buf);
        w2.interface.print("\r{s}", .{line}) catch return;
        w2.interface.flush() catch return;
    }
};

/// Builds one progress bar line: "{counters} {bar} {percent} {speed} ETA {dur}".
fn renderLine(buf: *[512]u8, total: u64, current: u64, finished: bool, elapsed_s: f64) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // Scratch space for formatBytes/durationString: MUST NOT alias the output
    // buffer (the fixed-buffer-stream writer memcpys from the formatted slice).
    var s1: [64]u8 = undefined;
    var s2: [64]u8 = undefined;
    var s3: [64]u8 = undefined;
    var s4: [64]u8 = undefined;

    // counters
    w.print("{s} / {s} ", .{ formatBytes(&s1, current), formatBytes(&s2, total) }) catch return buf[0..0];

    // bar: [----->____] with adaptive width
    var width_left: usize = bar_default_width;
    width_left -= 2; // "[", "]"
    var cur_count: usize = 0;
    if (total > 0) {
        const frac = @as(f128, @floatFromInt(current)) / @as(f128, @floatFromInt(total));
        cur_count = @intFromFloat(@ceil(frac * @as(f128, @floatFromInt(width_left))));
    }
    w.writeAll("[") catch return buf[0..0];
    if (total == current and finished) {
        var i: usize = 0;
        while (i < width_left) : (i += 1) w.writeAll("-") catch return buf[0..0];
    } else if (cur_count > 1) {
        var i: usize = 0;
        while (i < cur_count - 1) : (i += 1) w.writeAll("-") catch return buf[0..0];
        w.writeAll(">") catch return buf[0..0];
        i = cur_count;
        while (i < width_left) : (i += 1) w.writeAll("_") catch return buf[0..0];
    } else if (cur_count > 0) {
        w.writeAll(">") catch return buf[0..0];
        var i: usize = 1;
        while (i < width_left) : (i += 1) w.writeAll("_") catch return buf[0..0];
    } else {
        var i: usize = 0;
        while (i < width_left) : (i += 1) w.writeAll("_") catch return buf[0..0];
    }
    w.writeAll("] ") catch return buf[0..0];

    // percent
    if (total > 0) {
        const pct = @as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(total)) * 100.0;
        w.print("{d:0>2}.{d:0>2}% ", .{ @as(u64, @intFromFloat(@floor(pct))), @as(u64, @intFromFloat(@floor(pct * 100))) % 100 }) catch return buf[0..0];
    } else {
        w.writeAll("?% ") catch return buf[0..0];
    }

    // speed + ETA
    if (elapsed_s > 0 and current > 0) {
        const speed = @as(f64, @floatFromInt(current)) / elapsed_s;
        w.print("{s}/s ", .{formatBytes(&s3, @intFromFloat(speed))}) catch return buf[0..0];
        if (!finished and total > current) {
            const remain = @as(f64, @floatFromInt(total - current)) / speed;
            w.print("ETA {s}", .{durationString(&s4, remain)}) catch return buf[0..0];
        }
    } else {
        w.writeAll("0 B/s") catch return buf[0..0];
    }

    return fbs.getWritten();
}

/// pb formatBytes: 1024-based, "%.02f KiB/MiB/GiB/TiB" or "%d B".
fn formatBytes(buf: []u8, n: u64) []const u8 {
    const KiB: f64 = 1024.0;
    const MiB = KiB * 1024.0;
    const GiB = MiB * 1024.0;
    const TiB = GiB * 1024.0;
    const v = @as(f64, @floatFromInt(n));
    const s = std.fmt.bufPrint(buf, "{d:.2} TiB", .{v / TiB}) catch return "?";
    if (n >= @as(u64, @intFromFloat(TiB))) return s;
    const s2 = std.fmt.bufPrint(buf, "{d:.2} GiB", .{v / GiB}) catch return "?";
    if (n >= @as(u64, @intFromFloat(GiB))) return s2;
    const s3 = std.fmt.bufPrint(buf, "{d:.2} MiB", .{v / MiB}) catch return "?";
    if (n >= @as(u64, @intFromFloat(MiB))) return s3;
    const s4 = std.fmt.bufPrint(buf, "{d:.2} KiB", .{v / KiB}) catch return "?";
    if (n >= @as(u64, @intFromFloat(KiB))) return s4;
    return std.fmt.bufPrint(buf, "{d} B", .{n}) catch "?";
}

/// Go time.Duration.String() for ETA values (no zero padding, fractional
/// seconds trimmed of trailing zeros: "1m5s", "1h30m0s", "3.2s", "400ms").
fn durationString(buf: []u8, seconds_f: f64) []const u8 {
    if (seconds_f <= 0) return "0s";
    const total_ns: u64 = @intFromFloat(seconds_f * 1_000_000_000.0);
    const ns_per_s: u64 = 1_000_000_000;
    const ns_per_m: u64 = 60 * ns_per_s;
    const ns_per_h: u64 = 3600 * ns_per_s;

    if (total_ns < ns_per_s) {
        if (total_ns >= 1_000_000) return std.fmt.bufPrint(buf, "{d}ms", .{total_ns / 1_000_000}) catch "?";
        if (total_ns >= 1_000) return std.fmt.bufPrint(buf, "{d}µs", .{total_ns / 1_000}) catch "?";
        return std.fmt.bufPrint(buf, "{d}ns", .{total_ns}) catch "?";
    }

    const h = total_ns / ns_per_h;
    const m = (total_ns % ns_per_h) / ns_per_m;
    const s = (total_ns % ns_per_m) / ns_per_s;
    const frac_ms = (total_ns % ns_per_s) / 1_000_000;

    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();
    if (h > 0) w.print("{d}h", .{h}) catch return "?";
    if (h > 0 or m > 0) w.print("{d}m", .{m}) catch return "?";

    var frac_buf: [4]u8 = undefined;
    var frac_str = std.fmt.bufPrint(&frac_buf, "{d}", .{frac_ms}) catch "";
    while (frac_str.len > 0 and frac_str[frac_str.len - 1] == '0') frac_str = frac_str[0 .. frac_str.len - 1];
    if (frac_str.len == 0) {
        w.print("{d}s", .{s}) catch return "?";
    } else {
        w.print("{d}.{s}s", .{ s, frac_str }) catch return "?";
    }
    return fbs.getWritten();
}

const testing = std.testing;

test "cli: formatBytes matches pb (1024-based)" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("0 B", formatBytes(&buf, 0));
    try testing.expectEqualStrings("512 B", formatBytes(&buf, 512));
    try testing.expectEqualStrings("1.00 KiB", formatBytes(&buf, 1024));
    try testing.expectEqualStrings("2.50 MiB", formatBytes(&buf, 2621440));
    try testing.expectEqualStrings("1.00 GiB", formatBytes(&buf, 1024 * 1024 * 1024));
}

test "cli: durationString matches Go durations" {
    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings("0s", durationString(&buf, 0.0));
    try testing.expectEqualStrings("45s", durationString(&buf, 45.0));
    try testing.expectEqualStrings("1m5s", durationString(&buf, 65.0));
    try testing.expectEqualStrings("3.2s", durationString(&buf, 3.2));
    try testing.expectEqualStrings("1h30m0s", durationString(&buf, 5400.0));
    try testing.expectEqualStrings("400ms", durationString(&buf, 0.4));
}

test "cli: progress bar line matches pb.Full format" {
    var buf: [512]u8 = undefined;
    const total = 10 * 1024 * 1024;
    const current = 2 * 1024 * 1024;
    const line = renderLine(&buf, total, current, false, 1.0);
    try testing.expect(std.mem.startsWith(u8, line, "2.00 MiB / 10.00 MiB ["));
    try testing.expect(std.mem.indexOf(u8, line, "] 20.00% ") != null);
    try testing.expect(std.mem.endsWith(u8, line, "ETA 4s"));
}
