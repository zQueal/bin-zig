const std = @import("std");
const cli = @import("cli.zig");
const utils = @import("utils.zig");

pub const DownloadOptions = struct {
    threads: u32 = 4,
    min_parallel_size: u64 = 5 * 1024 * 1024, // 5MB
};

const Context = struct {
    client: *std.http.Client,
    url: []const u8,
    file: std.fs.File,
    start: u64,
    end: u64,
    id: u32,
    progress: *std.atomic.Value(u64),
    failed: *std.atomic.Value(bool),
};

const DownloadInfo = struct {
    final_url: []const u8,
    size: u64,
    supports_ranges: bool,
};

pub fn download(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, dest_path: []const u8, options: DownloadOptions) !void {
    const info = fetchDownloadInfo(allocator, client, url) catch |err| {
        std.log.err("Failed to fetch download info for '{s}': {}", .{ url, err });
        return err;
    };
    defer allocator.free(info.final_url);

    const file = std.fs.createFileAbsolute(dest_path, .{ .read = true }) catch |err| {
        std.log.err("Failed to create file at '{s}': {}", .{ dest_path, err });
        return err;
    };
    defer file.close();

    if (info.supports_ranges and info.size >= options.min_parallel_size and options.threads > 1) {
        try downloadParallel(allocator, client, info, file, options);
    } else {
        try downloadStreaming(allocator, client, info.final_url, file);
    }
}

/// Downloads a URL fully into memory (used by the asset pipeline, mirroring
/// the reference implementation which buffers downloads in memory).
pub fn downloadToMemory(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header) ![]const u8 {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
        .extra_headers = extra_headers,
        .headers = .{
            .user_agent = .{ .override = "bin-cli" },
            .connection = .{ .override = "close" },
        },
    });
    defer req.deinit();
    try req.sendBodiless();

    var head_buf: [2048]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);
    if (resp.head.status != .ok) return error.DownloadFailed;

    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [8192]u8 = undefined;
    var reader = resp.readerDecompressing(&transfer_buffer, &decompress, &decompress_buf);

    const total_size = resp.head.content_length orelse 0;
    var bar = cli.ProgressBar.init(total_size);

    var list = std.ArrayList(u8).empty;
    errdefer list.deinit(allocator);

    var buf: [16384]u8 = undefined;
    if (total_size > 0) {
        // Known length: never read past the end (0.15.x contentLengthStream
        // panics on post-EOF reads).
        while (list.items.len < total_size) {
            const want = @min(buf.len, total_size - list.items.len);
            const n = try reader.readSliceShort(buf[0..want]);
            if (n == 0) return error.DownloadFailed; // premature EOF
            try list.appendSlice(allocator, buf[0..n]);
            bar.update(list.items.len);
        }
    } else {
        while (true) {
            const n = try reader.readSliceShort(&buf);
            if (n == 0) break;
            try list.appendSlice(allocator, buf[0..n]);
            bar.update(list.items.len);
        }
    }
    bar.finish(list.items.len);
    return list.toOwnedSlice(allocator);
}

const max_memory_download = 4 * 1024 * 1024 * 1024; // 4GB

fn fetchDownloadInfo(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8) !DownloadInfo {
    const uri = std.Uri.parse(url) catch |err| {
        std.log.err("Failed to parse URL '{s}': {}", .{ url, err });
        return err;
    };
    var req = client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
        .headers = .{
            .user_agent = .{ .override = "bin-zig-cli" },
            .connection = .{ .override = "close" },
        },
    }) catch |err| {
        std.log.err("Failed to create HTTP request for '{s}': {}", .{ url, err });
        return err;
    };
    defer req.deinit();
    try req.sendBodiless();

    var head_buf: [4096]u8 = undefined;
    const resp = req.receiveHead(&head_buf) catch |err| {
        std.log.err("Failed to receive HTTP response headers: {}", .{err});
        return err;
    };

    if (resp.head.status != .ok) {
        std.log.err("HTTP request failed with status {}", .{@intFromEnum(resp.head.status)});
        return error.DownloadFailed;
    }

    const final_url = try std.fmt.allocPrint(allocator, "{f}", .{req.uri});

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

fn downloadStreaming(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, file: std.fs.File) !void {
    _ = allocator;
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
        .headers = .{
            .user_agent = .{ .override = "bin-zig-cli" },
            .connection = .{ .override = "close" },
        },
    });
    defer req.deinit();
    try req.sendBodiless();

    var head_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);
    if (resp.head.status != .ok) return error.DownloadFailed;

    const total_size = resp.head.content_length orelse 0;
    var downloaded: u64 = 0;

    var transfer_buffer: [8192]u8 = undefined;
    var reader = resp.reader(&transfer_buffer);
    var write_buf: [8192]u8 = undefined;
    var writer = file.writerStreaming(&write_buf);

    var buf: [8192]u8 = undefined;
    var stdout_buf: [128]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var stdout = stdout_file.writer(&stdout_buf);

    if (total_size > 0) {
        // Content length is known: read exactly that many bytes. Reading past the
        // end trips a 0.15.x std bug in the http contentLengthStream state machine.
        while (downloaded < total_size) {
            const want = @min(buf.len, total_size - downloaded);
            const n = try reader.readSliceShort(buf[0..want]);
            if (n == 0) return error.DownloadFailed; // premature EOF
            try writer.interface.writeAll(buf[0..n]);
            downloaded += n;

            const percent = downloaded * 100 / total_size;
            try stdout.interface.print("\rDownloading: {d}% ({d}/{d} bytes)", .{ percent, downloaded, total_size });
            try stdout.interface.flush();
        }
    } else {
        // Unknown length (no Content-Length header): the body reader is the raw
        // connection reader, which reports EOF as a short read.
        while (true) {
            const n = try reader.readSliceShort(&buf);
            if (n == 0) break;
            try writer.interface.writeAll(buf[0..n]);
            downloaded += n;

            try stdout.interface.print("\rDownloading: {d} bytes", .{downloaded});
            try stdout.interface.flush();
        }
    }
    try writer.interface.flush();
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();
}

fn downloadParallel(allocator: std.mem.Allocator, client: *std.http.Client, info: DownloadInfo, file: std.fs.File, options: DownloadOptions) !void {
    std.log.info("Starting parallel download ({} threads, {d} bytes)...", .{ options.threads, info.size });

    const chunk_size = (info.size + options.threads - 1) / options.threads;
    var threads = try allocator.alloc(std.Thread, options.threads);
    defer allocator.free(threads);

    var contexts = try allocator.alloc(Context, options.threads);
    defer allocator.free(contexts);

    var progress_values = try allocator.alloc(std.atomic.Value(u64), options.threads);
    defer allocator.free(progress_values);

    var targets = try allocator.alloc(u64, options.threads);
    defer allocator.free(targets);

    var failed_values = try allocator.alloc(std.atomic.Value(bool), options.threads);
    defer allocator.free(failed_values);

    for (0..options.threads) |i| {
        const start = i * chunk_size;
        const end = @min((i + 1) * chunk_size - 1, info.size - 1);
        const target = end - start + 1;

        progress_values[i] = std.atomic.Value(u64).init(0);
        failed_values[i] = std.atomic.Value(bool).init(false);
        targets[i] = target;

        contexts[i] = .{
            .client = client,
            .url = info.final_url,
            .file = file,
            .start = start,
            .end = end,
            .id = @intCast(i),
            .progress = &progress_values[i],
            .failed = &failed_values[i],
        };

        threads[i] = try std.Thread.spawn(.{}, downloadChunk, .{&contexts[i]});
    }

    // Reporter loop
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file = std.fs.File.stdout();
    var stdout = stdout_file.writer(&stdout_buf);

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

            const bar_slice: []const u8 = &bar;
            try stdout.interface.print("Thread {d:2}: [{s}] {d:3}% ({d}/{d})\n", .{ i, bar_slice, percent, d, target });
            if (d < target) all_done = false;
        }

        if (all_done) break;
        try stdout.interface.flush();
        std.Thread.sleep(100 * std.time.ns_per_ms);
        try stdout.interface.print("\x1b[{d}A", .{options.threads});
    }

    for (threads) |t| {
        t.join();
    }

    // Fail the download if any chunk failed: a partially written file must
    // never be treated as a successful download.
    for (failed_values) |fv| {
        if (fv.load(.monotonic)) {
            std.log.err("Parallel download failed: one or more chunks did not complete.", .{});
            return error.DownloadFailed;
        }
    }
    // Sanity check the total size.
    const stat = try file.stat();
    if (stat.size != info.size) {
        std.log.err("Parallel download size mismatch: got {d}, expected {d}.", .{ stat.size, info.size });
        return error.DownloadFailed;
    }

    try stdout.interface.writeAll("\nDownload complete.\n");
    try stdout.interface.flush();
}

fn downloadChunk(ctx: *const Context) void {
    const uri = std.Uri.parse(ctx.url) catch return;
    var range_buf: [128]u8 = undefined;
    const range_header = std.fmt.bufPrint(&range_buf, "bytes={d}-{d}", .{ ctx.start, ctx.end }) catch return;

    var req = ctx.client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
        .extra_headers = &[_]std.http.Header{
            .{ .name = "Range", .value = range_header },
        },
        .headers = .{
            .user_agent = .{ .override = "bin-zig-cli" },
            .connection = .{ .override = "close" },
        },
    }) catch |err| {
        std.log.err("Thread {}: request failed: {any}", .{ ctx.id, err });
        ctx.failed.store(true, .monotonic);
        return;
    };
    defer req.deinit();
    req.sendBodiless() catch |err| {
        std.log.err("Thread {}: sendBodiless failed: {any}", .{ ctx.id, err });
        ctx.failed.store(true, .monotonic);
        return;
    };

    var head_buf: [1024]u8 = undefined;
    var resp = req.receiveHead(&head_buf) catch |err| {
        std.log.err("Thread {}: receiveHead failed: {any}", .{ ctx.id, err });
        ctx.failed.store(true, .monotonic);
        return;
    };
    if (resp.head.status != .partial_content and resp.head.status != .ok) {
        std.log.err("Thread {}: unexpected status {d}", .{ ctx.id, @intFromEnum(resp.head.status) });
        ctx.failed.store(true, .monotonic);
        return;
    }

    var transfer_buffer: [8192]u8 = undefined;
    var reader = resp.reader(&transfer_buffer);

    var buf: [16384]u8 = undefined;
    var offset = ctx.start;
    const limit = ctx.end + 1;

    while (offset < limit) {
        // Never read past the chunk end: the std http contentLengthStream
        // panics on reads after EOF in 0.15.x.
        const want = @min(buf.len, limit - offset);
        const n = reader.readSliceShort(buf[0..want]) catch |err| {
            std.log.err("Thread {}: read error: {any}", .{ ctx.id, err });
            ctx.failed.store(true, .monotonic);
            break;
        };
        if (n == 0) {
            // Premature EOF: the chunk is incomplete; do NOT report success.
            ctx.failed.store(true, .monotonic);
            break;
        }
        ctx.file.pwriteAll(buf[0..n], offset) catch |err| {
            std.log.err("Thread {}: write error at offset {}: {any}", .{ ctx.id, offset, err });
            ctx.failed.store(true, .monotonic);
            break;
        };
        offset += n;
        ctx.progress.store(offset - ctx.start, .monotonic);
    }
    // Ensure 100% on exit (only when the chunk fully succeeded).
    if (!ctx.failed.load(.monotonic)) {
        ctx.progress.store(ctx.end - ctx.start + 1, .monotonic);
    }
}
