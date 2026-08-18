//! GitLab provider mirroring pkg/providers/gitlab.go: release assets are
//! gathered from project packages, release asset links and links inside the
//! release description. Self-hosted GitLab is supported via the URL hostname.

const std = @import("std");
const assets = @import("assets.zig");
const http_util = @import("http_util.zig");
const providers = @import("providers.zig");
const semver = @import("semver.zig");
const utils = @import("utils.zig");

pub const GitLab = struct {
    owner: []const u8,
    repo: []const u8,
    tag: []const u8,
    token: []const u8,
    api_base: []const u8,

    pub fn init(allocator: std.mem.Allocator, uri: std.Uri, provider_name: []const u8) !GitLab {
        _ = provider_name;
        var segments = std.ArrayList([]const u8).empty;
        defer segments.deinit(allocator);
        var it = std.mem.splitScalar(u8, providers.Provider.pathString(uri), '/');
        while (it.next()) |seg| {
            if (seg.len > 0) try segments.append(allocator, seg);
        }
        if (segments.items.len < 2) {
            std.log.debug("Error parsing GitLab URL, can't find owner and repo", .{});
            return error.InvalidURL;
        }

        var tag: []const u8 = "";
        var repo = segments.items[1];
        if (std.mem.indexOf(u8, providers.Provider.pathString(uri), "/releases/") != null) {
            for (segments.items, 0..) |seg, i| {
                if (std.mem.eql(u8, seg, "releases")) {
                    var parts = std.ArrayList([]const u8).empty;
                    defer parts.deinit(allocator);
                    for (segments.items[i + 1 ..]) |p| try parts.append(allocator, p);
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

        const host = providers.Provider.hostString(uri) orelse return error.InvalidURL;
        const hostname = host;

        var token = std.process.getEnvVarOwned(allocator, "GITLAB_TOKEN") catch "";
        if (token.len == 0) {
            const hostname_specific_name = try std.fmt.allocPrint(allocator, "GITLAB_TOKEN_{s}", .{hostname});
            defer allocator.free(hostname_specific_name);
            var cleaned = std.ArrayList(u8).empty;
            defer cleaned.deinit(allocator);
            for (hostname_specific_name) |c| {
                if (c == '.') try cleaned.append(allocator, '_') else try cleaned.append(allocator, c);
            }
            token = std.process.getEnvVarOwned(allocator, cleaned.items) catch "";
        }

        const api_base = try std.fmt.allocPrint(allocator, "https://{s}/api/v4", .{hostname});

        return .{
            .owner = try allocator.dupe(u8, segments.items[0]),
            .repo = try allocator.dupe(u8, repo),
            .tag = tag,
            .token = token,
            .api_base = api_base,
        };
    }

    pub fn getID() []const u8 {
        return "gitlab";
    }

    fn projectPath(self: *const GitLab) []const u8 {
        // "owner/repo" is URL-escaped at the call sites.
        return self.owner;
    }

    fn projectApi(self: *const GitLab, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/projects/{s}%2F{s}", .{ self.api_base, self.owner, self.repo });
    }

    fn authHeaders(self: *const GitLab, allocator: std.mem.Allocator) []const std.http.Header {
        if (self.token.len == 0) return &.{};
        const headers = allocator.alloc(std.http.Header, 1) catch return &.{};
        headers[0] = .{ .name = "PRIVATE-TOKEN", .value = self.token };
        return headers;
    }

    /// Extra headers for asset downloads.
    pub fn downloadHeaders(self: *const GitLab, allocator: std.mem.Allocator) []const std.http.Header {
        return self.authHeaders(allocator);
    }

    pub fn fetchRelease(self: *const GitLab, allocator: std.mem.Allocator, client: *std.http.Client, opts: providers.FetchOpts) !providers.Release {
        var tag = self.tag;
        if (opts.version.len > 0) tag = opts.version;

        var release_json: std.json.Value = undefined;
        if (tag.len > 0) {
            std.log.info("Getting {s} release for {s}/{s}", .{ tag, self.owner, self.repo });
            const enc_tag = try http_util.encodePathSegment(allocator, tag);
            const url = try std.fmt.allocPrint(allocator, "{s}/releases/{s}", .{ try self.projectApi(allocator), enc_tag });
            defer allocator.free(url);
            release_json = try http_util.getJson(allocator, client, url, self.authHeaders(allocator));
        } else {
            std.log.info("Getting latest release for {s}/{s}", .{ self.owner, self.repo });
            const latest = try self.getLatestVersion(allocator, client);
            const url = try std.fmt.allocPrint(allocator, "{s}/releases/{s}", .{ try self.projectApi(allocator), latest.version });
            defer allocator.free(url);
            release_json = try http_util.getJson(allocator, client, url, self.authHeaders(allocator));
        }

        var version: []const u8 = "";
        if (release_json.object.get("tag_name")) |t| {
                    if (t == .string) {
                        version = t.string;
                    }
                }

        var candidates = std.ArrayList(assets.Asset).empty;
        defer candidates.deinit(allocator);
        var candidate_urls = std.StringHashMap(void).init(allocator);
        defer candidate_urls.deinit();

        // Project info: visibility + packages_enabled.
        var project_is_public = true;
        var packages_enabled = false;
        if (http_util.getJson(allocator, client, try self.projectApi(allocator), self.authHeaders(allocator))) |project| {
            if (project.object.get("visibility")) |vis| {
                if (vis == .string and vis.string.len > 0 and !std.mem.eql(u8, vis.string, "public")) project_is_public = false;
            }
            if (project.object.get("packages_enabled")) |pe| {
                    if (pe == .bool) {
                        packages_enabled = pe.bool;
                    }
                }
        } else |_| {
            project_is_public = self.token.len == 0;
        }
        std.log.debug("Project is public: {}", .{project_is_public});

        const try_packages = project_is_public or packages_enabled;
        if (try_packages) {
            const tag_version = utils.stripPrefix(version, "v") orelse version;
            const packages_url = try std.fmt.allocPrint(allocator, "{s}?order_by=version&sort=desc", .{ try self.projectApi(allocator) });
            defer allocator.free(packages_url);
            if (http_util.getJson(allocator, client, packages_url, self.authHeaders(allocator))) |packages| {
                if (packages == .array) {
                    for (packages.array.items) |pkg| {
                        if (pkg != .object) continue;
                        var pkg_version: []const u8 = "";
                        var pkg_type: []const u8 = "";
                        var pkg_name: []const u8 = "";
                        var pkg_id: i64 = 0;
                        if (pkg.object.get("version")) |v| {
                    if (v == .string) {
                        pkg_version = v.string;
                    }
                }
                        if (pkg.object.get("package_type")) |v| {
                    if (v == .string) {
                        pkg_type = v.string;
                    }
                }
                        if (pkg.object.get("name")) |v| {
                    if (v == .string) {
                        pkg_name = v.string;
                    }
                }
                        if (pkg.object.get("id")) |v| {
                    if (v == .integer) {
                        pkg_id = v.integer;
                    }
                }
                        if (!std.mem.eql(u8, utils.stripPrefix(pkg_version, "v") orelse pkg_version, tag_version)) continue;

                        var page: i64 = 0;
                        while (true) : (page += 1) {
                            const files_url = try std.fmt.allocPrint(allocator, "{s}/packages/{d}/package_files?per_page=20&page={d}", .{ try self.projectApi(allocator), pkg_id, page + 1 });
                            defer allocator.free(files_url);
                            const files = http_util.getJson(allocator, client, files_url, self.authHeaders(allocator)) catch break;
                            if (files != .array or files.array.items.len == 0) break;
                            for (files.array.items) |f| {
                                if (f != .object) continue;
                                var filename: []const u8 = "";
                                if (f.object.get("file_name")) |v| {
                    if (v == .string) {
                        filename = v.string;
                    }
                }
                                if (filename.len == 0) continue;
                                const asset_url = try std.fmt.allocPrint(allocator, "{s}/packages/{s}/{s}/{s}/{s}", .{ try self.projectApi(allocator), pkg_type, pkg_name, pkg_version, filename });
                                if (candidate_urls.contains(asset_url)) continue;
                                try candidate_urls.put(asset_url, {});
                                const display = try std.fmt.allocPrint(allocator, "{s} ({s} package)", .{ filename, pkg_type });
                                try candidates.append(allocator, .{ .name = try allocator.dupe(u8, filename), .display_name = display, .url = asset_url });
                                std.log.debug("Adding {s} with URL {s}", .{ filename, asset_url });
                            }
                            if (files.array.items.len < 20) break;
                        }
                    }
                }
            } else |_| {}
        }

        // Release asset links.
        var project_web_url: []const u8 = "";
        if (release_json.object.get("_links")) |l| {
            if (l == .object) {
                if (l.object.get("self")) |s| {
                    if (s == .string) {
                        project_web_url = s.string;
                    }
                }
            }
        }
        const project_uploads_url = try std.fmt.allocPrint(allocator, "{s}/uploads/", .{project_web_url});
        defer allocator.free(project_uploads_url);

        if (release_json.object.get("assets")) |rassets| {
            if (rassets == .object) {
                if (rassets.object.get("links")) |links| {
                    if (links == .array) {
                        for (links.array.items) |link| {
                            if (link != .object) continue;
                            var link_name: []const u8 = "";
                            var link_url: []const u8 = "";
                            if (link.object.get("name")) |v| {
                    if (v == .string) {
                        link_name = v.string;
                    }
                }
                            if (link.object.get("url")) |v| {
                    if (v == .string) {
                        link_url = v.string;
                    }
                }
                            if (link_name.len == 0 or link_url.len == 0) continue;
                            if (!project_is_public and std.mem.startsWith(u8, link_url, project_uploads_url)) continue;
                            if (candidate_urls.contains(link_url)) continue;
                            try candidate_urls.put(link_url, {});
                            const display = try std.fmt.allocPrint(allocator, "{s} (asset link)", .{link_name});
                            try candidates.append(allocator, .{ .name = try allocator.dupe(u8, link_name), .display_name = display, .url = try allocator.dupe(u8, link_url) });
                            std.log.debug("Adding {s} with URL {s}", .{ link_name, link_url });
                        }
                    }
                }
            }
        }

        // Links inside the release description (markdown [title](url)).
        var description: []const u8 = "";
        if (release_json.object.get("description")) |d| {
                    if (d == .string) {
                        description = d.string;
                    }
                }
        var md_it = MarkdownLinkIter.init(description);
        while (md_it.next()) |md_link| {
            const title = md_link.title;
            const dest = md_link.dest;
            if (title.len == 0 or dest.len == 0) continue;
            if (!project_is_public and std.mem.startsWith(u8, dest, project_uploads_url)) continue;
            if (candidate_urls.contains(dest)) continue;
            try candidate_urls.put(dest, {});
            const display = try std.fmt.allocPrint(allocator, "{s} (from release description)", .{title});
            try candidates.append(allocator, .{ .name = try allocator.dupe(u8, title), .display_name = display, .url = try allocator.dupe(u8, dest) });
            std.log.debug("Adding {s} with URL {s}", .{ title, dest });
        }

        return .{
            .version = try allocator.dupe(u8, version),
            .repo_name = self.repo,
            .assets = try candidates.toOwnedSlice(allocator),
        };
    }

    pub fn getLatestVersion(self: *const GitLab, allocator: std.mem.Allocator, client: *std.http.Client) !providers.Latest {
        std.log.debug("Getting latest release for {s}/{s}", .{ self.owner, self.repo });
        const url = try std.fmt.allocPrint(allocator, "{s}?per_page=100", .{ try self.projectApi(allocator) });
        defer allocator.free(url);
        const releases = try http_util.getJson(allocator, client, url, self.authHeaders(allocator));
        if (releases != .array) return error.InvalidResponse;
        if (releases.array.items.len == 0) {
            std.log.err("no releases found for {s}/{s}", .{ self.owner, self.repo });
            return error.NoReleases;
        }

        var best: struct { sv: semver.Version, tag: []const u8, web_url: []const u8 } = undefined;
        var have_best = false;
        for (releases.array.items) |r| {
            if (r != .object) continue;
            var tag_name: []const u8 = "";
            if (r.object.get("tag_name")) |t| {
                    if (t == .string) {
                        tag_name = t.string;
                    }
                }
            if (tag_name.len == 0) continue;
            const sv = semver.parse(utils.stripPrefix(tag_name, "v") orelse tag_name) orelse continue;
            if (sv.prerelease.len != 0 or sv.metadata.len != 0) continue;
            if (!have_best or semver.compare(sv, best.sv) == .gt) {
                var web_url: []const u8 = "";
                if (r.object.get("commit")) |c| {
                    if (c == .object) {
                        if (c.object.get("web_url")) |w| {
                    if (w == .string) {
                        web_url = w.string;
                    }
                }
                    }
                }
                best = .{ .sv = sv, .tag = tag_name, .web_url = web_url };
                have_best = true;
            }
        }
        if (!have_best) {
            // No semver releases: fall back to the first release (Go keeps
            // releases[0] as highestTagName when no semver versions parse).
            var first_tag: []const u8 = "";
            var first_url: []const u8 = "";
            if (releases.array.items[0].object.get("tag_name")) |t| {
                    if (t == .string) {
                        first_tag = t.string;
                    }
                }
            if (releases.array.items[0].object.get("commit")) |c| {
                if (c == .object) {
                    if (c.object.get("web_url")) |w| {
                    if (w == .string) {
                        first_url = w.string;
                    }
                }
                }
            }
            return .{ .version = try allocator.dupe(u8, first_tag), .url = try allocator.dupe(u8, first_url) };
        }
        return .{ .version = try allocator.dupe(u8, best.tag), .url = try allocator.dupe(u8, best.web_url) };
    }
};

const MarkdownLink = struct { title: []const u8, dest: []const u8 };

const MarkdownLinkIter = struct {
    text: []const u8,
    pos: usize = 0,

    fn init(text: []const u8) MarkdownLinkIter {
        return .{ .text = text };
    }

    fn next(self: *MarkdownLinkIter) ?MarkdownLink {
        while (self.pos < self.text.len) {
            const start = std.mem.indexOfScalarPos(u8, self.text, self.pos, '[') orelse return null;
            const close = std.mem.indexOfScalarPos(u8, self.text, start + 1, ']') orelse return null;
            // must be followed by ( ... )
            if (close + 1 >= self.text.len or self.text[close + 1] != '(') {
                self.pos = start + 1;
                continue;
            }
            const paren_end = std.mem.indexOfScalarPos(u8, self.text, close + 2, ')') orelse {
                self.pos = start + 1;
                continue;
            };
            const title = self.text[start + 1 .. close];
            const dest = self.text[close + 2 .. paren_end];
            self.pos = paren_end + 1;
            return .{ .title = title, .dest = dest };
        }
        return null;
    }
};
