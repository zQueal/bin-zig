const std = @import("std");
const cli = @import("cli.zig");
const timeout = @import("timeout.zig");
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

// ---------------------------------------------------------------------------
// Attempts
//
// Each attempt runs on its own thread so the caller can walk away from one that
// stalls: on platforms where the blocked read cannot be woken (Windows), waiting
// for it would hang `bin` forever, while abandoning it and retrying on a fresh
// connection keeps the command moving (see timeout.zig). The struct lives in the
// caller's arena and is never reused, because an abandoned attempt keeps writing
// into it.
// ---------------------------------------------------------------------------

const MemoryAttempt = struct {
    value: []const u8 = &.{},
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn entry(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header, watch: *timeout.Watch, self: *MemoryAttempt) void {
        self.value = downloadToMemoryOnce(allocator, client, url, extra_headers, watch) catch |err| {
            self.err = err;
            self.done.store(true, .release);
            return;
        };
        self.done.store(true, .release);
    }
};

const FileAttempt = struct {
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn entry(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, dest_path: []const u8, options: DownloadOptions, watch: *timeout.Watch, self: *FileAttempt) void {
        downloadOnce(allocator, client, url, dest_path, options, watch) catch |err| {
            self.err = err;
            self.done.store(true, .release);
            return;
        };
        self.done.store(true, .release);
    }
};

/// Downloads `url` into `dest_path`, retrying transfers that stop mid-flight
/// (see timeout.zig: the reference implementation has no transfer deadline at
/// all, so a peer that stops sending data hangs it forever).
pub fn download(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, dest_path: []const u8, options: DownloadOptions) !void {
    var label_buf: [512]u8 = undefined;
    const label = timeout.label(&label_buf, "downloading", url);
    var retrier = timeout.Retrier{ .label = label };
    while (true) {
        const attempt = try allocator.create(FileAttempt);
        attempt.* = .{};
        const watch = try allocator.create(timeout.Watch);
        watch.* = .{};
        watch.begin(label);

        // The attempt may outlive this frame, so it allocates from a thread-safe
        // allocator and its buffers are never freed (process-lifetime memory,
        // like the arena the rest of the program uses).
        const thread = try std.Thread.spawn(.{}, FileAttempt.entry, .{
            std.heap.smp_allocator, client, url, dest_path, options, watch, attempt,
        });
        if (!timeout.waitForAttempt(watch, &attempt.done)) {
            watch.abandon();
            thread.detach();
            if (retrier.shouldRetry(error.Stalled)) continue;
            return error.Stalled;
        }
        thread.join();
        watch.end();

        if (attempt.err) |err| {
            if (retrier.shouldRetry(err)) continue;
            return err;
        }
        return;
    }
}

fn downloadOnce(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, dest_path: []const u8, options: DownloadOptions, watch: *timeout.Watch) !void {
    const info = fetchDownloadInfo(allocator, client, url, watch) catch |err| {
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
        try downloadStreaming(allocator, client, info.final_url, file, watch);
    }
}

/// Downloads a URL fully into memory (used by the asset pipeline, mirroring
/// the reference implementation which buffers downloads in memory). The
/// transfer is retried when it stops mid-flight, and one that goes silent for
/// longer than `--timeout` is given up on instead of blocking forever.
pub fn downloadToMemory(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header) ![]const u8 {
    var label_buf: [512]u8 = undefined;
    const label = timeout.label(&label_buf, "downloading", url);
    var retrier = timeout.Retrier{ .label = label };
    while (true) {
        const attempt = try allocator.create(MemoryAttempt);
        attempt.* = .{};
        const watch = try allocator.create(timeout.Watch);
        watch.* = .{};
        watch.begin(label);

        const thread = try std.Thread.spawn(.{}, MemoryAttempt.entry, .{
            std.heap.smp_allocator, client, url, extra_headers, watch, attempt,
        });
        if (!timeout.waitForAttempt(watch, &attempt.done)) {
            watch.abandon();
            thread.detach();
            if (retrier.shouldRetry(error.Stalled)) continue;
            return error.Stalled;
        }
        thread.join();
        watch.end();

        if (attempt.err) |err| {
            if (retrier.shouldRetry(err)) continue;
            return err;
        }
        return attempt.value;
    }
}

fn downloadToMemoryOnce(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header, watch: *timeout.Watch) ![]const u8 {
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
    watch.trackRequest(&req);
    try req.sendBodiless();

    var head_buf: [2048]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);
    watch.trackRequest(&req); // a redirect swapped in a new connection
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
            watch.touch();
            try list.appendSlice(allocator, buf[0..n]);
            bar.update(list.items.len);
        }
    } else {
        while (true) {
            const n = try reader.readSliceShort(&buf);
            if (n == 0) break;
            watch.touch();
            try list.appendSlice(allocator, buf[0..n]);
            bar.update(list.items.len);
        }
        // An interrupted socket can read as a clean EOF, which here would
        // otherwise look like a successful (truncated) download.
        if (watch.stalled()) return error.Stalled;
    }
    bar.finish(list.items.len);
    return list.toOwnedSlice(allocator);
}

const max_memory_download = 4 * 1024 * 1024 * 1024; // 4GB

fn fetchDownloadInfo(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, watch: *timeout.Watch) !DownloadInfo {
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
    watch.trackRequest(&req);
    try req.sendBodiless();

    var head_buf: [4096]u8 = undefined;
    const resp = req.receiveHead(&head_buf) catch |err| {
        std.log.err("Failed to receive HTTP response headers: {}", .{err});
        return err;
    };
    watch.trackRequest(&req);

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

fn downloadStreaming(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, file: std.fs.File, watch: *timeout.Watch) !void {
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
    watch.trackRequest(&req);
    try req.sendBodiless();

    var head_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);
    watch.trackRequest(&req); // a redirect swapped in a new connection
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
            watch.touch();
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
            watch.touch();
            try writer.interface.writeAll(buf[0..n]);
            downloaded += n;

            try stdout.interface.print("\rDownloading: {d} bytes", .{downloaded});
            try stdout.interface.flush();
        }
        if (watch.stalled()) return error.Stalled;
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
    // Each chunk gets its own watchdog: a shared one would be kept alive by the
    // chunks that are still moving while this one is stuck. Nobody abandons a
    // chunk, so a stuck one relies on the watchdog's last-resort exit.
    var label_buf: [64]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buf, "downloading chunk {d}", .{ctx.id}) catch "downloading chunk";
    var watch: timeout.Watch = .{};
    watch.begin(label);
    defer watch.end();

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
    watch.trackRequest(&req);
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
    watch.trackRequest(&req); // a redirect swapped in a new connection
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
            // Premature EOF (or an interrupted stalled socket): the chunk is
            // incomplete; do NOT report success.
            ctx.failed.store(true, .monotonic);
            break;
        }
        watch.touch();
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// The watchdog must flag a transfer that stops receiving data. This is the
// portable half of the guarantee: detection always works, so `bin` reports the
// stall instead of silently blocking.
test "the watchdog flags a transfer that goes silent" {
    timeout.stall_seconds = 1;
    defer timeout.stall_seconds = timeout.default_stall_seconds;

    var watch: timeout.Watch = .{};
    watch.begin("test transfer");
    defer watch.end();

    var waited_ms: i64 = 0;
    while (!watch.stalled() and waited_ms < 5_000) : (waited_ms += 25) {
        std.Thread.sleep(25 * std.time.ns_per_ms);
    }
    try std.testing.expect(watch.stalled());
}

// Retries are bounded, and only mid-flight transfer failures are retried — not
// decisions the server made about the request.
test "retries are bounded and limited to transfer failures" {
    timeout.max_retries = 1;
    timeout.stall_seconds = 0; // keep the watchdog out of this test
    defer {
        timeout.max_retries = timeout.default_retries;
        timeout.stall_seconds = timeout.default_stall_seconds;
    }

    var retrier = timeout.Retrier{ .label = "test transfer" };
    try std.testing.expect(retrier.shouldRetry(error.Stalled)); // backs off ~500ms
    try std.testing.expect(!retrier.shouldRetry(error.Stalled));

    var other = timeout.Retrier{ .label = "test transfer" };
    try std.testing.expect(!other.shouldRetry(error.NoFile));
}

// A connection-level failure has to be retried: the std reports a keep-alive
// connection the peer closed as `HttpConnectionClosing` (std/http.zig:379), and
// that name not being retryable is what aborted a whole `bin update` run. The
// classification is deliberately a denylist, so the next name the std uses for
// the same situation cannot repeat it.
test "connection-level failures are retried, decisions are not" {
    // Transient: the peer, the network, or the std's own plumbing got in the way.
    try std.testing.expect(timeout.retryable(error.HttpConnectionClosing));
    try std.testing.expect(timeout.retryable(error.HttpRequestTruncated));
    try std.testing.expect(timeout.retryable(error.ReadFailed));
    try std.testing.expect(timeout.retryable(error.ConnectionResetByPeer));
    try std.testing.expect(timeout.retryable(error.ConnectionClosed));
    try std.testing.expect(timeout.retryable(error.EndOfStream));
    try std.testing.expect(timeout.retryable(error.BrokenPipe));
    try std.testing.expect(timeout.retryable(error.WouldBlock));
    try std.testing.expect(timeout.retryable(error.ConnectionTimedOut));
    try std.testing.expect(timeout.retryable(error.NetworkSubsystemFailed));
    try std.testing.expect(timeout.retryable(error.Stalled));
    try std.testing.expect(timeout.retryable(error.Unexpected)); // wrapped syscall errors

    // Permanent: the server answered, or the local environment said no.
    try std.testing.expect(!timeout.retryable(error.RequestFailed));
    try std.testing.expect(!timeout.retryable(error.NoReleases));
    try std.testing.expect(!timeout.retryable(error.NoFile));
    try std.testing.expect(!timeout.retryable(error.InvalidURL));
    try std.testing.expect(!timeout.retryable(error.NotManaged));
    try std.testing.expect(!timeout.retryable(error.CommandAborted));
    try std.testing.expect(!timeout.retryable(error.OutOfMemory));
    try std.testing.expect(!timeout.retryable(error.FileNotFound));
    try std.testing.expect(!timeout.retryable(error.AccessDenied));
}

// A peer that completes the TCP handshake and then sends nothing at all is the
// exact shape of the hang the watchdog exists for: without a deadline the
// blocking read never returns and `bin` prints nothing forever. This runs on
// every platform: the transfer is reported as error.Stalled and retried, and on
// Windows (where the blocked read cannot be woken) that works because the
// attempt is abandoned rather than waited on.
test "a peer that goes silent is aborted instead of hanging" {
    const addr = try std.net.Address.parseIp4("127.0.0.1", 0);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    const port = server.listen_address.getPort();

    const Silent = struct {
        fn run(s: *std.net.Server) void {
            const conn = s.accept() catch return;
            defer conn.stream.close();
            std.Thread.sleep(30 * std.time.ns_per_s); // never send a byte
        }
    };
    const thread = try std.Thread.spawn(.{}, Silent.run, .{&server});
    thread.detach();

    timeout.stall_seconds = 1; // 1s of silence is a stall here
    timeout.max_retries = 0;
    defer {
        timeout.stall_seconds = timeout.default_stall_seconds;
        timeout.max_retries = timeout.default_retries;
    }

    // An abandoned attempt can still be inside this client, so it gets a
    // thread-safe allocator and is never torn down (the process exits).
    var client = std.http.Client{ .allocator = std.heap.smp_allocator };

    var url_buf: [64]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/asset", .{port});

    const started = std.time.milliTimestamp();
    const result = downloadToMemory(std.heap.page_allocator, &client, url, &.{});
    const elapsed = std.time.milliTimestamp() - started;

    try std.testing.expectError(error.Stalled, result);
    try std.testing.expect(elapsed < 10_000);
}
