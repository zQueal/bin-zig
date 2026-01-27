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

const GitLabRelease = struct {
    tag_name: []const u8,
    assets: struct {
        links: []struct {
            name: []const u8,
            url: []const u8,
        },
    },
};

pub fn fetchRelease(allocator: std.mem.Allocator, client: *std.http.Client, user: []const u8, repo: []const u8, tag: []const u8, token: []const u8) !Release {
    const project_id = try std.fmt.allocPrint(allocator, "{s}%2F{s}", .{ user, repo });
    defer allocator.free(project_id);

    const tag_val = if (tag.len == 0) "permalink/latest" else tag;
    const api_url = try std.fmt.allocPrint(allocator, "https://gitlab.com/api/v4/projects/{s}/releases/{s}", .{ project_id, tag_val });
    defer allocator.free(api_url);

    const uri = try std.Uri.parse(api_url);

    var extra_headers_list: std.ArrayList(std.http.Header) = .empty;
    defer extra_headers_list.deinit(allocator);

    if (token.len > 0) {
        try extra_headers_list.append(allocator, .{ .name = "PRIVATE-TOKEN", .value = token });
    }

    var req = try client.request(.GET, uri, .{
        .extra_headers = extra_headers_list.items,
        .headers = .{
            .user_agent = .{ .override = "bin-zig-cli" },
        },
    });
    defer req.deinit();

    var head_buf: [2048]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);
    if (resp.head.status != .ok) return error.GitLabApiError;

    var transfer_buffer: [8192]u8 = undefined;
    var reader = resp.reader(&transfer_buffer);
    const body = try reader.allocRemaining(allocator, .limited(10 * 1024 * 1024));
    defer allocator.free(body);

    const parsed = try std.json.parseFromSlice(GitLabRelease, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var assets = try allocator.alloc(Asset, parsed.value.assets.links.len);
    for (parsed.value.assets.links, 0..) |link, i| {
        assets[i] = .{
            .name = try allocator.dupe(u8, link.name),
            .browser_download_url = try allocator.dupe(u8, link.url),
        };
    }

    return .{
        .tag_name = try allocator.dupe(u8, parsed.value.tag_name),
        .assets = assets,
    };
}

pub fn selectBestAsset(allocator: std.mem.Allocator, release: Release) !?Asset {
    const os_keywords = utils.getOsKeywords();
    const arch_keywords = utils.getArchKeywords();
    const extensions = utils.getExtensions();

    var best_asset: ?Asset = null;
    var highest_score: i32 = -1;

    for (release.assets) |*asset| {
        var score: i32 = 0;
        const name = asset.name;

        var found_os = false;
        for (os_keywords) |kw| {
            if (std.mem.indexOf(u8, name, kw) != null) {
                found_os = true;
                score += 10;
                break;
            }
        }
        if (!found_os) continue;

        var found_arch = false;
        for (arch_keywords) |kw| {
            if (std.mem.indexOf(u8, name, kw) != null) {
                found_arch = true;
                score += 10;
                break;
            }
        }
        if (!found_arch) continue;

        for (extensions, 0..) |ext, i| {
            if (ext.len > 0 and std.mem.endsWith(u8, name, ext)) {
                score += @intCast(extensions.len - i);
                break;
            } else if (ext.len == 0) {
                if (std.mem.lastIndexOfScalar(u8, name, '.') == null) {
                    score += 5;
                }
            }
        }

        asset.score = score;
        if (score > highest_score) {
            highest_score = score;
            best_asset = asset.*;
        }
    }

    // Sort assets by score descending
    std.mem.sort(Asset, release.assets, {}, struct {
        fn lessThan(_: void, a: Asset, b: Asset) bool {
            return a.score > b.score;
        }
    }.lessThan);

    if (best_asset) |a| {
        return .{
            .name = try allocator.dupe(u8, a.name),
            .browser_download_url = try allocator.dupe(u8, a.browser_download_url),
            .score = a.score,
        };
    }
    return null;
}
