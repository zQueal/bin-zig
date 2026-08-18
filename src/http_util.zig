//! Small HTTP helpers shared by the providers (GET + JSON with the 0.15.2
//! client flow: sendBodiless -> receiveHead -> decompressing reader).
//! Everything is arena-allocated; callers never free (program-exit cleanup).

const std = @import("std");

pub const max_json_body = 64 * 1024 * 1024;

pub fn getBody(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, extra_headers: []const std.http.Header, limit: usize) ![]const u8 {
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
    try req.sendBodiless();

    var head_buf: [2048]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);
    if (resp.head.status != .ok) return error.RequestFailed;

    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var transfer_buffer: [8192]u8 = undefined;
    var reader = resp.readerDecompressing(&transfer_buffer, &decompress, &decompress_buf);
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
