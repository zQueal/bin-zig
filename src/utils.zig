const std = @import("std");

pub fn getOsKeywords() []const []const u8 {
    const builtin = @import("builtin");
    const os = builtin.os.tag;
    return switch (os) {
        .windows => &[_][]const u8{ "windows", "win" },
        .linux => &[_][]const u8{ "linux" },
        .macos => &[_][]const u8{ "darwin", "macos", "osx" },
        else => &[_][]const u8{ @tagName(os) },
    };
}

/// Go config.GetOS(): [GOOS] plus "win" on windows.
pub fn getGoOS() []const []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "windows", "win" },
        else => &[_][]const u8{@tagName(builtin.os.tag)},
    };
}

/// Go config.GetArch(): [GOARCH] plus x86_64 and x64 on amd64.
pub fn getGoArch() []const []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.cpu.arch) {
        .x86_64 => &[_][]const u8{ "amd64", "x86_64", "x64" },
        else => &[_][]const u8{@tagName(builtin.cpu.arch)},
    };
}

/// Go config.GetOSSpecificExtensions().
pub fn getGoOsSpecificExtensions() []const []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .linux => &[_][]const u8{"AppImage"},
        .windows => &[_][]const u8{"exe"},
        else => &[_][]const u8{},
    };
}

pub fn getArchKeywords() []const []const u8 {
    const builtin = @import("builtin");
    const arch = builtin.cpu.arch;
    return switch (arch) {
        .x86_64 => &[_][]const u8{ "amd64", "x86_64", "x64" },
        .aarch64 => &[_][]const u8{ "arm64", "aarch64" },
        else => &[_][]const u8{ @tagName(arch) },
    };
}

pub fn getExtensions() []const []const u8 {
    const builtin = @import("builtin");
    const os = builtin.os.tag;
    return switch (os) {
        .windows => &[_][]const u8{ ".exe", ".zip", ".tar.gz", ".tgz" },
        .linux => &[_][]const u8{ ".tar.gz", ".tgz", "", ".zip" }, // Empty string for binary with no extension
        .macos => &[_][]const u8{ ".tar.gz", ".tgz", "", ".zip" },
        else => &[_][]const u8{ ".tar.gz", ".zip" },
    };
}

/// Strips a literal prefix, returning null when the string does not start
/// with it (0.15.2 has no std.mem.trimPrefix).
pub fn stripPrefix(s: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, s, prefix)) return s[prefix.len..];
    return null;
}

pub fn copyFileAbsolute(src: []const u8, dest: []const u8) !void {    const src_file = try std.fs.openFileAbsolute(src, .{});
    defer src_file.close();

    if (std.fs.path.dirname(dest)) |parent| {
        std.fs.cwd().makePath(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const dst_file = try std.fs.createFileAbsolute(dest, .{});
    defer dst_file.close();

    var r_buffer: [8192]u8 = undefined;
    var src_reader = src_file.reader(&r_buffer);
    var w_buffer: [8192]u8 = undefined;
    var dst_writer = dst_file.writer(&w_buffer);

    const size = (try src_file.stat()).size;
    try src_reader.interface.streamExact64(&dst_writer.interface, size);
    try dst_writer.interface.flush();
}

pub fn computeSha256(path: []const u8, out_hex: *[64]u8) !void {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(&buffer);

    while (true) {
        const n = try reader.interface.readSliceShort(&buffer);
        if (n == 0) break;
        hash.update(buffer[0..n]);
    }

    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex_chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out_hex[i * 2] = hex_chars[b >> 4];
        out_hex[i * 2 + 1] = hex_chars[b & 0x0f];
    }
}
