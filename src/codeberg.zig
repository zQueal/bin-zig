//! Codeberg (Gitea/Forgejo) provider mirroring pkg/providers/codeberg.go.
//! Self-hosted instances are supported via the URL hostname.

const std = @import("std");
const assets = @import("assets.zig");
const http_util = @import("http_util.zig");
const providers = @import("providers.zig");

pub const Codeberg = struct {
    owner: []const u8,
    repo: []const u8,
    tag: []const u8,
    token: []const u8,
    api_base: []const u8,

    pub fn init(allocator: std.mem.Allocator, uri: std.Uri, provider_name: []const u8) !Codeberg {
        _ = provider_name;
        var segments = std.ArrayList([]const u8).empty;
        defer segments.deinit(allocator);
        var it = std.mem.splitScalar(u8, providers.Provider.pathString(uri), '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try segments.append(allocator, seg);
        }
        if (segments.items.len < 2) {
            std.log.debug("error parsing Codeberg URL, can't find owner and repo", .{});
            return error.InvalidURL;
        }

        var tag: []const u8 = "";
        var repo = segments.items[1];
        if (std.mem.indexOf(u8, providers.Provider.pathString(uri), "/releases/") != null) {
            for (segments.items, 0..) |seg, i| {
                if (std.mem.eql(u8, seg, "releases")) {
                    var parts = std.ArrayList([]const u8).empty;
                    defer parts.deinit(allocator);
                    for (segments.items[i + 2 ..]) |p| try parts.append(allocator, p);
                    tag = try std.mem.join(allocator, "/", parts.items);
                    break;
                }
            }
        }

        // Zig extension (update-bug fix): support user/repo@tag pinning.
        if (tag.len == 0) {
            if (std.mem.lastIndexOfScalar(u8, repo, '@')) |at_idx| {
                tag = repo[at_idx + 1 ..];
                repo = repo[0..at_idx];
            }
        }

        const hostname = providers.Provider.hostString(uri) orelse return error.InvalidURL;
        const token = std.process.getEnvVarOwned(allocator, "CODEBERG_TOKEN") catch "";
        const api_base = try std.fmt.allocPrint(allocator, "https://{s}/api/v1", .{hostname});

        return .{
            .owner = try allocator.dupe(u8, segments.items[0]),
            .repo = try allocator.dupe(u8, repo),
            .tag = tag,
            .token = token,
            .api_base = api_base,
        };
    }

    pub fn getID() []const u8 {
        return "codeberg";
    }

    fn authHeaders(self: *const Codeberg, allocator: std.mem.Allocator) []const std.http.Header {
        if (self.token.len == 0) return &.{};
        const headers = allocator.alloc(std.http.Header, 1) catch return &.{};
        const auth = std.fmt.allocPrint(allocator, "token {s}", .{self.token}) catch {
            return &.{};
        };
        headers[0] = .{ .name = "Authorization", .value = auth };
        return headers;
    }

    /// Extra headers for asset downloads.
    pub fn downloadHeaders(self: *const Codeberg, allocator: std.mem.Allocator) []const std.http.Header {
        if (self.token.len == 0) {
            return &.{
                .{ .name = "Accept", .value = "application/octet-stream" },
            };
        }
        const headers = allocator.alloc(std.http.Header, 2) catch return &.{};
        headers[0] = .{ .name = "Accept", .value = "application/octet-stream" };
        const auth = std.fmt.allocPrint(allocator, "token {s}", .{self.token}) catch {
            return &.{};
        };
        headers[1] = .{ .name = "Authorization", .value = auth };
        return headers;
    }

    fn repoApi(self: *const Codeberg, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/repos/{s}/{s}", .{ self.api_base, self.owner, self.repo });
    }

    pub fn fetchRelease(self: *const Codeberg, allocator: std.mem.Allocator, client: *std.http.Client, opts: providers.FetchOpts) !providers.Release {
        var tag = self.tag;
        if (opts.version.len > 0) tag = opts.version;

        var release_json: std.json.Value = undefined;
        if (tag.len > 0) {
            std.log.info("Getting {s} release for {s}/{s}", .{ tag, self.owner, self.repo });
            const enc_tag = try http_util.encodePathSegment(allocator, tag);
            const url = try std.fmt.allocPrint(allocator, "{s}/releases/tags/{s}", .{ try self.repoApi(allocator), enc_tag });
            defer allocator.free(url);
            release_json = try http_util.getJson(allocator, client, url, self.authHeaders(allocator));
        } else {
            std.log.info("Getting latest release for {s}/{s}", .{ self.owner, self.repo });
            const url = try std.fmt.allocPrint(allocator, "{s}/releases/latest", .{ try self.repoApi(allocator) });
            defer allocator.free(url);
            release_json = http_util.getJson(allocator, client, url, self.authHeaders(allocator)) catch |err| switch (err) {
                error.RequestFailed => {
                    std.log.err("repository {s}/{s} does not have releases", .{ self.owner, self.repo });
                    return error.NoReleases;
                },
                else => return err,
            };
        }

        var version: []const u8 = "";
        if (release_json.object.get("tag_name")) |t| {
                    if (t == .string) {
                        version = t.string;
                    }
                }

        var candidates = std.ArrayList(assets.Asset).empty;
        defer candidates.deinit(allocator);
        if (release_json.object.get("assets")) |a| {
            if (a == .array) {
                for (a.array.items) |item| {
                    if (item != .object) continue;
                    var name: []const u8 = "";
                    var durl: []const u8 = "";
                    if (item.object.get("name")) |n| {
                    if (n == .string) {
                        name = n.string;
                    }
                }
                    if (item.object.get("browser_download_url")) |u| {
                    if (u == .string) {
                        durl = u.string;
                    }
                }
                    if (name.len > 0 and durl.len > 0) {
                        try candidates.append(allocator, .{ .name = try allocator.dupe(u8, name), .url = try allocator.dupe(u8, durl) });
                    }
                }
            }
        }

        return .{
            .version = try allocator.dupe(u8, version),
            .repo_name = self.repo,
            .assets = try candidates.toOwnedSlice(allocator),
        };
    }

    pub fn getLatestVersion(self: *const Codeberg, allocator: std.mem.Allocator, client: *std.http.Client) !providers.Latest {
        std.log.debug("Getting latest release for {s}/{s}", .{ self.owner, self.repo });
        const url = try std.fmt.allocPrint(allocator, "{s}/releases/latest", .{ try self.repoApi(allocator) });
        defer allocator.free(url);
        const release = try http_util.getJson(allocator, client, url, self.authHeaders(allocator));
        var version: []const u8 = "";
        var html_url: []const u8 = "";
        if (release.object.get("tag_name")) |t| {
                    if (t == .string) {
                        version = t.string;
                    }
                }
        if (release.object.get("html_url")) |h| {
                    if (h == .string) {
                        html_url = h.string;
                    }
                }
        return .{ .version = try allocator.dupe(u8, version), .url = try allocator.dupe(u8, html_url) };
    }
};
