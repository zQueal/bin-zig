const std = @import("std");
const config = @import("config.zig");
const github = @import("github.zig");
const gitlab = @import("gitlab.zig");
const codeberg = @import("codeberg.zig");
const install = @import("install.zig");

pub fn update(allocator: std.mem.Allocator, conf: *config.Config, target: ?[]const u8, all_flag: bool, env: std.process.Environ, io: std.Io) !void {
    if (all_flag) {
        std.log.info("Updating all binaries...", .{});
        var it = conf.bins.iterator();
        while (it.next()) |entry| {
            try updateOne(allocator, conf, entry.value_ptr.*, env, io);
        }
        return;
    }

    if (target) |name| {
        var it = conf.bins.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.remote_name, name)) {
                try updateOne(allocator, conf, entry.value_ptr.*, env, io);
                return;
            }
        }
        std.log.err("Binary '{s}' not found in managed list.", .{name});
        return error.BinaryNotFound;
    }

    // Default: Check for updates
    std.log.info("Checking for updates...", .{});
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var it = conf.bins.iterator();
    var found_updates = false;
    while (it.next()) |entry| {
        const bin = entry.value_ptr.*;
        if (bin.pinned) continue;

        const latest_version = try getLatestVersion(allocator, &client, bin, conf);
        defer allocator.free(latest_version);

        if (!std.mem.eql(u8, bin.version, latest_version)) {
            std.log.info("  {s}: {s} -> {s} (update available)", .{ bin.remote_name, bin.version, latest_version });
            found_updates = true;
        }
    }

    if (!found_updates) {
        std.log.info("All binaries are up to date.", .{});
    } else {
        std.log.info("Run 'bin update --all' to update all binaries.", .{});
    }
}

fn getLatestVersion(allocator: std.mem.Allocator, client: *std.http.Client, bin: config.Binary, conf: *config.Config) ![]const u8 {
    // Parse user/repo from URL
    const url = bin.url;
    var user: []const u8 = "";
    var repo: []const u8 = "";

    if (std.mem.eql(u8, bin.provider, "github")) {
        const prefix = "github.com/";
        const idx = std.mem.indexOf(u8, url, prefix).?;
        const rest = url[idx + prefix.len ..];
        var it = std.mem.splitScalar(u8, rest, '/');
        user = it.next().?;
        repo = it.next().?;
        if (std.mem.indexOfScalar(u8, repo, '@')) |at| repo = repo[0..at];
        const release = try github.fetchRelease(allocator, client, user, repo, "", conf.tokens.github);
        return try allocator.dupe(u8, release.tag_name);
    } else if (std.mem.eql(u8, bin.provider, "gitlab")) {
        const prefix = "gitlab.com/";
        const idx = std.mem.indexOf(u8, url, prefix).?;
        const rest = url[idx + prefix.len ..];
        var it = std.mem.splitScalar(u8, rest, '/');
        user = it.next().?;
        repo = it.next().?;
        if (std.mem.indexOfScalar(u8, repo, '@')) |at| repo = repo[0..at];
        const release = try gitlab.fetchRelease(allocator, client, user, repo, "", conf.tokens.gitlab);
        return try allocator.dupe(u8, release.tag_name);
    } else if (std.mem.eql(u8, bin.provider, "codeberg")) {
        const prefix = "codeberg.org/";
        const idx = std.mem.indexOf(u8, url, prefix).?;
        const rest = url[idx + prefix.len ..];
        var it = std.mem.splitScalar(u8, rest, '/');
        user = it.next().?;
        repo = it.next().?;
        if (std.mem.indexOfScalar(u8, repo, '@')) |at| repo = repo[0..at];
        const release = try codeberg.fetchRelease(allocator, client, user, repo, "", conf.tokens.codeberg);
        return try allocator.dupe(u8, release.tag_name);
    }
    return try allocator.dupe(u8, bin.version);
}

fn updateOne(allocator: std.mem.Allocator, conf: *config.Config, bin: config.Binary, env: std.process.Environ, io: std.Io) !void {
    if (bin.pinned) {
        std.log.info("Skipping {s} (Pinned to version {s})", .{ bin.remote_name, bin.version });
        return;
    }
    std.log.info("Checking updates for {s}...", .{bin.remote_name});
    // For now, update just re-installs from the same URL.
    // In a fuller implementation, it would check the latest tag via API first.
    try install.install(allocator, conf, bin.url, env, io, .{ .alias = bin.remote_name });
}
