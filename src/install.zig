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
    // Process-lifetime and thread-safe: a stalled attempt can be abandoned while
    // still inside this client (see timeout.zig), so it is never torn down, and
    // its allocator must be safe to use from the attempt threads.
    var client = std.http.Client{ .allocator = std.heap.smp_allocator };
    try client.ca_bundle.rescan(std.heap.smp_allocator);

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

    const hash = try saveToDisk(allocator, env, p_result.name, p_result.version, p_result.data, final_path, opts.force);

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
pub fn saveToDisk(allocator: std.mem.Allocator, env: std.process.EnvMap, name: []const u8, version: []const u8, data: []const u8, path: []const u8, overwrite: bool) ![]const u8 {
    const epath = try config.expandEnv(allocator, path, env);
    const dir = std.fs.path.dirname(epath) orelse ".";
    const base = std.fs.path.basename(epath);
    const sep = std.fs.path.sep;

    const new_path = try std.fmt.allocPrint(allocator, "{s}{c}.{s}.new", .{ dir, sep, base });
    // The file being replaced is moved to this sibling. pickOldPath steps over
    // a ".old" that cannot be removed, which is what keeps a running binary
    // from blocking its own update (see its doc comment).
    const old_path = try pickOldPath(allocator, dir, base);

    std.log.info("Copying for {s}@{s} into {s}", .{ name, version, epath });

    // Write to a temp .new file first to allow atomic replacement. This is
    // required on Windows where in-place writes to running binaries fail.
    //
    // Leftovers from an interrupted run are removed first: the creation mode
    // below only applies when the file is created, so truncating an existing
    // one would keep whatever permissions it already had
    // (marcosnils/bin#313, "fix(install): make installed binaries executable
    // by group and others").
    std.fs.cwd().deleteFile(new_path) catch {};
    const file = try std.fs.cwd().createFile(new_path, .{ .mode = 0o755 });
    file.writeAll(data) catch |err| {
        file.close();
        std.fs.cwd().deleteFile(new_path) catch {};
        return err;
    };
    file.close();

    const hash = try checksumHex(allocator, data);

    // If the target already exists, check the overwrite flag and move it aside.
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

    // Clean up the old file. When the binary that was just replaced is still
    // running, Windows refuses to delete its mapped image: the sibling is left
    // behind and the next install reclaims the name.
    std.fs.cwd().deleteFile(old_path) catch {};

    return hash;
}

/// Picks the sibling `epath` is moved aside to: the plain ".old" when it can be
/// freed, otherwise the first free ".old.<n>".
///
/// Windows denies DeleteFile (and any write) on the mapped image of a running
/// process, so updating a binary that is still running leaves its ".old"
/// sibling behind. Renaming onto that sibling then fails with AccessDenied and
/// aborts the whole update, so it is stepped over instead: the locked sibling
/// keeps its contents, and the first install to run after that process exits
/// deletes it and reuses the name.
fn pickOldPath(allocator: std.mem.Allocator, dir: []const u8, base: []const u8) ![]const u8 {
    const sep = std.fs.path.sep;
    const plain = try std.fmt.allocPrint(allocator, "{s}{c}.{s}.old", .{ dir, sep, base });
    std.fs.cwd().deleteFile(plain) catch {};
    if (!fileExists(plain)) return plain;

    // The plain sibling is held by a process that is still running. Step over
    // it, reclaiming any sibling whose process has exited in the meantime. The
    // set of locked names is finite, so this terminates.
    var n: usize = 1;
    while (true) : (n += 1) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}{c}.{s}.old.{d}", .{ dir, sep, base, n });
        if (!fileExists(candidate)) return candidate;
        if (std.fs.cwd().deleteFile(candidate)) {
            return candidate;
        } else |_| {}
    }
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn writeFileAt(path: []const u8, bytes: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(bytes);
}

fn readFileAt(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return try f.readToEndAlloc(allocator, 4096);
}

/// saveToDisk allocates from the caller's arena in production (see install()),
/// so the tests hand it an arena rather than std.testing.allocator, which
/// would flag every one of those unfreed scratch allocations as a leak.
fn scratchAllocator(arena: *std.heap.ArenaAllocator) std.mem.Allocator {
    return arena.allocator();
}

test "saveToDisk: replaces a target whose .old sibling cannot be removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = scratchAllocator(&arena);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = try tmp_dir.dir.realpathAlloc(allocator, ".");

    const target = try std.fs.path.join(allocator, &[_][]const u8{ dir, "victim.exe" });
    // The siblings are dot-prefixed: saveToDisk names them ".{base}.old" and
    // ".{base}.old.<n>" — the same convention that leaves ".reasonix.exe.old"
    // behind in a real bin directory.
    const blocked = try std.fmt.allocPrint(allocator, "{s}{c}.victim.exe.old", .{ dir, std.fs.path.sep });
    const stepped = try std.fmt.allocPrint(allocator, "{s}{c}.victim.exe.old.1", .{ dir, std.fs.path.sep });

    try writeFileAt(target, "old binary");

    // Windows refuses DeleteFile on the mapped image of a running process, so
    // updating a binary that is still running leaves its ".old" sibling in
    // place. A non-empty directory reproduces that "exists, cannot be removed"
    // state on every platform.
    try std.fs.cwd().makeDir(blocked);
    try writeFileAt(try std.fs.path.join(allocator, &[_][]const u8{ blocked, "keep" }), "");

    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    const hash = try saveToDisk(allocator, env, "victim", "v2", "new binary", target, true);
    try std.testing.expectEqual(@as(usize, 64), hash.len);

    const got = try readFileAt(allocator, target);
    try std.testing.expectEqualStrings("new binary", got);

    // The sibling that could not be removed is left untouched, and the name
    // stepped over for it is cleaned up again.
    try std.testing.expect(fileExists(blocked));
    try std.testing.expect(!fileExists(stepped));
}

test "saveToDisk: reclaims the plain .old sibling when it can be deleted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = scratchAllocator(&arena);

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = try tmp_dir.dir.realpathAlloc(allocator, ".");

    const target = try std.fs.path.join(allocator, &[_][]const u8{ dir, "victim.exe" });
    const plain = try std.fmt.allocPrint(allocator, "{s}{c}.victim.exe.old", .{ dir, std.fs.path.sep });
    const stepped = try std.fmt.allocPrint(allocator, "{s}{c}.victim.exe.old.1", .{ dir, std.fs.path.sep });

    try writeFileAt(target, "old binary");
    try writeFileAt(plain, "leftover from an earlier update");

    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    _ = try saveToDisk(allocator, env, "victim", "v2", "new binary", target, true);

    const got = try readFileAt(allocator, target);
    try std.testing.expectEqualStrings("new binary", got);

    // A deletable sibling is reused rather than numbered, and nothing is left
    // behind.
    try std.testing.expect(!fileExists(plain));
    try std.testing.expect(!fileExists(stepped));
}
