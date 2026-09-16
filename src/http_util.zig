//! Small HTTP helpers shared by the providers (GET + JSON with the 0.15.2
//! client flow: sendBodiless -> receiveHead -> decompressing reader).
//! Everything is arena-allocated; callers never free (program-exit cleanup).

const std = @import("std");
const timeout = @import("timeout.zig");

pub const max_json_body = 64 * 1024 * 1024;

/// One `getBody` attempt. It runs on its own thread so that a request which goes
/// silent can be abandoned and retried, on platforms where the blocked read
/// cannot be woken (see timeout.zig). The struct lives in the caller's arena and
/// is never reused: an abandoned attempt keeps writing into it.
const Attempt = struct {
    body: []const u8 = &.{},
    err: ?anyerror = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn entry(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header, limit: usize, watch: *timeout.Watch, self: *Attempt) void {
        self.body = getBodyOnce(allocator, client, url, extra_headers, limit, watch) catch |err| {
            self.err = err;
            self.done.store(true, .release);
            return;
        };
        self.done.store(true, .release);
    }
};

/// GETs a body, retrying requests that stop mid-flight. A request that goes
/// silent for `--timeout` seconds is given up on and retried instead of blocking
/// the version check forever (see timeout.zig).
pub fn getBody(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header, limit: usize) ![]const u8 {
    var label_buf: [512]u8 = undefined;
    const label = timeout.label(&label_buf, "requesting", url);
    var retrier = timeout.Retrier{ .label = label };
    while (true) {
        const attempt = try allocator.create(Attempt);
        attempt.* = .{};
        const watch = try allocator.create(timeout.Watch);
        watch.* = .{};
        watch.begin(label);

        // The attempt may outlive this frame (an abandoned one parks in the
        // kernel until exit), so it must not allocate from `allocator`: it uses
        // the thread-safe allocator instead, and its result is never freed,
        // matching how the rest of the program treats process-lifetime memory.
        const thread = try std.Thread.spawn(.{}, Attempt.entry, .{
            std.heap.smp_allocator, client, url, extra_headers, limit, watch, attempt,
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
        return attempt.body;
    }
}

fn getBodyOnce(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header, limit: usize, watch: *timeout.Watch) ![]const u8 {
    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
        .extra_headers = extra_headers,
        .headers = .{
            .user_agent = .{ .override = "bin-cli" },
            // Keep-alive (default): the client pools the connection, so a
            // burst of requests to the same host (e.g. update checks across
            // many binaries) reuses the TCP+TLS connection instead of doing
            // a fresh handshake every time.
        },
    });
    defer req.deinit();
    watch.trackRequest(&req);
    try req.sendBodiless();

    var head_buf: [2048]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);
    watch.trackRequest(&req); // a redirect swapped in a new connection
    if (resp.head.status != .ok) return error.RequestFailed;

    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [8192]u8 = undefined;
    var reader = resp.readerDecompressing(&transfer_buffer, &decompress, &decompress_buf);
    // `allocRemaining` reads internally, so the watchdog measures the whole
    // body here: API responses are small, so this is equivalent to measuring
    // inactivity for anything that could legitimately take that long.
    return reader.allocRemaining(allocator, .limited(limit));
}

pub fn getJson(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header) !std.json.Value {
    const body = try getBody(allocator, client, url, extra_headers, max_json_body);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    // parsed.value strings alias `body`; both stay alive until program exit
    // (arena-backed). Do not deinit.
    return parsed.value;
}

/// Percent-encodes a URL path segment (tags can contain characters that would
/// otherwise alter the request path/query).
pub fn encodePathSegment(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.Uri.Component.percentEncode(&out.writer, s, struct {
        fn valid(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
        }
    }.valid);
    return allocator.dupe(u8, out.written());
}
