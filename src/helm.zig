//! Helm provider mirroring pkg/providers/helm.go: get.helm.sh publishes a
//! static set of os/arch archives per version; there is no listing API.

const std = @import("std");
const assets = @import("assets.zig");
const http_util = @import("http_util.zig");
const providers = @import("providers.zig");

const helm_download_base = "https://get.helm.sh";
const helm_latest_version = "https://get.helm.sh/helm-latest-version";

const HelmPlatform = struct { os: []const u8, arch: []const u8, ext: []const u8 };

const helm_platforms = [_]HelmPlatform{
    .{ .os = "darwin", .arch = "amd64", .ext = "tar.gz" },
    .{ .os = "darwin", .arch = "arm64", .ext = "tar.gz" },
    .{ .os = "linux", .arch = "386", .ext = "tar.gz" },
    .{ .os = "linux", .arch = "amd64", .ext = "tar.gz" },
    .{ .os = "linux", .arch = "arm", .ext = "tar.gz" },
    .{ .os = "linux", .arch = "arm64", .ext = "tar.gz" },
    .{ .os = "linux", .arch = "loong64", .ext = "tar.gz" },
    .{ .os = "linux", .arch = "ppc64le", .ext = "tar.gz" },
    .{ .os = "linux", .arch = "riscv64", .ext = "tar.gz" },
    .{ .os = "linux", .arch = "s390x", .ext = "tar.gz" },
    .{ .os = "windows", .arch = "amd64", .ext = "zip" },
    .{ .os = "windows", .arch = "arm64", .ext = "zip" },
};

pub const Helm = struct {
    tag: []const u8,

    pub fn init(allocator: std.mem.Allocator, uri: std.Uri) !Helm {
        const tag = try parseHelmTag(allocator, uri);
        return .{ .tag = tag };
    }

    fn downloadName(p: HelmPlatform, version: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "helm-{s}-{s}-{s}.{s}", .{ version, p.os, p.arch, p.ext });
    }

    fn candidates(self: *const Helm, allocator: std.mem.Allocator, version: []const u8) ![]assets.Asset {
        _ = self;
        var out = std.ArrayList(assets.Asset).empty;
        defer out.deinit(allocator);
        for (helm_platforms) |p| {
            const name = try downloadName(p, version, allocator);
            const url = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ helm_download_base, name });
            try out.append(allocator, .{ .name = name, .url = url });
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn fetchRelease(self: *const Helm, allocator: std.mem.Allocator, client: *std.http.Client, version: []const u8) !providers.Release {
        var v = version;
        if (v.len > 0 and v[0] != 'v') v = try std.fmt.allocPrint(allocator, "v{s}", .{version});
        if (v.len == 0) {
            const latest = try self.getLatestVersion(allocator, client);
            v = latest.version;
        }
        return .{
            .version = v,
            .repo_name = "helm",
            .assets = try self.candidates(allocator, v),
        };
    }

    pub fn getLatestVersion(self: *const Helm, allocator: std.mem.Allocator, client: *std.http.Client) !providers.Latest {
        std.log.debug("Getting latest release for helm", .{});
        const body = try http_util.getBody(allocator, client, helm_latest_version, &.{}, 1024 * 1024);
        const trimmed = std.mem.trim(u8, body, " \t\r\n");
        var version = trimmed;
        if (version.len > 0 and version[0] != 'v') version = try std.fmt.allocPrint(allocator, "v{s}", .{trimmed});
        if (version.len == 0) {
            std.log.err("could not determine latest Helm version", .{});
            return error.NoVersion;
        }
        const url = try self.downloadURL(allocator, version);
        return .{ .version = try allocator.dupe(u8, version), .url = url };
    }

    fn downloadURL(self: *const Helm, allocator: std.mem.Allocator, version: []const u8) ![]const u8 {
        _ = self;
        // linux/amd64 fallback, or the running platform when published.
        var platform = helm_platforms[3];
        for (helm_platforms) |p| {
            if (std.mem.eql(u8, p.os, @tagName(@import("builtin").os.tag)) and std.mem.eql(u8, p.arch, @tagName(@import("builtin").cpu.arch))) {
                platform = p;
                break;
            }
        }
        const name = try downloadName(platform, version, allocator);
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ helm_download_base, name });
    }
};

fn normalizeHelmVersion(version: []const u8) []const u8 {
    if (version.len == 0 or version[0] == 'v') return version;
    return version; // caller prepends nothing; versions on get.helm.sh already carry "v"
}
fn parseHelmTag(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    var path = providers.Provider.pathString(uri);
    while (path.len > 0 and path[0] == '/') path = path[1..];
    while (path.len > 0 and path[path.len - 1] == '/') path = path[0 .. path.len - 1];
    if (path.len == 0) return "";

    if (std.mem.startsWith(u8, path, "helm-")) {
        const v = path["helm-".len..];
        for (helm_platforms) |p| {
            const suffix = try std.fmt.allocPrint(allocator, "-{s}-{s}.{s}", .{ p.os, p.arch, p.ext });
            defer allocator.free(suffix);
            if (std.mem.endsWith(u8, v, suffix)) {
                return try allocator.dupe(u8, v[0 .. v.len - suffix.len]);
            }
        }
    }
    std.log.err("invalid get.helm.sh URL {s}, to install a specific version use the full release URL, e.g. https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz", .{providers.Provider.pathString(uri)});
    return error.InvalidURL;
}
