const std = @import("std");
const config = @import("config.zig");
const install_mod = @import("install.zig");
const prompt = @import("prompt.zig");
const providers = @import("providers.zig");
const semver = @import("semver.zig");

pub const UpdateOpts = struct {
    yes_to_update: bool = false,
    dry_run: bool = false,
    all: bool = false,
    skip_path_check: bool = false,
    continue_on_error: bool = false,
    exclude: []const []const u8 = &.{},
};

const UpdateInfo = struct {
    version: []const u8,
    url: []const u8,
};

/// Mirrors cmd/update.go of the reference implementation.
pub fn update(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, args: []const []const u8, opts: UpdateOpts) !void {
    var client = std.http.Client{ .allocator = allocator };
    try client.ca_bundle.rescan(allocator);
    defer client.deinit();

    // Resolve which binaries to process.
    var bins_to_process = std.StringHashMap(config.Binary).init(allocator);
    defer bins_to_process.deinit();
    var bin_paths = std.ArrayList([]const u8).empty;
    defer bin_paths.deinit(allocator);

    if (args.len > 0) {
        for (args) |a| {
            const bin = try config.getBinPath(allocator, conf, env, a);
            const b = conf.bins.get(bin) orelse {
                std.log.err("binary {s} is not managed by bin", .{bin});
                return error.NotManaged;
            };
            try bins_to_process.put(bin, b);
            try bin_paths.append(allocator, bin);
        }
    } else {
        var it = conf.bins.iterator();
        while (it.next()) |entry| {
            try bins_to_process.put(entry.key_ptr.*, entry.value_ptr.*);
            try bin_paths.append(allocator, entry.key_ptr.*);
        }
    }

    // Excluded binaries.
    var excluded = std.StringHashMap(void).init(allocator);
    defer excluded.deinit();
    for (opts.exclude) |e| {
        const bin = config.getBinPath(allocator, conf, env, e) catch continue;
        try excluded.put(bin, {});
    }

    var to_update = std.ArrayList(struct { info: UpdateInfo, bin: config.Binary, path: []const u8 }).empty;
    defer to_update.deinit(allocator);
    var update_failures = std.ArrayList([]const u8).empty;
    defer update_failures.deinit(allocator);

    for (bin_paths.items) |p| {
        const b = bins_to_process.get(p).?;
        if (excluded.contains(p)) {
            std.log.info("{s} is excluded from updates", .{p});
            continue;
        }
        if (b.pinned) {
            std.log.info("{s} is a pinned binary", .{p});
            continue;
        }
        var provider = providers.Provider.new(allocator, b.url, b.provider) catch |err| {
            if (opts.continue_on_error) {
                try update_failures.append(allocator, try std.fmt.allocPrint(allocator, "Error while creating provider for {s}: {s}", .{ p, @errorName(err) }));
                continue;
            }
            return err;
        };
        std.log.debug("Using provider '{s}' for '{s}'", .{ provider.getID(), b.url });

        const ui = getLatestVersion(allocator, &client, &b, &provider) catch |err| {
            if (opts.continue_on_error) {
                try update_failures.append(allocator, try std.fmt.allocPrint(allocator, "Error while getting latest version of {s}: {s}", .{ p, @errorName(err) }));
                continue;
            }
            return err;
        };
        if (ui) |info| {
            try to_update.append(allocator, .{ .info = info, .bin = b, .path = p });
        }
    }

    if (to_update.items.len == 0 and update_failures.items.len == 0) {
        std.log.info("All binaries are up to date", .{});
        return;
    }

    if (opts.dry_run) {
        std.log.err("Updates found, exit (dry-run mode).", .{});
        return error.DryRunExit;
    }

    if (to_update.items.len > 0 and !opts.yes_to_update) {
        for (update_failures.items) |f| std.log.warn("{s}", .{f});
        update_failures.clearRetainingCapacity();
        try prompt.confirm("Do you want to continue?");
    }

    for (to_update.items) |item| {
        const ui = item.info;
        const b = item.bin;

        var provider = providers.Provider.new(allocator, ui.url, b.provider) catch |err| {
            if (opts.continue_on_error) {
                try update_failures.append(allocator, try std.fmt.allocPrint(allocator, "Error while creating provider for {s}: {s}", .{ ui.url, @errorName(err) }));
                continue;
            }
            return err;
        };
        std.log.debug("Using provider '{s}' for '{s}'", .{ provider.getID(), ui.url });

        const p_result = provider.fetch(allocator, &client, .{
            .all = opts.all,
            .package_name = b.remote_name,
            .package_path = b.package_path,
            .skip_path_check = opts.skip_path_check,
            .previous_asset = b.selected_asset,
            .previous_version = b.version,
        }) catch |err| {
            if (opts.continue_on_error) {
                try update_failures.append(allocator, try std.fmt.allocPrint(allocator, "Error while fetching {s}: {s}", .{ ui.url, @errorName(err) }));
                continue;
            }
            return err;
        };

        const hash = try install_mod.saveToDisk(allocator, env, p_result.data, b.path, true);

        // Note: Pinned is intentionally NOT preserved here (matches the
        // reference implementation).
        try config.upsertBinary(conf, .{
            .path = b.path,
            .remote_name = p_result.name,
            .version = p_result.version,
            .hash = hash,
            .url = ui.url,
            .provider = provider.getID(),
            .package_path = p_result.package_path,
            .selected_asset = p_result.selected_asset,
        });

        const expanded = try config.expandEnv(allocator, b.path, env);
        defer allocator.free(expanded);
        std.log.info("Done updating {s} to {s}", .{ expanded, ui.version });
    }

    for (update_failures.items) |f| std.log.warn("{s}", .{f});
}

/// Mirrors cmd/getLatestVersion: no update when versions are equal or when the
/// current version is a semver >= the latest.
fn getLatestVersion(allocator: std.mem.Allocator, client: *std.http.Client, b: *const config.Binary, p: *providers.Provider) !?UpdateInfo {
    std.log.debug("Checking updates for {s}", .{b.path});
    const latest = try p.getLatestVersion(allocator, client);

    if (std.mem.eql(u8, b.version, latest.version)) return null;

    const b_semver = semver.parse(b.version);
    const v_semver = semver.parse(latest.version);
    if (b_semver != null and v_semver != null) {
        const order = semver.compare(v_semver.?, b_semver.?);
        if (order != .gt) return null;
    }

    std.log.debug("Found new version {s} for {s} at {s}", .{ latest.version, b.path, latest.url });
    std.log.info("{s} {s} -> {s}", .{ b.path, b.version, latest.version });
    return .{ .version = latest.version, .url = latest.url };
}
