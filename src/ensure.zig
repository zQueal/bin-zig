const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const install_mod = @import("install.zig");
const providers = @import("providers.zig");

/// Mirrors cmd/ensure.go: verifies each managed binary, re-installing when it
/// is missing or its SHA-256 hash does not match the stored one.
pub fn ensure(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, args: []const []const u8) !void {
    var client = std.http.Client{ .allocator = allocator };
    try client.ca_bundle.rescan(allocator);
    defer client.deinit();

    var bins_to_process = std.ArrayList(config.Binary).empty;
    defer bins_to_process.deinit(allocator);

    if (args.len > 0) {
        for (args) |a| {
            const bin = try config.getBinPath(allocator, conf, env, a);
            const b = conf.bins.get(bin) orelse {
                std.log.err("binary {s} is not managed by bin", .{bin});
                return error.NotManaged;
            };
            try bins_to_process.append(allocator, b);
        }
    } else {
        var it = conf.bins.iterator();
        while (it.next()) |entry| try bins_to_process.append(allocator, entry.value_ptr.*);
    }

    for (bins_to_process.items) |bin_cfg| {
        const ep = try config.expandEnv(allocator, bin_cfg.path, env);
        defer allocator.free(ep);

        const stat = std.fs.cwd().statFile(ep) catch |err| switch (err) {
            error.FileNotFound => null,
            else => continue, // other stat errors: skip
        };

        if (stat != null) {
            // File exists: verify the hash.
            const actual_hash = try fileHashHex(allocator, ep);
            if (std.mem.eql(u8, actual_hash, bin_cfg.hash)) continue;
            std.log.info("{s} hash does not match with config's, re-installing", .{ep});
        }

        var provider = providers.Provider.new(allocator, bin_cfg.url, bin_cfg.provider) catch |err| {
            std.log.err("error creating provider for {s}: {s}", .{ bin_cfg.path, @errorName(err) });
            return err;
        };
        std.log.debug("Using provider '{s}' for '{s}'", .{ provider.getID(), bin_cfg.url });

        const p_result = provider.fetch(allocator, &client, .{
            .version = bin_cfg.version,
            .package_name = bin_cfg.remote_name,
            .package_path = bin_cfg.package_path,
            .previous_asset = bin_cfg.selected_asset,
            .previous_version = bin_cfg.version,
            .auto_select_previous = true,
        }) catch |err| {
            std.log.err("error fetching {s}: {s}", .{ bin_cfg.url, @errorName(err) });
            return err;
        };

        const hash = try install_mod.saveToDisk(allocator, env, p_result.name, p_result.version, p_result.data, ep, true);

        // Pinned is preserved (unlike update).
        try config.upsertBinary(conf, .{
            .path = bin_cfg.path,
            .remote_name = p_result.name,
            .version = p_result.version,
            .hash = hash,
            .url = bin_cfg.url,
            .provider = provider.getID(),
            .package_path = p_result.package_path,
            .selected_asset = p_result.selected_asset,
            .pinned = bin_cfg.pinned,
        });

        std.log.info("Done ensuring {s} to {s}", .{ ep, cli.green(bin_cfg.version) });
    }
}

fn fileHashHex(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const size = (try file.stat()).size;
    const data = try allocator.alloc(u8, size);
    _ = try file.readAll(data);

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(data);
    var digest: [32]u8 = undefined;
    hash.final(&digest);

    const hex = try allocator.alloc(u8, 64);
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = hex_chars[b >> 4];
        hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
    return hex;
}
