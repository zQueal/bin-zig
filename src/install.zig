const std = @import("std");
const config = @import("config.zig");
const github = @import("github.zig");
const gitlab = @import("gitlab.zig");
const codeberg = @import("codeberg.zig");
const utils = @import("utils.zig");
const extract_mod = @import("extract.zig");
const advanced_download = @import("download.zig");
const checksum_mod = @import("checksum.zig");

pub const Provider = enum {
    github,
    gitlab,
    codeberg,

    pub fn fromUrl(url: []const u8, explicit_provider: ?Provider) !Provider {
        // If explicit provider provided, use it
        if (explicit_provider) |prov| return prov;

        // Auto-detect from full URL (https://)
        if (std.mem.indexOf(u8, url, "https://github.com/") != null) return .github;
        if (std.mem.indexOf(u8, url, "https://gitlab.com/") != null) return .gitlab;
        if (std.mem.indexOf(u8, url, "https://codeberg.org/") != null) return .codeberg;

        // Auto-detect from domain format (github.com/)
        if (std.mem.indexOf(u8, url, "github.com/") != null) return .github;
        if (std.mem.indexOf(u8, url, "gitlab.com/") != null) return .gitlab;
        if (std.mem.indexOf(u8, url, "codeberg.org/") != null) return .codeberg;

        // Validate user/repo format (exactly one slash)
        var slash_count: usize = 0;
        var it = std.mem.splitScalar(u8, url, '/');
        var parts: [2][]const u8 = undefined;
        while (it.next()) |part| {
            if (slash_count < 2) {
                parts[slash_count] = part;
            }
            slash_count += 1;
        }

        if (slash_count != 2 or parts[0].len == 0 or parts[1].len == 0) {
            return error.InvalidURL;
        }

        // Default to github for "user/repo" format
        return .github;
    }

    pub fn prefix(self: Provider) []const u8 {
        return switch (self) {
            .github => "github.com/",
            .gitlab => "gitlab.com/",
            .codeberg => "codeberg.org/",
        };
    }
};

pub const InstallOptions = struct {
    alias: ?[]const u8 = null,
    interactive: bool = false,
    install_path: ?[]const u8 = null,
    provider: ?Provider = null,
};

pub fn install(allocator: std.mem.Allocator, conf: *config.Config, url: []const u8, env: std.process.Environ, io: std.Io, options: InstallOptions) !void {
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    const provider = try Provider.fromUrl(url, options.provider);
    const pref = provider.prefix();

    var rest: []const u8 = undefined;

    // Handle full URL (https://)
    if (std.mem.indexOf(u8, url, "https://") != null) {
        const idx = std.mem.indexOf(u8, url, pref).?;
        rest = url[idx + pref.len ..];
    }
    // Handle domain format (github.com/) or short format (user/repo)
    else if (std.mem.indexOf(u8, url, pref) != null) {
        const idx = std.mem.indexOf(u8, url, pref).?;
        rest = url[idx + pref.len ..];
    }
    // Short format (user/repo)
    else {
        rest = url;
    }

    var it = std.mem.splitScalar(u8, rest, '/');
    const user = it.next() orelse return error.InvalidURL;
    var repo_full = it.next() orelse return error.InvalidURL;

    var repo = repo_full;
    var tag: []const u8 = "";
    if (std.mem.indexOfScalar(u8, repo_full, '@')) |at_idx| {
        repo = repo_full[0..at_idx];
        tag = repo_full[at_idx + 1 ..];
    }

    std.log.info("Fetching release information from {s} for {s}/{s}{s}{s}...", .{ @tagName(provider), user, repo, if (tag.len > 0) "@" else "", tag });

    var tag_name: []const u8 = undefined;
    var asset_name: []const u8 = undefined;
    var download_url: []const u8 = undefined;

    switch (provider) {
        .github => {
            const release = try github.fetchRelease(allocator, &client, user, repo, tag, conf.tokens.github);
            _ = try github.selectBestAsset(allocator, release); // Score them
            const asset_val = if (options.interactive) try selectGitHubAssetInteractively(release.assets, io) else (try github.selectBestAsset(allocator, release)) orelse return error.NoAssetFound;

            tag_name = try allocator.dupe(u8, release.tag_name);
            asset_name = try allocator.dupe(u8, asset_val.name);
            download_url = try allocator.dupe(u8, asset_val.browser_download_url);

            const download_path = try prepareDownloadPath(allocator, conf, asset_name, io);
            try performDownload(allocator, &client, download_url, download_path, io, conf.download_threads);
            try checksum_mod.verify(allocator, &client, release, asset_name, download_path, io);
            try finalizeInstall(allocator, conf, env, io, download_path, url, repo, tag_name, "github", options.alias);
        },
        .gitlab => {
            const release = try gitlab.fetchRelease(allocator, &client, user, repo, tag, conf.tokens.gitlab);
            _ = try gitlab.selectBestAsset(allocator, release); // Score them
            const asset_val = if (options.interactive) try selectGitLabAssetInteractively(release.assets, io) else (try gitlab.selectBestAsset(allocator, release)) orelse return error.NoAssetFound;

            tag_name = try allocator.dupe(u8, release.tag_name);
            asset_name = try allocator.dupe(u8, asset_val.name);
            download_url = try allocator.dupe(u8, asset_val.browser_download_url);

            const download_path = try prepareDownloadPath(allocator, conf, asset_name, io);
            try performDownload(allocator, &client, download_url, download_path, io, conf.download_threads);
            try finalizeInstall(allocator, conf, env, io, download_path, url, repo, tag_name, "gitlab", options.alias);
        },
        .codeberg => {
            const release = try codeberg.fetchRelease(allocator, &client, user, repo, tag, conf.tokens.codeberg);
            _ = try codeberg.selectBestAsset(allocator, release); // Score them
            const asset_val = if (options.interactive) try selectCodebergAssetInteractively(release.assets, io) else (try codeberg.selectBestAsset(allocator, release)) orelse return error.NoAssetFound;

            tag_name = try allocator.dupe(u8, release.tag_name);
            asset_name = try allocator.dupe(u8, asset_val.name);
            download_url = try allocator.dupe(u8, asset_val.browser_download_url);

            const download_path = try prepareDownloadPath(allocator, conf, asset_name, io);
            try performDownload(allocator, &client, download_url, download_path, io, conf.download_threads);
            try finalizeInstall(allocator, conf, env, io, download_path, url, repo, tag_name, "codeberg", options.alias);
        },
    }
}

fn selectGitHubAssetInteractively(assets: []github.Asset, io: std.Io) !github.Asset {
    var stdout_buf: [1]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &stdout_buf);

    var stdin_buf: [1]u8 = undefined;
    var stdin_file = std.Io.File.stdin();
    var stdin = stdin_file.reader(io, &stdin_buf);

    std.log.info("Multiple assets found. Please select one:", .{});
    for (assets, 0..) |asset, i| {
        var sw = stdout.interface;
        try sw.print("  [{d}] {s} (score: {d})\n", .{ i + 1, asset.name, asset.score });
    }
    var sw2 = stdout.interface;
    try sw2.print("Select asset [1-{d}]: ", .{assets.len});
    try stdout.interface.flush();

    const line = (try stdin.interface.takeDelimiter('\n')) orelse return error.InvalidInput;
    const trimmed = std.mem.trim(u8, line, " \r\t");
    const choice = try std.fmt.parseInt(usize, trimmed, 10);

    if (choice < 1 or choice > assets.len) return error.InvalidChoice;
    return assets[choice - 1];
}

fn selectGitLabAssetInteractively(assets: []gitlab.Asset, io: std.Io) !gitlab.Asset {
    var stdout_buf: [1]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &stdout_buf);

    var stdin_buf: [1]u8 = undefined;
    var stdin_file = std.Io.File.stdin();
    var stdin = stdin_file.reader(io, &stdin_buf);

    std.log.info("Multiple assets found. Please select one:", .{});
    for (assets, 0..) |asset, i| {
        var sw = stdout.interface;
        try sw.print("  [{d}] {s} (score: {d})\n", .{ i + 1, asset.name, asset.score });
    }
    var sw2 = stdout.interface;
    try sw2.print("Select asset [1-{d}]: ", .{assets.len});
    try stdout.interface.flush();

    const line = (try stdin.interface.takeDelimiter('\n')) orelse return error.InvalidInput;
    const trimmed = std.mem.trim(u8, line, " \r\t");
    const choice = try std.fmt.parseInt(usize, trimmed, 10);

    if (choice < 1 or choice > assets.len) return error.InvalidChoice;
    return assets[choice - 1];
}

fn selectCodebergAssetInteractively(assets: []codeberg.Asset, io: std.Io) !codeberg.Asset {
    var stdout_buf: [1]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &stdout_buf);

    var stdin_buf: [1]u8 = undefined;
    var stdin_file = std.Io.File.stdin();
    var stdin = stdin_file.reader(io, &stdin_buf);

    std.log.info("Multiple assets found. Please select one:", .{});
    for (assets, 0..) |asset, i| {
        var sw = stdout.interface;
        try sw.print("  [{d}] {s} (score: {d})\n", .{ i + 1, asset.name, asset.score });
    }
    var sw2 = stdout.interface;
    try sw2.print("Select asset [1-{d}]: ", .{assets.len});
    try stdout.interface.flush();

    const line = (try stdin.interface.takeDelimiter('\n')) orelse return error.InvalidInput;
    const trimmed = std.mem.trim(u8, line, " \r\t");
    const choice = try std.fmt.parseInt(usize, trimmed, 10);

    if (choice < 1 or choice > assets.len) return error.InvalidChoice;
    return assets[choice - 1];
}

fn prepareDownloadPath(allocator: std.mem.Allocator, conf: *config.Config, asset_name: []const u8, io: std.Io) ![]const u8 {
    const download_dir = try std.fs.path.join(allocator, &[_][]const u8{ std.fs.path.dirname(conf.bin_dir) orelse ".", "cache" });
    std.Io.Dir.createDirAbsolute(io, download_dir, .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;
    return try std.fs.path.join(allocator, &[_][]const u8{ download_dir, asset_name });
}

fn performDownload(allocator: std.mem.Allocator, client: *std.http.Client, url: []const u8, dest: []const u8, io: std.Io, threads: u32) !void {
    std.log.info("Downloading to {s}...", .{dest});
    try advanced_download.download(allocator, client, url, dest, io, .{ .threads = threads });
}

fn finalizeInstall(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.Environ, io: std.Io, download_path: []const u8, url: []const u8, repo: []const u8, version: []const u8, provider_name: []const u8, alias: ?[]const u8) !void {
    const install_path_dir = conf.bin_dir;
    std.Io.Dir.createDirAbsolute(io, install_path_dir, .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;

    var final_bin_path: []const u8 = "";
    const asset_name = std.fs.path.basename(download_path);
    const install_name = alias orelse repo;

    if (std.mem.endsWith(u8, asset_name, ".zip") or std.mem.endsWith(u8, asset_name, ".tar.gz") or std.mem.endsWith(u8, asset_name, ".tgz") or std.mem.endsWith(u8, asset_name, ".tar.xz") or std.mem.endsWith(u8, asset_name, ".tar.zst") or std.mem.endsWith(u8, asset_name, ".tar.zstd") or std.mem.endsWith(u8, asset_name, ".tar.lzma") or std.mem.endsWith(u8, asset_name, ".tar")) {
        final_bin_path = try extract_mod.extractArchive(allocator, download_path, install_path_dir, install_name, io);
    } else {
        const builtin = @import("builtin");
        const bin_name = if (builtin.os.tag == .windows and !std.mem.endsWith(u8, install_name, ".exe")) try std.fmt.allocPrint(allocator, "{s}.exe", .{install_name}) else try allocator.dupe(u8, install_name);
        const dest_path = try std.fs.path.join(allocator, &[_][]const u8{ install_path_dir, bin_name });
        try utils.copyFileAbsolute(io, download_path, dest_path);
        final_bin_path = dest_path;
    }

    var new_bin = config.Binary{
        .path = try allocator.dupe(u8, final_bin_path),
        .remote_name = try allocator.dupe(u8, install_name),
        .version = try allocator.dupe(u8, version),
        .url = try allocator.dupe(u8, url),
        .provider = try allocator.dupe(u8, provider_name),
    };
    try conf.bins.put(new_bin.path, new_bin);
    try config.save(conf, env, io);

    std.log.info("Successfully installed {s} version {s}", .{ install_name, version });
}
