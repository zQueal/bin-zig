const std = @import("std");
const options_mod = @import("options.zig");
const utils = @import("utils.zig");

/// Mirrors the config.Binary struct of the reference Go implementation.
/// JSON field names match exactly so both tools can share a config file.
pub const Binary = struct {
    path: []const u8,
    remote_name: []const u8,
    version: []const u8,
    hash: []const u8 = "",
    url: []const u8,
    provider: []const u8,
    package_path: []const u8 = "",
    selected_asset: []const u8 = "",
    pinned: bool = false,
};

pub const Config = struct {
    default_path: []const u8 = "",
    bins: std.StringHashMap(Binary),
    arena: std.heap.ArenaAllocator,
    /// Resolved path of the config file (cached for save()).
    config_path: []const u8 = "",

    pub fn init(parent_allocator: std.mem.Allocator) Config {
        return Config{
            .bins = std.StringHashMap(Binary).init(parent_allocator),
            .arena = std.heap.ArenaAllocator.init(parent_allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.bins.deinit();
        self.arena.deinit();
    }
};

/// True when the path exists as a file or directory (Windows statFile returns
/// error.IsDir for directories, so this must not rely on statFile alone).
pub fn pathExists(path: []const u8) bool {
    if (isDir(path)) return true;
    const stat = std.fs.cwd().statFile(path) catch return false;
    _ = stat;
    return true;
}

pub fn isDir(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

/// Same resolution strategy as the Go version (pkg/config/config.go:199):
/// 1. honor BIN_CONFIG (error if the file does not exist)
/// 2. legacy "$HOME/.bin/config.json" if present
/// 3. "$XDG_CONFIG_HOME/bin/config.json" if XDG_CONFIG_HOME points to an
///    existing directory
/// 4. "$HOME/.config/bin/config.json" if "$HOME/.config" exists
/// 5. default to "$HOME/.bin/config.json"
pub fn getConfigPath(allocator: std.mem.Allocator, env: std.process.EnvMap) ![]const u8 {
    if (env.get("BIN_CONFIG")) |c| {
        if (c.len > 0) {
            if (std.fs.cwd().statFile(c)) |_| {
                return try allocator.dupe(u8, c);
            } else |err| switch (err) {
                error.FileNotFound => return err,
                else => return try allocator.dupe(u8, c),
            }
        }
    }

    const home = env.get("HOME") orelse env.get("USERPROFILE") orelse return error.HomeNotFound;

    // Legacy location
    const legacy = try std.fs.path.join(allocator, &[_][]const u8{ home, ".bin", "config.json" });
    defer allocator.free(legacy);
    if (pathExists(legacy)) {
        return try allocator.dupe(u8, legacy);
    }

    // XDG_CONFIG_HOME
    if (env.get("XDG_CONFIG_HOME")) |xdg| {
        if (xdg.len > 0 and pathExists(xdg)) {
            return try std.fs.path.join(allocator, &[_][]const u8{ xdg, "bin", "config.json" });
        }
    }

    // $HOME/.config exists?
    const dot_config = try std.fs.path.join(allocator, &[_][]const u8{ home, ".config" });
    defer allocator.free(dot_config);
    if (pathExists(dot_config)) {
        return try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "bin", "config.json" });
    }

    return try std.fs.path.join(allocator, &[_][]const u8{ home, ".bin", "config.json" });
}

/// Loads (and if necessary creates) the configuration, mirroring
/// config.CheckAndLoad() of the Go implementation. If no default download path
/// is configured it is auto-detected from PATH (interactively picked) or
/// prompted for manually, and persisted.
pub fn load(parent_allocator: std.mem.Allocator, env: std.process.EnvMap) !Config {
    var config = Config.init(parent_allocator);
    const allocator = config.arena.allocator();

    const path = try getConfigPath(allocator, env);
    config.config_path = path;

    // Create config directory
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            std.log.err("Error creating config directory [{s}]: {}", .{ dir, err });
            return err;
        };
    }

    std.log.debug("Config directory is: {s}", .{std.fs.path.dirname(path) orelse "."});

    // Open with create: an empty/new file is valid.
    const file = std.fs.cwd().createFile(path, .{ .read = true, .truncate = false }) catch |err| {
        return err;
    };
    defer file.close();

    const size = (try file.stat()).size;
    if (size > 0) {
        const buffer = try allocator.alloc(u8, size);
        _ = try file.preadAll(buffer, 0);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, buffer, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root == .object) {
            if (root.object.get("default_path")) |dp| {
                if (dp == .string and dp.string.len > 0) {
                    config.default_path = try allocator.dupe(u8, dp.string);
                }
            }
            if (root.object.get("bins")) |bins| {
                if (bins == .object) {
                    var it = bins.object.iterator();
                    while (it.next()) |entry| {
                        const key = entry.key_ptr.*;
                        const val = entry.value_ptr.*;
                        if (val != .object) continue;
                        var b = Binary{
                            .path = try allocator.dupe(u8, key),
                            .remote_name = key,
                            .version = "",
                            .url = "",
                            .provider = "",
                        };
                        if (val.object.get("remote_name")) |v| {
                            if (v == .string) b.remote_name = try allocator.dupe(u8, v.string);
                        }
                        if (val.object.get("path")) |v| {
                            if (v == .string and v.string.len > 0) b.path = try allocator.dupe(u8, v.string);
                        }
                        if (val.object.get("version")) |v| {
                            if (v == .string) b.version = try allocator.dupe(u8, v.string);
                        }
                        if (val.object.get("hash")) |v| {
                            if (v == .string) b.hash = try allocator.dupe(u8, v.string);
                        }
                        if (val.object.get("url")) |v| {
                            if (v == .string) b.url = try allocator.dupe(u8, v.string);
                        }
                        if (val.object.get("provider")) |v| {
                            if (v == .string) b.provider = try allocator.dupe(u8, v.string);
                        }
                        if (val.object.get("package_path")) |v| {
                            if (v == .string) b.package_path = try allocator.dupe(u8, v.string);
                        }
                        if (val.object.get("selected_asset")) |v| {
                            if (v == .string) b.selected_asset = try allocator.dupe(u8, v.string);
                        }
                        if (val.object.get("pinned")) |v| {
                            if (v == .bool) b.pinned = v.bool;
                        }
                        try config.bins.put(b.path, b);
                    }
                }
            }
        }
    }

    if (config.default_path.len == 0) {
        config.default_path = try getDefaultPath(allocator, env);
        try save(&config);
    }

    std.log.debug("Download path set to {s}", .{config.default_path});
    return config;
}

/// Saves the config as JSON with 4-space indentation (matching the Go
/// encoder), truncating the file.
pub fn save(config: *Config) !void {
    const allocator = config.arena.allocator();
    const file = std.fs.cwd().createFile(config.config_path, .{}) catch |err| {
        return err;
    };
    defer file.close();

    var buf: [8192]u8 = undefined;
    var file_writer = file.writer(&buf);
    const w = &file_writer.interface;

    var s: std.json.Stringify = .{
        .writer = w,
        .options = .{ .whitespace = .indent_4 },
    };
    try s.beginObject();
    try s.objectField("default_path");
    try s.write(config.default_path);

    // Write bins with keys sorted alphabetically (Go's encoding/json sorts
    // map keys).
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var it = config.bins.iterator();
    while (it.next()) |entry| try keys.append(allocator, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    try s.objectField("bins");
    try s.beginObject();
    for (keys.items) |key| {
        const b = config.bins.get(key).?;
        try s.objectField(key);
        try s.beginObject();
        try s.objectField("path");
        try s.write(b.path);
        try s.objectField("remote_name");
        try s.write(b.remote_name);
        try s.objectField("version");
        try s.write(b.version);
        try s.objectField("hash");
        try s.write(b.hash);
        try s.objectField("url");
        try s.write(b.url);
        try s.objectField("provider");
        try s.write(b.provider);
        try s.objectField("package_path");
        try s.write(b.package_path);
        try s.objectField("selected_asset");
        try s.write(b.selected_asset);
        try s.objectField("pinned");
        try s.write(b.pinned);
        try s.endObject();
    }
    try s.endObject();
    try s.endObject();
    try w.flush();
}

/// UpsertBinary adds or updates a binary resource in the config, keyed by path.
pub fn upsertBinary(config: *Config, b: Binary) !void {
    try config.bins.put(b.path, b);
    try save(config);
}

/// RemoveBinaries removes the specified paths from the configuration.
pub fn removeBinaries(config: *Config, paths: []const []const u8) !void {
    for (paths) |p| {
        _ = config.bins.remove(p);
    }
    try save(config);
}

/// Go os.ExpandEnv semantics: expands $VAR and ${VAR} using the environment.
pub fn expandEnv(allocator: std.mem.Allocator, s: []const u8, env: std.process.EnvMap) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '$') == null) {
        return try allocator.dupe(u8, s);
    }
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '$') {
            try out.append(allocator, s[i]);
            i += 1;
            continue;
        }
        // $VAR or ${VAR}
        if (i + 1 >= s.len) {
            try out.append(allocator, '$');
            break;
        }
        if (s[i + 1] == '{') {
            const end = std.mem.indexOfScalarPos(u8, s, i + 2, '}') orelse {
                // malformed: keep rest as-is
                try out.appendSlice(allocator, s[i..]);
                break;
            };
            const name = s[i + 2 .. end];
            if (env.get(name)) |val| try out.appendSlice(allocator, val);
            i = end + 1;
        } else {
            var j = i + 1;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '_')) : (j += 1) {}
            const name = s[i + 1 .. j];
            if (name.len > 0) {
                if (env.get(name)) |val| try out.appendSlice(allocator, val);
            } else {
                try out.append(allocator, '$');
            }
            i = j;
        }
    }
    return out.toOwnedSlice(allocator);
}

/// getDefaultPath mirrors config_unix.go / config_windows.go: scans PATH for
/// writable directories, dedupes, and interactively asks the user to pick one.
pub fn getDefaultPath(allocator: std.mem.Allocator, env: std.process.EnvMap) ![]const u8 {
    const builtin = @import("builtin");
    const separator: u8 = if (builtin.os.tag == .windows) ';' else ':';

    const path_env = env.get("PATH") orelse return error.NoPathFound;
    std.log.debug("User PATH is [{s}]", .{path_env});

    var opts = std.ArrayList([]const u8).empty;
    defer opts.deinit(allocator);

    var unique = std.StringHashMap(void).init(allocator);
    defer unique.deinit();

    var it = std.mem.splitScalar(u8, path_env, separator);
    while (it.next()) |p| {
        if (p.len == 0) continue;
        checkDirExistsAndWritable(p) catch |err| {
            std.log.debug("Error [{s}] checking path: {}", .{ p, err });
            continue;
        };
        std.log.debug("{s} seems to be a dir and writable, adding option.", .{p});
        if (unique.contains(p)) continue;
        try unique.put(p, {});
        try opts.append(allocator, p);
    }

    if (opts.items.len == 0) {
        return error.NoWritablePath;
    }

    return options_mod.selectCustom("Pick a default download dir: ", opts.items);
}

pub fn checkDirExistsAndWritable(dir: []const u8) !void {
    if (!isDir(dir)) {
        return error.NotDir;
    }
    try checkWritable(dir);
}

fn checkWritable(dir: []const u8) !void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        // Probe by creating and removing a temporary file (Go only checks the
        // owner-write mode bit; probing is more accurate and equivalent for
        // writable directories).
        var probe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const probe = std.fmt.bufPrint(&probe_buf, "{s}{c}.bin_write_test", .{ dir, std.fs.path.sep }) catch return error.NameTooLong;
        const f = std.fs.cwd().createFile(probe, .{}) catch {
            return error.AccessDenied;
        };
        f.close();
        std.fs.cwd().deleteFile(probe) catch {};
        return;
    }
    std.posix.access(dir, std.posix.W_OK) catch {
        return error.AccessDenied;
    };
}

/// Minimal exec.LookPath equivalent: searches PATH (with Windows executable
/// extensions) for `name`. Returns the full path or an error.
pub fn lookPath(allocator: std.mem.Allocator, env: std.process.EnvMap, name: []const u8) ![]const u8 {
    const builtin = @import("builtin");

    if (std.mem.indexOfAny(u8, name, "/\\") != null) {
        // contains a separator: check directly
        if (std.fs.cwd().statFile(name)) |stat| {
            if (stat.kind == .file) return try allocator.dupe(u8, name);
        } else |_| {}
        return error.FileNotFound;
    }

    const path_env = env.get("PATH") orelse return error.FileNotFound;
    const separator: u8 = if (builtin.os.tag == .windows) ';' else ':';

    var it = std.mem.splitScalar(u8, path_env, separator);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const base = try std.fs.path.join(allocator, &[_][]const u8{ dir, name });
        defer allocator.free(base);
        if (fileExecutable(base)) return try allocator.dupe(u8, base);
        if (builtin.os.tag == .windows) {
            for ([_][]const u8{ ".exe", ".cmd", ".bat", ".com" }) |ext| {
                const candidate = try std.fmt.allocPrint(allocator, "{s}{s}", .{ base, ext });
                defer allocator.free(candidate);
                if (fileExecutable(candidate)) return try allocator.dupe(u8, candidate);
            }
        }
    }
    return error.FileNotFound;
}

fn fileExecutable(path: []const u8) bool {
    const stat = std.fs.cwd().statFile(path) catch return false;
    if (stat.kind != .file) return false;
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) return true;
    return stat.mode & 0o111 != 0;
}

/// Mirrors cmd/getBinPath: resolves a binary name via PATH, falling back to a
/// managed binary whose basename matches (when the name has no separator).
pub fn getBinPath(allocator: std.mem.Allocator, conf: *Config, env: std.process.EnvMap, name: []const u8) ![]const u8 {
    const f = lookPath(allocator, env, name) catch |err| {
        std.log.debug("binary {s} not found in PATH: {}", .{ name, err });
        if (std.mem.indexOfScalar(u8, name, '/') == null and std.mem.indexOfScalar(u8, name, '\\') == null) {
            var it = conf.bins.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, std.fs.path.basename(entry.value_ptr.path), name)) {
                    return try allocator.dupe(u8, entry.value_ptr.path);
                }
            }
        }
        return err;
    };
    defer allocator.free(f);

    var it = conf.bins.iterator();
    while (it.next()) |entry| {
        const expanded = try expandEnv(allocator, entry.value_ptr.path, env);
        defer allocator.free(expanded);
        if (std.mem.eql(u8, expanded, f)) {
            return try allocator.dupe(u8, entry.value_ptr.path);
        }
    }
    return error.BinPathNotFound;
}
