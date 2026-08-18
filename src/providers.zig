//! Unified provider abstraction mirroring pkg/providers of the reference
//! implementation: github, gitlab, codeberg, hashicorp, helm, goinstall and
//! docker, with the shared "select asset -> download -> unpack" flow.

const std = @import("std");
const assets = @import("assets.zig");
pub const github = @import("github.zig");
pub const gitlab = @import("gitlab.zig");
pub const codeberg = @import("codeberg.zig");
pub const hashicorp = @import("hashicorp.zig");
pub const helm = @import("helm.zig");
pub const goinstall = @import("goinstall.zig");
pub const docker = @import("docker.zig");
pub const semver = @import("semver.zig");

pub const FetchOpts = struct {
    all: bool = false,
    package_name: []const u8 = "",
    package_path: []const u8 = "",
    skip_path_check: bool = false,
    version: []const u8 = "",
    name_pattern: []const u8 = "",
    previous_asset: []const u8 = "",
    previous_version: []const u8 = "",
    auto_select_previous: bool = false,
};

pub const File = struct {
    data: []const u8,
    name: []const u8,
    version: []const u8,
    package_path: []const u8 = "",
    selected_asset: []const u8 = "",
};

pub const Release = struct {
    version: []const u8,
    latest_url: []const u8 = "",
    repo_name: []const u8,
    assets: []const assets.Asset,
    extra_headers: []const std.http.Header = &.{},
};

pub const Latest = struct {
    version: []const u8,
    url: []const u8,
};

pub const Provider = struct {
    id: []const u8,
    inner: Inner,

    const Inner = union(enum) {
        github: github.GitHub,
        gitlab: gitlab.GitLab,
        codeberg: codeberg.Codeberg,
        hashicorp: hashicorp.HashiCorp,
        helm: helm.Helm,
        goinstall: goinstall.GoInstall,
        docker: docker.Docker,
    };

    /// Extracts the raw host string from a parsed URI (0.15.2's Uri.host is a
    /// Component union).
    pub fn hostString(uri: std.Uri) ?[]const u8 {
        if (uri.host) |h| {
            return switch (h) {
                .raw => |s| s,
                .percent_encoded => |s| s,
            };
        }
        return null;
    }

    /// Extracts the raw path string from a parsed URI.
    pub fn pathString(uri: std.Uri) []const u8 {
        return switch (uri.path) {
            .raw => |s| s,
            .percent_encoded => |s| s,
        };
    }

    /// Extracts the raw query string from a parsed URI (null when absent).
    pub fn queryString(uri: std.Uri) ?[]const u8 {
        if (uri.query) |q| {
            return switch (q) {
                .raw => |s| s,
                .percent_encoded => |s| s,
            };
        }
        return null;
    }

    /// Mirrors providers.New(u, provider): URL prefix and host detection.
    pub fn new(allocator: std.mem.Allocator, u: []const u8, provider_name: []const u8) !Provider {
        if (std.mem.startsWith(u8, u, "docker://")) {
            return .{ .id = "docker", .inner = .{ .docker = try docker.Docker.init(allocator, u) } };
        }
        if (std.mem.startsWith(u8, u, "goinstall://") or std.mem.eql(u8, provider_name, "goinstall")) {
            return .{ .id = "goinstall", .inner = .{ .goinstall = try goinstall.GoInstall.init(allocator, u) } };
        }

        var full_url = u;
        if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://")) {
            full_url = try std.fmt.allocPrint(allocator, "https://{s}", .{u});
        }
        const uri = try std.Uri.parse(full_url);
        const host = Provider.hostString(uri) orelse return error.InvalidURL;

        if (std.mem.indexOf(u8, host, "github") != null or std.mem.eql(u8, provider_name, "github")) {
            return .{ .id = "github", .inner = .{ .github = try github.GitHub.init(allocator, uri, provider_name) } };
        }
        if (std.mem.indexOf(u8, host, "gitlab") != null or std.mem.eql(u8, provider_name, "gitlab")) {
            return .{ .id = "gitlab", .inner = .{ .gitlab = try gitlab.GitLab.init(allocator, uri, provider_name) } };
        }
        if (std.mem.indexOf(u8, host, "codeberg") != null or std.mem.eql(u8, provider_name, "codeberg")) {
            return .{ .id = "codeberg", .inner = .{ .codeberg = try codeberg.Codeberg.init(allocator, uri, provider_name) } };
        }
        if (std.mem.indexOf(u8, host, "get.helm.sh") != null or std.mem.eql(u8, provider_name, "helm")) {
            return .{ .id = "helm", .inner = .{ .helm = try helm.Helm.init(allocator, uri) } };
        }
        if (std.mem.indexOf(u8, host, "releases.hashicorp.com") != null or std.mem.eql(u8, provider_name, "hashicorp")) {
            return .{ .id = "hashicorp", .inner = .{ .hashicorp = try hashicorp.HashiCorp.init(allocator, uri) } };
        }

        std.log.debug("Can't find provider for url {s}", .{full_url});
        return error.UnknownProvider;
    }

    pub fn getID(self: *const Provider) []const u8 {
        return self.id;
    }

    pub fn fetch(self: *Provider, allocator: std.mem.Allocator, client: *std.http.Client, opts: FetchOpts) !File {
        return switch (self.inner) {
            .github => |*g| fetchGitHubLike(allocator, client, g, opts),
            .gitlab => |*g| fetchGitHubLike(allocator, client, g, opts),
            .codeberg => |*g| fetchGitHubLike(allocator, client, g, opts),
            .hashicorp => |*g| fetchHttpRelease(allocator, client, "hashicorp", g, opts),
            .helm => |*g| fetchHttpRelease(allocator, client, "helm", g, opts),
            .goinstall => |*g| g.fetch(allocator, client, opts),
            .docker => |*g| g.fetch(allocator, opts),
        };
    }

    pub fn getLatestVersion(self: *Provider, allocator: std.mem.Allocator, client: *std.http.Client) !Latest {
        return switch (self.inner) {
            .github => |*g| g.getLatestVersion(allocator, client),
            .gitlab => |*g| g.getLatestVersion(allocator, client),
            .codeberg => |*g| g.getLatestVersion(allocator, client),
            .hashicorp => |*g| g.getLatestVersion(allocator, client),
            .helm => |*g| g.getLatestVersion(allocator, client),
            .goinstall => |*g| g.getLatestVersion(allocator, client),
            .docker => |*g| g.getLatestVersion(allocator, client),
        };
    }
};

/// Shared flow for providers that enumerate release assets (github, gitlab,
/// codeberg): fetch release -> FilterAssets -> download -> process -> File.
fn fetchGitHubLike(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    src: anytype,
    opts: FetchOpts,
) !File {
    const release = try src.fetchRelease(allocator, client, opts);

    var fopts = assets.FilterOpts{
        .skip_scoring = opts.all,
        .package_name = opts.package_name,
        .package_path = opts.package_path,
        .skip_path_check = opts.skip_path_check,
        .name_pattern = opts.name_pattern,
        .preferred_asset = opts.previous_asset,
        .preferred_version = opts.previous_version,
        .current_version = release.version,
        .auto_select_previous = opts.auto_select_previous,
    };
    var filter = assets.Filter.init(&fopts);
    const gf = try filter.filterAssets(allocator, release.repo_name, release.assets);

    var gf_with_headers = gf;
    gf_with_headers.extra_headers = src.downloadHeaders(allocator);

    const processed = try filter.processURL(allocator, client, gf_with_headers);
    return .{
        .data = processed.data,
        .name = processed.name,
        .version = release.version,
        .package_path = processed.package_path,
        .selected_asset = gf.name,
    };
}

/// Shared flow for httpReleaseProvider-style sources (hashicorp, helm).
fn fetchHttpRelease(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    id: []const u8,
    src: anytype,
    opts: FetchOpts,
) !File {
    var version = src.tag;
    if (opts.version.len > 0) version = opts.version;

    if (version.len == 0) {
        std.log.info("Getting latest release for {s}", .{id});
    } else {
        std.log.info("Getting {s} release for {s}", .{ version, id });
    }

    const release = try src.fetchRelease(allocator, client, version);

    var fopts = assets.FilterOpts{
        .skip_scoring = opts.all,
        .package_name = opts.package_name,
        .package_path = opts.package_path,
        .skip_path_check = opts.skip_path_check,
        .name_pattern = opts.name_pattern,
        .preferred_asset = opts.previous_asset,
        .preferred_version = opts.previous_version,
        .current_version = release.version,
        .auto_select_previous = opts.auto_select_previous,
    };
    var filter = assets.Filter.init(&fopts);
    const gf = try filter.filterAssets(allocator, id, release.assets);

    var gf_with_headers = gf;
    gf_with_headers.extra_headers = release.extra_headers;

    const processed = try filter.processURL(allocator, client, gf_with_headers);
    return .{
        .data = processed.data,
        .name = processed.name,
        .version = release.version,
        .package_path = processed.package_path,
        .selected_asset = gf.name,
    };
}
