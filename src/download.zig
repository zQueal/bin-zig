const std = @import("std");
const utils = @import("utils.zig");

pub const DownloadOptions = struct {
    threads: u32 = 4,
    min_parallel_size: u64 = 5 * 1024 * 1024, // 5MB
};

const Context = struct {
    client: *std.http.Client,
    url: []const u8,
    file: std.Io.File,
    io: std.Io,
    start: u64,
    end: u64,
    id: u32,
    progress: *std.atomic.Value(u64),
};

const DownloadInfo = struct {
    final_url: []const u8,
    size: u64,
    supports_ranges: bool,
};

pub fn download(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, dest_path: []const u8, io: std.Io, options: DownloadOptions) !void {
    const info = try fetchDownloadInfo(allocator, client, url);
    defer allocator.free(info.final_url);

    const file = try std.Io.Dir.createFileAbsolute(io, dest_path, .{ .read = true });
    defer file.close(io);

    if (info.supports_ranges and info.size >= options.min_parallel_size and options.threads > 1) {
        try downloadParallel(allocator, client, info, file, io, options);
    } else {
        try downloadStreaming(allocator, client, info.final_url, file, io);
    }
}

fn fetchDownloadInfo(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8) !DownloadInfo {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
    });
    defer req.deinit();

    var head_buf: [4096]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);

    if (resp.head.status != .ok) return error.DownloadFailed;

    const final_url = try std.fmt.allocPrint(allocator, "{}", .{req.uri});
    
    var size: u64 = 0;
    if (resp.head.content_length) |cl| {
        size = cl;
    }

    var supports_ranges = false;
    // Iterate over headers in resp.head.bytes
    var it = std.mem.splitSequence(u8, resp.head.bytes, "\r\n");
    _ = it.next(); // Skip status line
    while (it.next()) |line| {
        if (line.len == 0) break;
        var line_it = std.mem.splitScalar(u8, line, ':');
        const name = line_it.next() orelse continue;
        if (std.ascii.eqlIgnoreCase(name, "accept-ranges")) {
            const val = std.mem.trim(u8, line_it.rest(), " \t");
            if (std.mem.eql(u8, val, "bytes")) supports_ranges = true;
        }
    }

    return .{
        .final_url = final_url,
        .size = size,
        .supports_ranges = supports_ranges,
    };
}

fn downloadStreaming(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, file: std.Io.File, io: std.Io) !void {
    _ = allocator;
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{ .redirect_behavior = @enumFromInt(5) });
    defer req.deinit();

    var head_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);
    if (resp.head.status != .ok) return error.DownloadFailed;

    const total_size = resp.head.content_length orelse 0;
    var downloaded: u64 = 0;

    var transfer_buffer: [8192]u8 = undefined;
    var reader = resp.reader(&transfer_buffer);
    var write_buf: [8192]u8 = undefined;
    var writer = file.writerStreaming(io, &write_buf);
    
    var buf: [8192]u8 = undefined;
    var stdout_buf: [128]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &stdout_buf);
    
    while (true) {
        const n = try reader.readSliceShort(&buf);
        if (n == 0) break;
        try writer.interface.writeAll(buf[0..n]);
        downloaded += n;
        
        if (total_size > 0) {
            const percent = downloaded * 100 / total_size;
            try stdout.interface.print("\rDownloading: {d}% ({d}/{d} bytes)", .{ percent, downloaded, total_size });
        } else {
            try stdout.interface.print("\rDownloading: {d} bytes", .{downloaded});
        }
        try stdout.interface.flush();
    }
    try writer.interface.flush();
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();
}

fn downloadParallel(allocator: std.mem.Allocator, client: *std.http.Client, info: DownloadInfo, file: std.Io.File, io: std.Io, options: DownloadOptions) !void {
    std.log.info("Starting parallel download ({} threads, {d} bytes)...", .{options.threads, info.size});
    
    const chunk_size = (info.size + options.threads - 1) / options.threads;
    var threads = try allocator.alloc(std.Thread, options.threads);
    defer allocator.free(threads);

    var contexts = try allocator.alloc(Context, options.threads);
    defer allocator.free(contexts);

    var progress_values = try allocator.alloc(std.atomic.Value(u64), options.threads);
    defer allocator.free(progress_values);
    
    var targets = try allocator.alloc(u64, options.threads);
    defer allocator.free(targets);

    for (0..options.threads) |i| {
        const start = i * chunk_size;
        const end = @min((i + 1) * chunk_size - 1, info.size - 1);
        const target = end - start + 1;
        
        progress_values[i] = std.atomic.Value(u64).init(0);
        targets[i] = target;

        contexts[i] = .{
            .client = client,
            .url = info.final_url,
            .file = file,
            .io = io,
            .start = start,
            .end = end,
            .id = @intCast(i),
            .progress = &progress_values[i],
        };

        threads[i] = try std.Thread.spawn(.{}, downloadChunk, .{&contexts[i]});
    }

    // Reporter loop
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &stdout_buf);
    
    // Enable VT100 on Windows if possible
    if (@import("builtin").os.tag == .windows) {
        const windows = std.os.windows;
        const handle = windows.GetStdHandle(windows.STD_OUTPUT_HANDLE) catch null;
        if (handle) |h| {
            var mode: windows.DWORD = undefined;
            if (windows.kernel32.GetConsoleMode(h, &mode) != 0) {
                _ = windows.kernel32.SetConsoleMode(h, mode | 0x0004); // ENABLE_VIRTUAL_TERMINAL_PROCESSING
            }
        }
    }

    while (true) {
        var all_done = true;
        for (0..options.threads) |i| {
            const d = progress_values[i].load(.monotonic);
            const target = targets[i];
            const percent = if (target > 0) (d * 100 / target) else 100;
            
            // Simplified progress bar [####....]
            const bar_width = 20;
            const filled = (percent * bar_width) / 100;
            var bar: [bar_width]u8 = undefined;
            for (0..bar_width) |j| {
                bar[j] = if (j < filled) '#' else '.';
            }
            
            try stdout.interface.print("Thread {d:2}: [{s}] {d:3}% ({d}/{d})\n", .{ i, bar, percent, d, target });
            if (d < target) all_done = false;
        }

        if (all_done) break;
        try stdout.interface.flush();
        try io.sleep(std.Io.Duration.fromMilliseconds(100), .awake);
        try stdout.interface.print("\x1b[{d}A", .{options.threads});
    }

    for (threads) |t| {
        t.join();
    }
    try stdout.interface.writeAll("\nDownload complete.\n");
    try stdout.interface.flush();
}

fn downloadChunk(ctx: *const Context) void {
    const uri = std.Uri.parse(ctx.url) catch return;
    var range_buf: [128]u8 = undefined;
    const range_header = std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ ctx.start, ctx.end }) catch return;

    var req = ctx.client.request(.GET, uri, .{
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Range", .value = range_header },
        },
    }) catch |err| {
        std.log.err("Thread {}: request failed: {any}", .{ ctx.id, err });
        return;
    };
    defer req.deinit();

    var head_buf: [1024]u8 = undefined;
    var resp = req.receiveHead(&head_buf) catch |err| {
        std.log.err("Thread {}: receiveHead failed: {any}", .{ ctx.id, err });
        return;
    };
    if (resp.head.status != .partial_content and resp.head.status != .ok) {
        std.log.err("Thread {}: unexpected status {d}", .{ ctx.id, @intFromEnum(resp.head.status) });
        return;
    }

    var transfer_buffer: [8192]u8 = undefined;
    var reader = resp.reader(&transfer_buffer);
    
    var buf: [16384]u8 = undefined;
    var offset = ctx.start;
    const limit = ctx.end + 1;

    while (offset < limit) {
        const n = reader.readSliceShort(&buf) catch |err| {
             std.log.err("Thread {}: read error: {any}", .{ ctx.id, err });
             break;
        };
        if (n == 0) break;
        ctx.file.writePositionalAll(ctx.io, buf[0..n], offset) catch |err| {
            std.log.err("Thread {}: write error at offset {}: {any}", .{ ctx.id, offset, err });
            break;
        };
        offset += n;
        ctx.progress.store(offset - ctx.start, .monotonic);
    }
    // Ensure 100% on exit
    ctx.progress.store(ctx.end - ctx.start + 1, .monotonic);
}
