const std = @import("std");
const http_util = @import("http_util.zig");

const RateLimitInfo = struct {
    provider: []const u8,
    endpoint: []const u8,
    limit: ?u64 = null,
    remaining: ?u64 = null,
    reset: ?i64 = null, // Unix timestamp
    error_message: ?[]const u8 = null,
};

/// Extra zig command (not in the reference): shows API rate limit info.
pub fn info(allocator: std.mem.Allocator) !void {
    var client = std.http.Client{ .allocator = allocator };
    try client.ca_bundle.rescan(allocator);
    defer client.deinit();

    const github_token = std.process.getEnvVarOwned(allocator, "GITHUB_TOKEN") catch "";
    const gitlab_token = std.process.getEnvVarOwned(allocator, "GITLAB_TOKEN") catch "";
    const codeberg_token = std.process.getEnvVarOwned(allocator, "CODEBERG_TOKEN") catch "";

    var results = std.ArrayList(RateLimitInfo).empty;
    defer results.deinit(allocator);

    const github_info = getGithubRateLimit(allocator, &client, github_token) catch |err| RateLimitInfo{
        .provider = "GitHub",
        .endpoint = "https://api.github.com/rate_limit",
        .error_message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
    };
    try results.append(allocator, github_info);

    const gitlab_info = getGitLabRateLimit(allocator, &client, gitlab_token) catch |err| RateLimitInfo{
        .provider = "GitLab",
        .endpoint = "https://gitlab.com/api/v4/user",
        .error_message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
    };
    try results.append(allocator, gitlab_info);

    const codeberg_info = getCodebergRateLimit(allocator, &client, codeberg_token) catch |err| RateLimitInfo{
        .provider = "Codeberg",
        .endpoint = "https://codeberg.org/api/v1/version",
        .error_message = try std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}),
    };
    try results.append(allocator, codeberg_info);

    // Display results
    std.debug.print("\n=== API Rate Limit Information ===\n\n", .{});

    for (results.items) |result| {
        std.debug.print("{s}:\n", .{result.provider});
        std.debug.print("  Endpoint: {s}\n", .{result.endpoint});

        if (result.error_message) |msg| {
            std.debug.print("  Status: Error\n", .{});
            std.debug.print("  Message: {s}\n\n", .{msg});
        } else {
            if (result.limit) |limit| {
                std.debug.print("  Limit: {d}\n", .{limit});
            }
            if (result.remaining) |remaining| {
                std.debug.print("  Remaining: {d}\n", .{remaining});
            }
            if (result.reset) |reset| {
                std.debug.print("  Reset time: {d} (Unix timestamp)\n", .{reset});
            }
            std.debug.print("\n", .{});
        }
    }
}

fn getGithubRateLimit(allocator: std.mem.Allocator, client: *std.http.Client, token: []const u8) !RateLimitInfo {
    const url = "https://api.github.com/rate_limit";

    var headers = std.ArrayList(std.http.Header).empty;
    defer headers.deinit(allocator);
    try headers.append(allocator, .{ .name = "Accept", .value = "application/vnd.github.v3+json" });
    if (token.len > 0) {
        const auth = try std.fmt.allocPrint(allocator, "token {s}", .{token});
        try headers.append(allocator, .{ .name = "Authorization", .value = auth });
    }

    const parsed = try http_util.getJson(allocator, client, url, headers.items);

    var result = RateLimitInfo{ .provider = "GitHub", .endpoint = url };
    if (parsed.object.get("resources")) |resources| {
        if (resources == .object) {
            if (resources.object.get("core")) |core| {
                if (core == .object) {
                    if (core.object.get("limit")) |l| {
                        if (l == .integer) result.limit = @intCast(l.integer);
                    }
                    if (core.object.get("remaining")) |r| {
                        if (r == .integer) result.remaining = @intCast(r.integer);
                    }
                    if (core.object.get("reset")) |reset| {
                        if (reset == .integer) result.reset = @intCast(reset.integer);
                    }
                }
            }
        }
    }
    return result;
}

fn getGitLabRateLimit(allocator: std.mem.Allocator, client: *std.http.Client, token: []const u8) !RateLimitInfo {
    _ = allocator;
    _ = client;
    _ = token;
    return RateLimitInfo{
        .provider = "GitLab",
        .endpoint = "https://gitlab.com/api/v4/user",
        .error_message = "Rate limit info available in response headers but not accessible via the API",
    };
}

fn getCodebergRateLimit(allocator: std.mem.Allocator, client: *std.http.Client, token: []const u8) !RateLimitInfo {
    _ = allocator;
    _ = client;
    _ = token;
    return RateLimitInfo{
        .provider = "Codeberg",
        .endpoint = "https://codeberg.org/api/v1/version",
        .error_message = "No standard rate limit endpoint available",
    };
}
