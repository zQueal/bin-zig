const std = @import("std");
const assets = @import("assets.zig");
const http_util = @import("http_util.zig");
const providers = @import("providers.zig");

pub const GitHub = struct {
    owner: []const u8,
    repo: []const u8,
    tag: []const u8,
    token: []const u8,
    filter: []const u8,
    api_base: []const u8,
    /// Raw path segment list used to build URLs (keeps hostname).
    host: []const u8,

    /// Mirrors newGitHub: parses owner/repo/tag from the URL path.
    pub fn init(allocator: std.mem.Allocator, uri: std.Uri, provider_name: []const u8) !GitHub {
        _ = provider_name;
        var segments = std.ArrayList([]const u8).empty;
        defer segments.deinit(allocator);
        var it = std.mem.splitScalar(u8, providers.Provider.pathString(uri), '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try segments.append(allocator, seg);
        }
        if (segments.items.len < 2) {
            std.log.debug("error parsing Github URL, can't find owner and repo", .{});
            return error.InvalidURL;
        }

        var tag: []const u8 = "";
        var repo = segments.items[1];
        // specific releases URL: /owner/repo/releases/tag/v0.1 or /releases/download/v0.1
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

        // Zig extension (update-bug fix, never upstreamed): the URL may carry a
        // pinned version as user/repo@tag. Split the tag off the repo name with
        // lastIndexOfScalar so repo names containing '@' keep working.
        if (tag.len == 0) {
            if (std.mem.lastIndexOfScalar(u8, repo, '@')) |at_idx| {
                tag = repo[at_idx + 1 ..];
                repo = repo[0..at_idx];
            }
        }

        // filter query param (glob over release tags)
        var filter: []const u8 = "";
        if (providers.Provider.queryString(uri)) |q| {
            var qit = std.mem.splitScalar(u8, q, '&');
            while (qit.next()) |pair| {
                if (std.mem.startsWith(u8, pair, "filter=")) {
                    filter = try allocator.dupe(u8, pair["filter=".len..]);
                }
            }
        }

        const token = try getGithubToken(allocator);

        // GHES support
        const ghes_base = std.process.getEnvVarOwned(allocator, "GHES_BASE_URL") catch "";
        defer if (ghes_base.len > 0) allocator.free(ghes_base);
        const ghes_upload = std.process.getEnvVarOwned(allocator, "GHES_UPLOAD_URL") catch "";
        defer if (ghes_upload.len > 0) allocator.free(ghes_upload);
        const ghes_auth = std.process.getEnvVarOwned(allocator, "GHES_AUTH_TOKEN") catch "";
        defer if (ghes_auth.len > 0) allocator.free(ghes_auth);

        var api_base: []const u8 = "https://api.github.com";
        var final_token = token;
        if (ghes_base.len > 0 and ghes_upload.len > 0 and ghes_auth.len > 0) {
            api_base = try std.fmt.allocPrint(allocator, "{s}/api/v3", .{ghes_base});
            final_token = ghes_auth;
        }

        return .{
            .owner = try allocator.dupe(u8, segments.items[0]),
            .repo = try allocator.dupe(u8, repo),
            .tag = tag,
            .token = final_token,
            .filter = filter,
            .api_base = api_base,
            .host = providers.Provider.hostString(uri) orelse "",
        };
    }

    pub fn getID() []const u8 {
        return "github";
    }

    pub fn fetchRelease(self: *const GitHub, allocator: std.mem.Allocator, client: *std.http.Client, opts: providers.FetchOpts) !providers.Release {
        var release_json: std.json.Value = undefined;
        var tag = self.tag;
        if (opts.version.len > 0) tag = opts.version;

        if (tag.len > 0) {
            std.log.info("Getting {s} release for {s}/{s}", .{ tag, self.owner, self.repo });
            const enc_tag = try http_util.encodePathSegment(allocator, tag);
            const url = try std.fmt.allocPrint(allocator, "{s}/repos/{s}/{s}/releases/tags/{s}", .{ self.api_base, self.owner, self.repo, enc_tag });
            defer allocator.free(url);
            release_json = try http_util.getJson(allocator, client, url, self.authHeaders(allocator));
        } else if (self.filter.len > 0) {
            std.log.info("Getting latest release matching \"{s}\" for {s}/{s}", .{ self.filter, self.owner, self.repo });
            release_json = try self.findLatestMatchingRelease(allocator, client);
        } else {
            std.log.info("Getting latest release for {s}/{s}", .{ self.owner, self.repo });
            const url = try std.fmt.allocPrint(allocator, "{s}/repos/{s}/{s}/releases/latest", .{ self.api_base, self.owner, self.repo });
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
        var html_url: []const u8 = "";
        if (release_json.object.get("tag_name")) |t| {
                    if (t == .string) {
                        version = t.string;
                    }
                }
        if (release_json.object.get("html_url")) |h| {
                    if (h == .string) {
                        html_url = h.string;
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
            .latest_url = try allocator.dupe(u8, html_url),
            .repo_name = self.repo,
            .assets = try candidates.toOwnedSlice(allocator),
        };
    }

    pub fn getLatestVersion(self: *const GitHub, allocator: std.mem.Allocator, client: *std.http.Client) !providers.Latest {
        std.log.debug("Getting latest release for {s}/{s}", .{ self.owner, self.repo });
        var release_json: std.json.Value = undefined;
        if (self.filter.len > 0) {
            release_json = try self.findLatestMatchingRelease(allocator, client);
        } else {
            const url = try std.fmt.allocPrint(allocator, "{s}/repos/{s}/{s}/releases/latest", .{ self.api_base, self.owner, self.repo });
            defer allocator.free(url);
            release_json = try http_util.getJson(allocator, client, url, self.authHeaders(allocator));
        }
        var version: []const u8 = "";
        var html_url: []const u8 = "";
        if (release_json.object.get("tag_name")) |t| {
                    if (t == .string) {
                        version = t.string;
                    }
                }
        if (release_json.object.get("html_url")) |h| {
                    if (h == .string) {
                        html_url = h.string;
                    }
                }
        return .{ .version = try allocator.dupe(u8, version), .url = try allocator.dupe(u8, html_url) };
    }

    fn findLatestMatchingRelease(self: *const GitHub, allocator: std.mem.Allocator, client: *std.http.Client) !std.json.Value {
        var page: usize = 1;
        while (true) {
            const url = try std.fmt.allocPrint(allocator, "{s}/repos/{s}/{s}/releases?per_page=30&page={d}", .{ self.api_base, self.owner, self.repo, page });
            defer allocator.free(url);
            const val = try http_util.getJson(allocator, client, url, self.authHeaders(allocator));
            if (val != .array) return error.InvalidResponse;
            for (val.array.items) |r| {
                if (r != .object) continue;
                var tag_name: []const u8 = "";
                if (r.object.get("html_url")) |h| {
                    if (h == .string) {
                        tag_name = std.fs.path.basename(h.string);
                    }
                }
                if (std.mem.eql(u8, tag_name, "")) continue;
                if (globMatch(self.filter, tag_name)) {
                    return r;
                }
            }
            if (val.array.items.len < 30) break;
            page += 1;
        }
        std.log.err("no release matching \"{s}\" found for {s}/{s}", .{ self.filter, self.owner, self.repo });
        return error.NoMatchingRelease;
    }

    fn authHeaders(self: *const GitHub, allocator: std.mem.Allocator) []const std.http.Header {
        if (self.token.len == 0) {
            return &.{
                .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            };
        }
        const headers = allocator.alloc(std.http.Header, 2) catch return &.{};
        headers[0] = .{ .name = "Accept", .value = "application/vnd.github.v3+json" };
        const auth = std.fmt.allocPrint(allocator, "token {s}", .{self.token}) catch {
            return &.{};
        };
        headers[1] = .{ .name = "Authorization", .value = auth };
        return headers;
    }

    /// Extra headers for asset downloads.
    pub fn downloadHeaders(self: *const GitHub, allocator: std.mem.Allocator) []const std.http.Header {
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
};

fn getGithubToken(allocator: std.mem.Allocator) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, "GITHUB_AUTH_TOKEN")) |t| {
        if (t.len > 0) return t;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "GITHUB_TOKEN")) |t| {
        if (t.len > 0) return t;
    } else |_| {}
    return "";
}

/// Minimal glob used for the github ?filter= release-tag matching.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    // Reuse assets.zig's glob matcher via a public wrapper.
    return assets.globMatch(pattern, name);
}
