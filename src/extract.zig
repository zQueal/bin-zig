const std = @import("std");
const utils = @import("utils.zig");

pub fn extractArchive(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8, repo_name: []const u8, io: std.Io) ![]const u8 {
    std.log.info("Extracting {s}...", .{ archive_path });
    
    const extraction_dir = try std.fs.path.join(allocator, &[_][]const u8{ std.fs.path.dirname(archive_path) orelse ".", "tmp_extract" });
    std.Io.Dir.createDirAbsolute(io, extraction_dir, .default_dir) catch |err| if (err != error.PathAlreadyExists) return err;

    const archive_file = try std.Io.Dir.openFileAbsolute(io, archive_path, .{});
    defer archive_file.close(io);

    var r_buf: [8192]u8 = undefined;
    var reader = archive_file.reader(io, &r_buf);

    const ext_dir_handle = try std.Io.Dir.openDirAbsolute(io, extraction_dir, .{});
    defer ext_dir_handle.close(io);

    if (std.mem.endsWith(u8, archive_path, ".zip")) {
        try std.zip.extract(ext_dir_handle, &reader, .{ .allow_backslashes = true });
    } else if (std.mem.endsWith(u8, archive_path, ".tar.gz") or std.mem.endsWith(u8, archive_path, ".tgz")) {
        const decompress_buf = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(decompress_buf);
        var decompressor = std.compress.flate.Decompress.init(&reader.interface, .gzip, decompress_buf);
        try std.tar.pipeToFileSystem(io, ext_dir_handle, &decompressor.reader, .{});
    } else if (std.mem.endsWith(u8, archive_path, ".tar.xz")) {
        const xz_buf = try allocator.alloc(u8, 4096); 
        defer allocator.free(xz_buf);
        var decompressor = try std.compress.xz.Decompress.init(&reader.interface, allocator, xz_buf);
        defer decompressor.deinit();
        try std.tar.pipeToFileSystem(io, ext_dir_handle, &decompressor.reader, .{});
    } else if (std.mem.endsWith(u8, archive_path, ".tar.zst") or std.mem.endsWith(u8, archive_path, ".tar.zstd")) {
        const zstd_buf = try allocator.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        defer allocator.free(zstd_buf);
        var decompressor = std.compress.zstd.Decompress.init(&reader.interface, zstd_buf, .{});
        try std.tar.pipeToFileSystem(io, ext_dir_handle, &decompressor.reader, .{});
    } else if (std.mem.endsWith(u8, archive_path, ".tar.lzma")) {
        const lzma_buf = try allocator.alloc(u8, 4096);
        defer allocator.free(lzma_buf);
        var decompressor = try std.compress.lzma.Decompress.initOptions(&reader.interface, allocator, lzma_buf, .{}, 64 * 1024 * 1024);
        defer decompressor.deinit();
        try std.tar.pipeToFileSystem(io, ext_dir_handle, &decompressor.reader, .{});
    } else if (std.mem.endsWith(u8, archive_path, ".tar")) {
        try std.tar.pipeToFileSystem(io, ext_dir_handle, &reader.interface, .{});
    } else {
         // Fallback to shell tar
         const run_result = try std.process.run(allocator, io, .{
            .argv = &[_][]const u8{ "tar", "-xf", archive_path, "-C", extraction_dir },
        });
        if (run_result.term != .exited or run_result.term.exited != 0) {
            std.log.err("tar failed or unknown extension: {s}", .{run_result.stderr});
            return error.TarFailed;
        }
    }

    const best_entry = try findBestBinary(allocator, extraction_dir, repo_name, io);
    if (best_entry == null) return error.NoBinaryInArchive;

    const builtin = @import("builtin");
    const bin_name = if (builtin.os.tag == .windows and !std.mem.endsWith(u8, repo_name, ".exe")) try std.fmt.allocPrint(allocator, "{s}.exe", .{repo_name}) else try allocator.dupe(u8, repo_name);
    const final_path = try std.fs.path.join(allocator, &[_][]const u8{ dest_dir, bin_name });
    
    try utils.copyFileAbsolute(io, best_entry.?, final_path);

    return final_path;
}

fn findBestBinary(allocator: std.mem.Allocator, dir_path: []const u8, repo_name: []const u8, io: std.Io) !?[]const u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var it = dir.iterate();
    var best_file: ?[]const u8 = null;
    var highest_score: i32 = 0;

    const builtin = @import("builtin");

    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            const sub_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
            if (try findBestBinary(allocator, sub_path, repo_name, io)) |found| {
                 return found; 
            }
            continue;
        }

        if (entry.kind == .file) {
            var score: i32 = 0;
            const name = entry.name;
            
            var lower_name_buf: [256]u8 = undefined;
            const actual_len = @min(name.len, 256);
            const lower_name = std.ascii.lowerString(lower_name_buf[0..actual_len], name[0..actual_len]);

            if (std.mem.indexOf(u8, lower_name, repo_name) != null) score += 10;
            if (builtin.os.tag == .windows and std.mem.endsWith(u8, lower_name, ".exe")) score += 5;
            if (std.mem.eql(u8, lower_name, repo_name)) score += 20;

            if (std.mem.startsWith(u8, lower_name, "license") or std.mem.startsWith(u8, lower_name, "readme") or std.mem.endsWith(u8, lower_name, ".md") or std.mem.endsWith(u8, lower_name, ".txt")) {
                score -= 100;
            }

            if (score > highest_score) {
                highest_score = score;
                if (best_file) |f| allocator.free(f);
                best_file = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, name });
            }
        }
    }
    return best_file;
}
