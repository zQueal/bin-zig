const std = @import("std");
const config = @import("config.zig");

const RateLimitInfo = struct {
    provider: []const u8,
    endpoint: []const u8,
    limit: ?u64 = null,
    remaining: ?u64 = null,
    reset: ?i64 = null, // Unix timestamp
    error_message: ?[]const u8 = null,
};

pub fn info(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.Environ, io: std.Io) !void {
    _ = env;

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var results = std.ArrayList(RateLimitInfo).empty;
    defer results.deinit(allocator);

    // GitHub rate limit
    const github_info = getGithubRateLimit(allocator, &client, conf.tokens.github) catch |err| RateLimitInfo{
        .provider = "GitHub",
        .endpoint = "https://api.github.com/rate_limit",
        .error_message = errorNameAlloc(allocator, err),
    };
    try results.append(allocator, github_info);

    // GitLab - doesn't have a rate_limit endpoint, but we can make a simple request to get headers
    const gitlab_info = getGitLabRateLimit(allocator, &client, conf.tokens.gitlab) catch |err| RateLimitInfo{
        .provider = "GitLab",
        .endpoint = "https://gitlab.com/api/v4/user",
        .error_message = errorNameAlloc(allocator, err),
    };
    try results.append(allocator, gitlab_info);

    // Codeberg (Gitea) - similar to GitLab
    const codeberg_info = getCodebergRateLimit(allocator, &client, conf.tokens.codeberg) catch |err| RateLimitInfo{
        .provider = "Codeberg",
        .endpoint = "https://codeberg.org/api/v1/version",
        .error_message = errorNameAlloc(allocator, err),
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
                // Display raw Unix timestamp (API may provide future reset time)
                std.debug.print("  Reset time: {d} (Unix timestamp)\n", .{reset});
            }
            std.debug.print("\n", .{});
        }
    }

    // Note: Error messages will be cleaned up by the arena allocator when config is destroyed
}

// Helper function to allocate error name
fn errorNameAlloc(allocator: std.mem.Allocator, err: anyerror) ?[]const u8 {
    return std.fmt.allocPrint(allocator, "{s}", .{@errorName(err)}) catch null;
}

fn getGithubRateLimit(allocator: std.mem.Allocator, client: *std.http.Client, token: []const u8) !RateLimitInfo {
    const url = "https://api.github.com/rate_limit";
    const uri = try std.Uri.parse(url);

    var extra_headers_list: std.ArrayList(std.http.Header) = .empty;
    defer extra_headers_list.deinit(allocator);

    if (token.len > 0) {
        const auth_value = try std.fmt.allocPrint(allocator, "token {s}", .{token});
        defer allocator.free(auth_value);
        try extra_headers_list.append(allocator, .{ .name = "Authorization", .value = auth_value });
    }
    try extra_headers_list.append(allocator, .{ .name = "Accept", .value = "application/vnd.github.v3+json" });

    var req = try client.request(.GET, uri, .{
        .extra_headers = extra_headers_list.items,
        .headers = .{
            .user_agent = .{ .override = "bin-zig-cli" },
        },
    });
    defer req.deinit();

    var redirect_buffer: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    if (response.head.status != .ok) {
        return error.RequestFailed;
    }

    var transfer_buffer: [8192]u8 = undefined;
    var reader = response.reader(&transfer_buffer);
    const body = try reader.allocRemaining(allocator, .limited(1024 * 1024));
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    var result = RateLimitInfo{
        .provider = "GitHub",
        .endpoint = url,
    };

    if (root.object.get("resources")) |resources| {
        if (resources == .object) {
            // Get core rate limits (most relevant for authenticated requests)
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
    // GitLab doesn't have a rate_limit endpoint, and rate limit info is returned in response headers
    // Due to Zig stdlib API limitations, we cannot easily access response headers at this time
    // So we'll report that rate limit info is available but not readable
    _ = allocator;
    _ = client;
    _ = token;

    return RateLimitInfo{
        .provider = "GitLab",
        .endpoint = "https://gitlab.com/api/v4/user",
        .limit = null,
        .remaining = null,
        .reset = null,
        .error_message = "Rate limit info available in response headers but not accessible due to API limitations",
    };
}

fn getCodebergRateLimit(allocator: std.mem.Allocator, client: *std.http.Client, token: []const u8) !RateLimitInfo {
    // Codeberg (Gitea) doesn't have a rate_limit endpoint
    // Due to Zig stdlib API limitations, we cannot easily access response headers at this time
    // Codeberg typically doesn't enforce strict rate limits
    _ = allocator;
    _ = client;
    _ = token;

    return RateLimitInfo{
        .provider = "Codeberg",
        .endpoint = "https://codeberg.org/api/v1/version",
        .limit = null,
        .remaining = null,
        .reset = null,
        .error_message = "No standard rate limit endpoint available",
    };
}
