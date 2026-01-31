const std = @import("std");
const utils = @import("utils.zig");

pub const Asset = struct {
    name: []const u8,
    browser_download_url: []const u8,
    score: i32 = 0,
};

pub const Release = struct {
    tag_name: []const u8,
    assets: []Asset,
};

pub fn fetchRelease(allocator: std.mem.Allocator, client: *std.http.Client, user: []const u8, repo: []const u8, tag: []const u8, token: []const u8) !Release {
    const url = if (tag.len == 0)
        try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/latest", .{ user, repo })
    else
        try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/{s}/releases/tags/{s}", .{ user, repo, tag });
    defer allocator.free(url);

    const uri = try std.Uri.parse(url);

    var extra_headers_list: std.ArrayList(std.http.Header) = .empty;
    defer extra_headers_list.deinit(allocator);

    // Track Authorization header value for proper cleanup
    var auth_header_value: ?[]const u8 = null;
    if (token.len > 0) {
        auth_header_value = try std.fmt.allocPrint(allocator, "token {s}", .{token});
        try extra_headers_list.append(allocator, .{ .name = "Authorization", .value = auth_header_value.? });
    }
    defer if (auth_header_value) |v| allocator.free(v);
    try extra_headers_list.append(allocator, .{ .name = "Accept", .value = "application/vnd.github.v3+json" });

    var req = try client.request(.GET, uri, .{
        .extra_headers = extra_headers_list.items,
        .redirect_behavior = @enumFromInt(5),
        .headers = .{
            .user_agent = .{ .override = "bin-zig-cli" },
            .connection = .{ .override = "close" },
        },
    });
    defer req.deinit();

    var redirect_buffer: [1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buffer);

    if (response.head.status != .ok) {
        std.log.err("GitHub API request failed with status {d}", .{@intFromEnum(response.head.status)});
        return error.RequestFailed;
    }

    // Read body
    const body_size = 10 * 1024 * 1024; // 10MB limit for response
    var transfer_buffer: [8192]u8 = undefined;
    var reader = response.reader(&transfer_buffer);
    const body = try reader.allocRemaining(allocator, .limited(body_size));
    // defer allocator.free(body); // We rely on caller to manage memory of returned struct, simpler to arena everything.
    // Actually we should probably use an arena for the whole operation.

    // Parse JSON
    // We only need assets and tag_name
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    // defer parsed.deinit(); // Caller needs the strings

    const root = parsed.value;
    var release = Release{ .tag_name = "", .assets = &[_]Asset{} };

    if (root.object.get("tag_name")) |t| {
        if (t == .string) release.tag_name = try allocator.dupe(u8, t.string);
    }

    if (root.object.get("assets")) |a| {
        if (a == .array) {
            var assets = std.ArrayList(Asset).empty;
            for (a.array.items) |item| {
                if (item == .object) {
                    var name: []const u8 = "";
                    var durl: []const u8 = "";
                    if (item.object.get("name")) |n| if (n == .string) {
                        name = n.string;
                    };
                    if (item.object.get("browser_download_url")) |u| if (u == .string) {
                        durl = u.string;
                    };

                    if (name.len > 0 and durl.len > 0) {
                        try assets.append(allocator, Asset{
                            .name = try allocator.dupe(u8, name),
                            .browser_download_url = try allocator.dupe(u8, durl),
                        });
                    }
                }
            }
            release.assets = try assets.toOwnedSlice(allocator);
        }
    }

    return release;
}

pub fn selectBestAsset(allocator: std.mem.Allocator, release: Release) !?Asset {
    const os_keywords = utils.getOsKeywords();
    const arch_keywords = utils.getArchKeywords();
    const extensions = utils.getExtensions();

    var best_asset: ?Asset = null;
    var best_score: i32 = -1;

    for (release.assets) |*asset| {
        var score: i32 = 0;
        const name_lower = try std.ascii.allocLowerString(allocator, asset.name);
        defer allocator.free(name_lower);

        // OS Detection
        var os_match = false;
        for (os_keywords) |kw| {
            if (std.mem.indexOf(u8, name_lower, kw) != null) {
                score += 10;
                os_match = true;
                break;
            }
        }

        // Arch Detection
        var arch_match = false;
        for (arch_keywords) |kw| {
            if (std.mem.indexOf(u8, name_lower, kw) != null) {
                score += 10;
                arch_match = true;
                break;
            }
        }

        // Extension weight
        var ext_match = false;
        for (extensions) |ext| {
            if (ext.len > 0 and std.mem.endsWith(u8, name_lower, ext)) {
                score += 5;
                ext_match = true;
                if (std.mem.eql(u8, ext, ".exe")) score += 2;
                break;
            }
        }

        // Penalties
        if (std.mem.indexOf(u8, name_lower, "sha256") != null) score -= 100;
        if (std.mem.indexOf(u8, name_lower, ".asc") != null) score -= 100;
        if (std.mem.indexOf(u8, name_lower, ".sig") != null) score -= 100;

        asset.score = score;

        if (score > best_score) {
            best_score = score;
            best_asset = asset.*;
        }
    }

    // Sort assets by score descending
    std.mem.sort(Asset, release.assets, {}, struct {
        fn lessThan(_: void, a: Asset, b: Asset) bool {
            return a.score > b.score;
        }
    }.lessThan);

    if (best_score <= 0) return null;
    return best_asset;
}
