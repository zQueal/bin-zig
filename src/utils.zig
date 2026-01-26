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

pub fn copyFileAbsolute(io: std.Io, src: []const u8, dest: []const u8) !void {
    const src_file = try std.Io.Dir.openFileAbsolute(io, src, .{});
    defer src_file.close(io);
    
    if (std.fs.path.dirname(dest)) |parent| {
        std.Io.Dir.createDirAbsolute(io, parent, .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;
    }

    const dst_file = try std.Io.Dir.createFileAbsolute(io, dest, .{});
    defer dst_file.close(io);
    
    var buffer: [8192]u8 = undefined;
    var src_reader = src_file.reader(io, &buffer);
    var dst_writer = dst_file.writer(io, &buffer);
    
    const size = (try src_file.stat(io)).size;
    try src_reader.interface.streamExact64(&dst_writer.interface, size);
    try dst_writer.flush();
}

pub fn computeSha256(io: std.Io, path: []const u8, out_hex: *[64]u8) !void {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(io, &buffer);
    
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
