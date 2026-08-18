const std = @import("std");
const assets = @import("assets.zig");
const config = @import("config.zig");
const providers = @import("providers.zig");

pub const InstallOpts = struct {
    force: bool = false,
    all: bool = false,
    provider: []const u8 = "",
    name_pattern: []const u8 = "",
};

/// Installs the binary at `url` into `resolved_path` (a directory or a file
/// path), mirroring cmd/install.go of the reference implementation.
pub fn install(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, url: []const u8, resolved_path: []const u8, opts: InstallOpts) !void {
    var client = std.http.Client{ .allocator = allocator };
    try client.ca_bundle.rescan(allocator);
    defer client.deinit();

    var provider = try providers.Provider.new(allocator, url, opts.provider);
    std.log.debug("Using provider '{s}' for '{s}'", .{ provider.getID(), url });

    const p_result = try provider.fetch(allocator, &client, .{
        .all = opts.all,
        .name_pattern = opts.name_pattern,
    });

    // checkFinalPath: if the target is a directory, join with the sanitized
    // file name; otherwise use it as the file path.
    var final_path = resolved_path;
    if (isDir(final_path)) {
        const file_name = try assets.sanitizeName(allocator, p_result.name, p_result.version);
        final_path = try std.fs.path.join(allocator, &[_][]const u8{ final_path, file_name });
    }

    const hash = try saveToDisk(allocator, env, p_result.data, final_path, opts.force);

    // Convert to absolute path before storing in config.
    const abs_path = try std.fs.path.resolve(allocator, &[_][]const u8{final_path});

    try config.upsertBinary(conf, .{
        .path = abs_path,
        .remote_name = p_result.name,
        .version = p_result.version,
        .hash = hash,
        .url = url,
        .provider = provider.getID(),
        .package_path = p_result.package_path,
        .selected_asset = p_result.selected_asset,
    });

    std.log.info("Done installing {s} {s}", .{ p_result.name, p_result.version });
}

fn isDir(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

/// saveToDisk writes the data atomically via ".new"/".old" siblings and
/// returns the hex SHA-256 of the written bytes (mirrors cmd/saveToDisk).
pub fn saveToDisk(allocator: std.mem.Allocator, env: std.process.EnvMap, data: []const u8, path: []const u8, overwrite: bool) ![]const u8 {
    const epath = try config.expandEnv(allocator, path, env);
    const dir = std.fs.path.dirname(epath) orelse ".";
    const base = std.fs.path.basename(epath);
    const sep = std.fs.path.sep;

    const new_path = try std.fmt.allocPrint(allocator, "{s}{c}.{s}.new", .{ dir, sep, base });
    const old_path = try std.fmt.allocPrint(allocator, "{s}{c}.{s}.old", .{ dir, sep, base });

    std.log.info("Copying for {s} into {s}", .{ base, epath });

    // Write to a temp .new file first to allow atomic replacement. This is
    // required on Windows where in-place writes to running binaries fail.
    const file = try std.fs.cwd().createFile(new_path, .{ .mode = 0o755 });
    file.writeAll(data) catch |err| {
        file.close();
        std.fs.cwd().deleteFile(new_path) catch {};
        return err;
    };
    file.close();

    const hash = try checksumHex(allocator, data);

    // If the target already exists, check the overwrite flag and move it aside.
    std.fs.cwd().deleteFile(old_path) catch {};

    if (std.fs.cwd().statFile(epath)) |_| {
        if (!overwrite) {
            std.fs.cwd().deleteFile(new_path) catch {};
            std.log.err("file {s} already exists, use -f/--force to overwrite", .{epath});
            return error.FileExists;
        }
        std.log.debug("Overwrite flag set, moving {s} to {s}", .{ epath, old_path });
        std.fs.cwd().rename(epath, old_path) catch |err| {
            std.fs.cwd().deleteFile(new_path) catch {};
            return err;
        };
    } else |_| {}

    // Atomically move the new file into place.
    std.fs.cwd().rename(new_path, epath) catch |err| {
        // Attempt rollback if we moved the old file aside.
        std.fs.cwd().rename(old_path, epath) catch |rerr| {
            std.log.debug("Rollback failed, {s} may be missing: {}", .{ epath, rerr });
        };
        return err;
    };

    // Clean up the old file.
    std.fs.cwd().deleteFile(old_path) catch {};

    return hash;
}

fn checksumHex(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
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
