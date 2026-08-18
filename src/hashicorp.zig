//! HashiCorp releases provider mirroring pkg/providers/hashicorp.go:
//! releases.hashicorp.com/{repo}/index.json listing + per-version metadata.

const std = @import("std");
const assets = @import("assets.zig");
const http_util = @import("http_util.zig");
const options_mod = @import("options.zig");
const providers = @import("providers.zig");
const semver = @import("semver.zig");

const releases_url_base = "https://releases.hashicorp.com";

pub const HashiCorp = struct {
    repo: []const u8,
    tag: []const u8,

    pub fn init(allocator: std.mem.Allocator, uri: std.Uri) !HashiCorp {
        var segments = std.ArrayList([]const u8).empty;
        defer segments.deinit(allocator);
        var it = std.mem.splitScalar(u8, providers.Provider.pathString(uri), '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try segments.append(allocator, seg);
        }
        if (segments.items.len < 1) {
            std.log.err("Error parsing HashiCorp releases URL, can't find repo", .{});
            return error.InvalidURL;
        }
        var tag: []const u8 = "";
        if (segments.items.len >= 2) tag = segments.items[1];
        return .{
            .repo = try allocator.dupe(u8, segments.items[0]),
            .tag = tag,
        };
    }

    fn buildApiUrl(self: *const HashiCorp, allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
        _ = self;
        var parts = std.ArrayList([]const u8).empty;
        defer parts.deinit(allocator);
        try parts.append(allocator, releases_url_base);
        for (args) |a| try parts.append(allocator, a);
        try parts.append(allocator, "index.json");
        return std.mem.join(allocator, "/", parts.items);
    }

    fn getRelease(self: *const HashiCorp, allocator: std.mem.Allocator, client: *std.http.Client, version: []const u8) !std.json.Value {
        const url = try self.buildApiUrl(allocator, &.{ self.repo, version });
        defer allocator.free(url);
        return http_util.getJson(allocator, client, url, &.{});
    }

    fn listReleases(self: *const HashiCorp, allocator: std.mem.Allocator, client: *std.http.Client) !std.json.Value {
        const url = try self.buildApiUrl(allocator, &.{self.repo});
        defer allocator.free(url);
        return http_util.getJson(allocator, client, url, &.{});
    }

    /// Highest non-prerelease semver version, asking the user to disambiguate
    /// ties, then fetches its release metadata.
    fn latestRelease(self: *const HashiCorp, allocator: std.mem.Allocator, client: *std.http.Client) !std.json.Value {
        const repo = try self.listReleases(allocator, client);
        const versions = repo.object.get("versions") orelse return error.NoReleases;
        if (versions != .object or versions.object.count() == 0) {
            std.log.err("no releases found for {s}", .{self.repo});
            return error.NoReleases;
        }

        var svs = std.ArrayList(semver.Version).empty;
        defer svs.deinit(allocator);
        var it = versions.object.iterator();
        while (it.next()) |entry| {
            const v = entry.key_ptr.*;
            const sv = semver.parse(v) orelse {
                std.log.debug("unable to parse \"{s}\" as a semantic version", .{v});
                continue;
            };
            if (sv.prerelease.len == 0 and sv.metadata.len == 0) {
                try svs.append(allocator, sv);
            }
        }
        if (svs.items.len == 0) {
            std.log.err("no semver versions found for {s}", .{self.repo});
            return error.NoSemverVersions;
        }

        var highest = svs.items[0];
        for (svs.items[1..]) |sv| {
            if (semver.compare(sv, highest) == .gt) highest = sv;
        }

        // Collect tied versions (compare == 0).
        var tied = std.ArrayList([]const u8).empty;
        defer tied.deinit(allocator);
        for (svs.items) |sv| {
            if (semver.compare(sv, highest) == .eq) {
                try tied.append(allocator, try formatVersion(allocator, sv));
            }
        }
        if (tied.items.len > 1) {
            std.mem.sort([]const u8, tied.items, {}, struct {
                fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lessThan);
            const choice = try options_mod.select("Select file to download:", tied.items);
            return self.getRelease(allocator, client, choice);
        }

        return self.getRelease(allocator, client, try formatVersion(allocator, highest));
    }

    pub fn fetchRelease(self: *const HashiCorp, allocator: std.mem.Allocator, client: *std.http.Client, version: []const u8) !providers.Release {
        var release_json: std.json.Value = undefined;
        if (version.len == 0) {
            release_json = try self.latestRelease(allocator, client);
        } else {
            release_json = try self.getRelease(allocator, client, version);
        }

        var release_version: []const u8 = "";
        if (release_json.object.get("version")) |v| {
            if (v == .string) release_version = v.string;
        }

        var candidates = std.ArrayList(assets.Asset).empty;
        defer candidates.deinit(allocator);
        if (release_json.object.get("builds")) |builds| {
            if (builds == .array) {
                for (builds.array.items) |b| {
                    if (b != .object) continue;
                    var filename: []const u8 = "";
                    var furl: []const u8 = "";
                    if (b.object.get("filename")) |f| {
                        if (f == .string) filename = f.string;
                    }
                    if (b.object.get("url")) |u| {
                        if (u == .string) furl = u.string;
                    }
                    if (filename.len > 0 and furl.len > 0) {
                        try candidates.append(allocator, .{ .name = try allocator.dupe(u8, filename), .url = try allocator.dupe(u8, furl) });
                    }
                }
            }
        }

        return .{
            .version = try allocator.dupe(u8, release_version),
            .repo_name = self.repo,
            .assets = try candidates.toOwnedSlice(allocator),
        };
    }

    pub fn getLatestVersion(self: *const HashiCorp, allocator: std.mem.Allocator, client: *std.http.Client) !providers.Latest {
        std.log.debug("Getting latest release for {s}", .{self.repo});
        const release = try self.latestRelease(allocator, client);
        var version: []const u8 = "";
        if (release.object.get("version")) |v| {
            if (v == .string) version = v.string;
        }
        const url = try self.buildApiUrl(allocator, &.{ self.repo, version });
        return .{ .version = try allocator.dupe(u8, version), .url = url };
    }
};

fn formatVersion(allocator: std.mem.Allocator, v: semver.Version) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (v.segments, 0..) |seg, i| {
        if (i > 0) try out.append(allocator, '.');
        try out.writer(allocator).print("{d}", .{seg});
    }
    if (v.prerelease.len > 0) {
        try out.append(allocator, '-');
        try out.appendSlice(allocator, v.prerelease);
    }
    if (v.metadata.len > 0) {
        try out.append(allocator, '+');
        try out.appendSlice(allocator, v.metadata);
    }
    return out.toOwnedSlice(allocator);
}
