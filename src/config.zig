const std = @import("std");

pub const Binary = struct {
    path: []const u8,
    remote_name: []const u8,
    version: []const u8,
    url: []const u8,
    provider: []const u8,
    pinned: bool = false,
};

pub const Config = struct {
    bin_dir: []const u8,
    download_threads: u32 = 4,
    tokens: struct {
        github: []const u8 = "",
        gitlab: []const u8 = "",
        codeberg: []const u8 = "",
    } = .{},
    bins: std.StringHashMap(Binary),
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .bin_dir = "",
            .download_threads = 4,
            .bins = std.StringHashMap(Binary).init(allocator),
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Config) void {
        self.bins.deinit();
        self.arena.deinit();
    }

    // Helper to get or create BIN_CONFIG path
    pub fn getConfigPath(allocator: std.mem.Allocator, env: std.process.Environ, io: std.Io) ![]const u8 {
        if (env.getAlloc(allocator, "BIN_CONFIG")) |path| {
            return path;
        } else |_| {}

        const builtin = @import("builtin");
        const home = env.getAlloc(allocator, "HOME") catch b: {
            if (builtin.os.tag == .windows) {
                break :b try env.getAlloc(allocator, "USERPROFILE");
            }
            return error.HomeNotFound;
        };
        defer allocator.free(home);

        const config_dir = try std.fs.path.join(allocator, &[_][]const u8{ home, ".config" });
        std.Io.Dir.createDirAbsolute(io, config_dir, .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;

        return std.fs.path.join(allocator, &[_][]const u8{ config_dir, "bin.yml" });
    }
};

pub fn load(parent_allocator: std.mem.Allocator, env: std.process.Environ, io: std.Io) !Config {
    var config = Config.init(parent_allocator);
    const allocator = config.arena.allocator();

    const path = try Config.getConfigPath(allocator, env, io);

    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return config,
        else => return err,
    };
    defer file.close(io);

    const file_size = (try file.stat(io)).size;
    if (file_size == 0) return config;

    const buffer = try allocator.alloc(u8, file_size);
    _ = try file.readPositionalAll(io, buffer, 0);

    var it = std.mem.splitScalar(u8, buffer, '\n');
    var current_section: enum { root, tokens, bins, binary } = .root;
    var current_bin_name: []const u8 = "";
    var current_bin = Binary{ .path = "", .remote_name = "", .version = "", .url = "", .provider = "" };

    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        const indent = line.len - std.mem.trimStart(u8, line, " ").len;

        if (std.mem.startsWith(u8, trimmed, "bin_dir:")) {
            config.bin_dir = try allocator.dupe(u8, std.mem.trim(u8, trimmed["bin_dir:".len..], " "));
        } else if (std.mem.startsWith(u8, trimmed, "download_threads:")) {
            const val = std.mem.trim(u8, trimmed["download_threads:".len..], " ");
            config.download_threads = std.fmt.parseInt(u32, val, 10) catch 4;
        } else if (std.mem.startsWith(u8, trimmed, "tokens:")) {
            current_section = .tokens;
        } else if (std.mem.startsWith(u8, trimmed, "bins:")) {
            current_section = .bins;
        } else if (current_section == .tokens and std.mem.indexOf(u8, trimmed, ":") != null) {
            var kv = std.mem.splitScalar(u8, trimmed, ':');
            const k = std.mem.trim(u8, kv.next().?, " ");
            const v = std.mem.trim(u8, kv.rest(), " ");
            if (std.mem.eql(u8, k, "github")) config.tokens.github = try allocator.dupe(u8, v);
            if (std.mem.eql(u8, k, "gitlab")) config.tokens.gitlab = try allocator.dupe(u8, v);
            if (std.mem.eql(u8, k, "codeberg")) config.tokens.codeberg = try allocator.dupe(u8, v);
        } else if (current_section == .bins and indent == 2 and std.mem.endsWith(u8, trimmed, ":")) {
            if (current_bin_name.len > 0) {
                try config.bins.put(current_bin_name, current_bin);
            }
            current_bin_name = try allocator.dupe(u8, trimmed[0 .. trimmed.len - 1]);
            current_bin = Binary{ .path = "", .remote_name = current_bin_name, .version = "", .url = "", .provider = "" };
            current_section = .binary;
        } else if (current_section == .binary and indent >= 4 and std.mem.indexOf(u8, trimmed, ":") != null) {
            var kv = std.mem.splitScalar(u8, trimmed, ':');
            const k = std.mem.trim(u8, kv.next().?, " ");
            const v = std.mem.trim(u8, kv.rest(), " ");
            if (std.mem.eql(u8, k, "path")) current_bin.path = try allocator.dupe(u8, v);
            if (std.mem.eql(u8, k, "version")) current_bin.version = try allocator.dupe(u8, v);
            if (std.mem.eql(u8, k, "url")) current_bin.url = try allocator.dupe(u8, v);
            if (std.mem.eql(u8, k, "provider")) current_bin.provider = try allocator.dupe(u8, v);
            if (std.mem.eql(u8, k, "pinned")) current_bin.pinned = std.mem.eql(u8, v, "true");
        } else if (indent == 2 and current_section == .binary) {
            // New bin record
            if (current_bin_name.len > 0) {
                try config.bins.put(current_bin_name, current_bin);
            }
            current_bin_name = try allocator.dupe(u8, trimmed[0 .. trimmed.len - 1]);
            current_bin = Binary{ .path = "", .remote_name = current_bin_name, .version = "", .url = "", .provider = "" };
        }
    }
    if (current_bin_name.len > 0) {
        try config.bins.put(current_bin_name, current_bin);
    }

    return config;
}

pub fn save(config: *Config, env: std.process.Environ, io: std.Io) !void {
    const allocator = config.arena.allocator();
    const path = try Config.getConfigPath(allocator, env, io);

    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buf);
    const w = &file_writer.interface;

    try w.print("bin_dir: {s}\n", .{config.bin_dir});
    try w.print("download_threads: {d}\n", .{config.download_threads});
    try w.print("tokens:\n", .{});
    try w.print("  github: {s}\n", .{config.tokens.github});
    try w.print("  gitlab: {s}\n", .{config.tokens.gitlab});
    try w.print("  codeberg: {s}\n", .{config.tokens.codeberg});

    try w.writeAll("bins:\n");
    var it = config.bins.iterator();
    while (it.next()) |entry| {
        const bin = entry.value_ptr.*;
        try w.print("  {s}:\n", .{entry.key_ptr.*});
        try w.print("    path: {s}\n", .{bin.path});
        try w.print("    version: {s}\n", .{bin.version});
        try w.print("    url: {s}\n", .{bin.url});
        try w.print("    provider: {s}\n", .{bin.provider});
        try w.print("    pinned: {}\n", .{bin.pinned});
    }
    try file_writer.flush();
}

pub fn validate(conf: *Config, io: std.Io) !void {
    if (conf.bin_dir.len == 0) {
        return error.BinDirRequired;
    }

    // Validate bin_dir exists
    _ = std.Io.Dir.openDirAbsolute(io, conf.bin_dir, .{}) catch |err| {
        std.log.err("bin_dir '{s}' is invalid: {}", .{ conf.bin_dir, err });
        return error.InvalidBinDir;
    };

    // Validate thread count
    if (conf.download_threads == 0 or conf.download_threads > 32) {
        std.log.err("download_threads must be between 1 and 32", .{});
        return error.InvalidThreadCount;
    }

    // Validate binaries
    var it = conf.bins.iterator();
    while (it.next()) |entry| {
        const bin = entry.value_ptr.*;
        if (bin.path.len == 0) return error.BinaryPathRequired;
        if (bin.url.len == 0) return error.BinaryUrlRequired;
        if (bin.version.len == 0) return error.BinaryVersionRequired;
    }
}
