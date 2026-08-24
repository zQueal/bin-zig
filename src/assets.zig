//! Go-parity release-asset pipeline (mirrors bin-python/pkg/assets).
//! Scoring, sanitization, name patterns, preferred-asset re-selection,
//! interactive candidate selection, executable-file filtering inside
//! archives, and package-path matching.

const std = @import("std");
const options_mod = @import("options.zig");
const utils = @import("utils.zig");
const download_mod = @import("download.zig");

pub const Asset = struct {
    name: []const u8,
    display_name: []const u8 = "",
    url: []const u8 = "",
    extra_headers: []const std.http.Header = &.{},
};

pub const FilteredAsset = struct {
    repo_name: []const u8 = "",
    name: []const u8,
    display_name: []const u8 = "",
    url: []const u8 = "",
    score: i32 = 0,
    extra_headers: []const std.http.Header = &.{},
};

pub const FilterOpts = struct {
    skip_scoring: bool = false,
    skip_path_check: bool = false,
    package_name: []const u8 = "",
    package_path: []const u8 = "",
    name_pattern: []const u8 = "",
    preferred_asset: []const u8 = "",
    preferred_version: []const u8 = "",
    current_version: []const u8 = "",
    auto_select_previous: bool = false,
};

pub const ProcessedFile = struct {
    data: []const u8,
    name: []const u8,
    package_path: []const u8 = "",
};

const EntryInfo = struct {
    name: []const u8,
    mode: u32 = 0,
    data: []const u8 = "", // populated for the selected entry only
};

pub const Filter = struct {
    opts: *const FilterOpts,
    repo_name: []const u8 = "",
    name: []const u8 = "",
    package_path: []const u8 = "",
    name_pattern_used: bool = false,
    preferred_used: bool = false,

    pub fn init(opts: *const FilterOpts) Filter {
        return .{ .opts = opts };
    }

    // ------------------------------------------------------------------
    // Asset selection
    // ------------------------------------------------------------------

    pub fn filterAssets(self: *Filter, allocator: std.mem.Allocator, repo_name: []const u8, assets: []const Asset) !FilteredAsset {
        var as = assets;

        // NamePattern filters the top-level asset list (part before the slash).
        if (self.opts.name_pattern.len > 0 and !self.name_pattern_used) {
            as = try self.applyNamePattern(allocator, as);
        }

        // PackageName exact match selects automatically.
        if (self.opts.package_name.len > 0) {
            for (as) |a| {
                if (std.mem.eql(u8, a.name, self.opts.package_name)) {
                    std.log.debug("Asset \"{s}\" matches PackageName exactly, selecting automatically", .{a.name});
                    return .{ .repo_name = repo_name, .name = a.name, .display_name = a.display_name, .url = a.url, .extra_headers = a.extra_headers };
                }
            }
        }

        // PreferredAsset re-selection (same artefact across versions).
        var preferred: []const u8 = "";
        var preferred_asset: ?Asset = null;
        if (self.opts.preferred_asset.len > 0 and !self.preferred_used) {
            self.preferred_used = true;
            preferred = try sanitizeName(allocator, self.opts.preferred_asset, self.opts.preferred_version);
            var pref_matches = std.ArrayList(Asset).empty;
            defer pref_matches.deinit(allocator);
            for (as) |a| {
                const sn = try sanitizeName(allocator, a.name, self.opts.current_version);
                defer allocator.free(sn);
                if (std.mem.eql(u8, sn, preferred)) try pref_matches.append(allocator, a);
            }
            if (pref_matches.items.len == 1) {
                const pa = pref_matches.items[0];
                if (self.opts.auto_select_previous) {
                    std.log.debug("Asset \"{s}\" matches previously selected artefact, selecting automatically", .{pa.name});
                    return .{ .repo_name = repo_name, .name = pa.name, .display_name = pa.display_name, .url = pa.url, .extra_headers = pa.extra_headers };
                }
                std.log.debug("Asset \"{s}\" matches previously selected artefact, offering it as the default", .{pa.name});
                preferred_asset = pa;
            }
        }

        var matches: []FilteredAsset = undefined;
        if (as.len == 1) {
            matches = try allocator.alloc(FilteredAsset, 1);
            matches[0] = .{ .repo_name = repo_name, .name = as[0].name, .display_name = as[0].display_name, .url = as[0].url, .extra_headers = as[0].extra_headers };
        } else if (self.opts.skip_scoring) {
            std.log.debug("--all flag was supplied, skipping scoring", .{});
            matches = try toFilteredAssets(allocator, repo_name, as);
        } else {
            matches = try scoreAssets(allocator, repo_name, as);
        }

        // Make sure the preferred asset is among the prompted options.
        if (preferred_asset) |pa| {
            var found = false;
            for (matches) |m| {
                if (std.mem.eql(u8, m.name, pa.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                const all = try toFilteredAssets(allocator, repo_name, as);
                const extended = try allocator.alloc(FilteredAsset, matches.len + 1);
                @memcpy(extended[0..matches.len], matches);
                extended[matches.len] = .{ .repo_name = repo_name, .name = pa.name, .display_name = pa.display_name, .url = pa.url, .extra_headers = pa.extra_headers };
                allocator.free(matches);
                allocator.free(all);
                matches = extended;
            }
        }

        const all_assets = try toFilteredAssets(allocator, repo_name, as);
        defer allocator.free(all_assets);
        return selectCandidate(allocator, matches, all_assets, preferred, self.opts.current_version);
    }

    fn toFilteredAssets(allocator: std.mem.Allocator, repo_name: []const u8, as: []const Asset) ![]FilteredAsset {
        const out = try allocator.alloc(FilteredAsset, as.len);
        for (as, 0..) |a, i| {
            out[i] = .{ .repo_name = repo_name, .name = a.name, .display_name = a.display_name, .url = a.url, .extra_headers = a.extra_headers };
        }
        return out;
    }

    fn applyNamePattern(self: *Filter, allocator: std.mem.Allocator, as: []const Asset) ![]Asset {
        self.name_pattern_used = true;
        var pattern = self.opts.name_pattern;
        if (std.mem.indexOfScalar(u8, pattern, '/')) |idx| pattern = pattern[0..idx];

        var matches = std.ArrayList(Asset).empty;
        defer matches.deinit(allocator);
        for (as) |a| {
            if (globMatch(pattern, a.name)) try matches.append(allocator, a);
        }
        if (matches.items.len == 0) {
            std.log.err("no assets matching pattern \"{s}\"", .{pattern});
            return error.NoAssetsMatchingPattern;
        }
        return try allocator.dupe(Asset, matches.items);
    }

    fn scoreAssets(allocator: std.mem.Allocator, repo_name: []const u8, as: []const Asset) ![]FilteredAsset {
        // score map: repoName -> 1, each OS -> 10, each arch -> 5, OS-specific ext -> 15
        var keys = std.ArrayList(ScoreKey).empty;
        defer keys.deinit(allocator);
        try keys.append(allocator, .{ .key = repo_name, .score = 1 });
        for (utils.getGoOS()) |os| try keys.append(allocator, .{ .key = os, .score = 10 });
        for (utils.getGoArch()) |arch| try keys.append(allocator, .{ .key = arch, .score = 5 });
        for (utils.getGoOsSpecificExtensions()) |ext| try keys.append(allocator, .{ .key = ext, .score = 15 });

        var matches = std.ArrayList(FilteredAsset).empty;
        defer matches.deinit(allocator);
        for (as) |a| {
            const s = scoreAsset(a.name, keys.items);
            if (s > 0) {
                try matches.append(allocator, .{ .repo_name = repo_name, .name = a.name, .display_name = a.display_name, .url = a.url, .extra_headers = a.extra_headers, .score = s });
            }
        }
        return keepHighestScored(allocator, matches.items);
    }

    fn scoreAsset(name: []const u8, keys: []const ScoreKey) i32 {
        const lower_name = std.ascii.lowerString;
        _ = lower_name;
        var buf: [1024]u8 = undefined;
        const n = @min(name.len, buf.len);
        const ln = std.ascii.lowerString(buf[0..n], name[0..n]);

        // Gate: must contain at least one keyword and have a supported extension.
        var any_match = false;
        for (keys) |k| {
            if (std.mem.indexOf(u8, ln, k.key) != null) {
                any_match = true;
                break;
            }
        }
        if (!any_match or !isSupportedExt(name)) return 0;

        var total: i32 = 0;
        for (keys) |k| {
            if (std.mem.indexOf(u8, ln, k.key) != null) {
                std.log.debug("Candidate {s} contains {s}. Adding score {d}", .{ name, k.key, k.score });
                total += k.score;
            }
        }
        return total;
    }

    fn keepHighestScored(allocator: std.mem.Allocator, matches: []FilteredAsset) ![]FilteredAsset {
        var highest: i32 = 0;
        for (matches) |m| {
            if (m.score > highest) highest = m.score;
        }
        var out = std.ArrayList(FilteredAsset).empty;
        defer out.deinit(allocator);
        for (matches) |m| {
            if (m.score >= highest) {
                std.log.debug("Keeping {s} (URL {s}) with highest score {d}", .{ m.name, m.url, m.score });
                try out.append(allocator, m);
            } else {
                std.log.debug("Removing {s} (URL {s}) with score {d} lower than {d}", .{ m.name, m.url, m.score, highest });
            }
        }
        return out.toOwnedSlice(allocator);
    }

    // ------------------------------------------------------------------
    // Download + processing
    // ------------------------------------------------------------------

    pub fn processURL(self: *Filter, allocator: std.mem.Allocator, client: *std.http.Client, gf: FilteredAsset) !ProcessedFile {
        self.name = gf.name;
        std.log.debug("Checking binary from {s}", .{gf.url});
        std.log.info("Starting download of {s}", .{gf.url});
        const data = try download_mod.downloadToMemory(allocator, client, gf.url, gf.extra_headers);
        return self.processBytes(allocator, data);
    }

    /// processBytes mirrors processReader: sniffs the content type and
    /// recursively unpacks until a final executable file is found.
    pub fn processBytes(self: *Filter, allocator: std.mem.Allocator, data: []const u8) !ProcessedFile {
        const t = sniffType(data);
        var out: ?ProcessedFile = null;
        switch (t) {
            .gz => {
                const out_file = try self.processGz(allocator, data);
                out = try self.processBytes(allocator, out_file.data);
            },
            .xz => {
                const out_file = try self.processXz(allocator, data);
                out = try self.processBytes(allocator, out_file.data);
            },
            .bz2 => {
                const out_file = try self.processBz2(allocator, data);
                out = try self.processBytes(allocator, out_file.data);
            },
            .tar => {
                out = try self.processTar(allocator, data);
            },
            .zip => {
                out = try self.processZip(allocator, data);
            },
            .none => {
                out = .{ .data = data, .name = self.name };
            },
        }
        if (out) |o| {
            self.name = o.name;
            self.package_path = o.package_path;
        }
        return out orelse error.NoFile;
    }

    fn processGz(self: *Filter, allocator: std.mem.Allocator, data: []const u8) !ProcessedFile {
        var in = std.Io.Reader.fixed(data);
        // Direct mode (empty buffer): flate streams output straight into the
        // destination writer. The stdlib's internal-buffer path panics with
        // "reached unreachable code" on deflate streams containing stored
        // blocks (its internal writer has no rebase). The Allocating writer
        // grows on demand and implements rebase, so this is always safe.
        var decompress = std.compress.flate.Decompress.init(&in, .gzip, &.{});
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        var total: u64 = 0;
        while (true) {
            const remaining = max_processed_bytes -| total;
            if (remaining == 0) return error.StreamTooLong;
            const n = decompress.reader.stream(&out.writer, .limited(remaining)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.ReadFailed => return error.ReadFailed,
                error.WriteFailed => return error.WriteFailed,
            };
            total += n;
        }
        return .{ .data = try out.toOwnedSlice(), .name = self.name };
    }

    fn processXz(self: *Filter, allocator: std.mem.Allocator, data: []const u8) !ProcessedFile {
        var in = std.Io.Reader.fixed(data);
        const old = in.adaptToOldInterface();
        var decompressor = try std.compress.xz.decompress(allocator, old);
        defer decompressor.deinit();
        const out = try decompressor.reader().readAllAlloc(allocator, max_processed_bytes);
        return .{ .data = out, .name = self.name };
    }

    fn processBz2(self: *Filter, allocator: std.mem.Allocator, data: []const u8) !ProcessedFile {
        // std.compress has no bzip2 in 0.15.2; fall back to the shell. The
        // input file is created exclusively so a pre-existing symlink cannot
        // redirect the write.
        const in_path = try std.fmt.allocPrint(allocator, ".bin_bz2_in_{d}", .{std.time.nanoTimestamp()});
        defer allocator.free(in_path);

        const in_file = std.fs.cwd().createFile(in_path, .{ .exclusive = true }) catch {
            return error.TempFileConflict;
        };
        defer in_file.close();
        defer std.fs.cwd().deleteFile(in_path) catch {};
        try in_file.writeAll(data);

        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "bzip2", "-dc", in_path },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.log.err("bzip2 decompression failed: {s}", .{result.stderr});
            return error.Bzip2Failed;
        }
        return .{ .data = try allocator.dupe(u8, result.stdout), .name = self.name };
    }

    fn processTar(self: *Filter, allocator: std.mem.Allocator, data: []const u8) !ProcessedFile {
        var entries = std.ArrayList(EntryInfo).empty;
        defer entries.deinit(allocator);

        {
            var reader = std.Io.Reader.fixed(data);
            var name_buf: [std.fs.max_path_bytes]u8 = undefined;
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            var it = std.tar.Iterator.init(&reader, .{
                .file_name_buffer = &name_buf,
                .link_name_buffer = &link_buf,
            });
            while (try it.next()) |file| {
                if (file.kind == .directory) continue;
                if (file.kind != .file) continue;
                if (!self.opts.skip_path_check and self.opts.package_path.len > 0 and !self.packagePathMatches(allocator, file.name)) continue;
                try entries.append(allocator, .{ .name = try allocator.dupe(u8, file.name), .mode = file.mode });
            }
        }

        const chosen = try self.selectArchiveEntry(allocator, entries.items);
        if (chosen == null) {
            std.log.err("no files found in tar archive, use -p flag to manually select . PackagePath [{s}]", .{self.opts.package_path});
            return error.NoFilesInArchive;
        }
        const chosen_name = chosen.?;

        // Second pass to read the chosen entry's bytes.
        var out: []const u8 = "";
        {
            var reader = std.Io.Reader.fixed(data);
            var name_buf: [std.fs.max_path_bytes]u8 = undefined;
            var link_buf: [std.fs.max_path_bytes]u8 = undefined;
            var it = std.tar.Iterator.init(&reader, .{
                .file_name_buffer = &name_buf,
                .link_name_buffer = &link_buf,
            });
            while (try it.next()) |file| {
                if (file.kind != .file) continue;
                if (!std.mem.eql(u8, file.name, chosen_name)) continue;
                var w: std.io.Writer.Allocating = .init(allocator);
                defer w.deinit();
                try it.streamRemaining(file, &w.writer);
                out = try allocator.dupe(u8, w.written());
                break;
            }
        }

        return .{
            .data = out,
            .name = std.fs.path.basename(chosen_name),
            .package_path = chosen_name,
        };
    }

    fn processZip(self: *Filter, allocator: std.mem.Allocator, data: []const u8) !ProcessedFile {
        // Work in a uniquely named private directory so std.zip (file-based)
        // can read the archive. The directory is created exclusively, so a
        // pre-created symlink cannot redirect the extraction target.
        var work_dir: []const u8 = "";
        var attempt: usize = 0;
        while (attempt < 8) : (attempt += 1) {
            const candidate = try std.fmt.allocPrint(allocator, ".bin_zip_{d}_{d}", .{ std.time.nanoTimestamp(), attempt });
            if (std.fs.cwd().makeDir(candidate)) |_| {
                work_dir = candidate;
                break;
            } else |_| {}
            allocator.free(candidate);
        }
        if (work_dir.len == 0) return error.TempDirConflict;
        defer deleteDirRecursive(work_dir) catch {};

        const zip_path = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, "archive.zip" });
        defer allocator.free(zip_path);
        const out_dir = try std.fs.path.join(allocator, &[_][]const u8{ work_dir, "out" });
        defer allocator.free(out_dir);
        std.fs.cwd().makeDir(out_dir) catch {};

        const f = try std.fs.cwd().createFile(zip_path, .{});
        try f.writeAll(data);
        f.close();

        var out_dir_handle = try std.fs.cwd().openDir(out_dir, .{});
        defer out_dir_handle.close();

        var zip_file = try std.fs.cwd().openFile(zip_path, .{});
        defer zip_file.close();
        var r_buf: [8192]u8 = undefined;
        var reader = zip_file.reader(&r_buf);
        // Custom extraction: std.zip.extract uses a flate buffer of exactly
        // max_window_len, which panics with "reached unreachable code" on
        // deflate streams that contain stored blocks (the 0.15.2 flate
        // internal writer has no rebase). A large staging buffer makes the
        // rebase path unreachable for any realistic block size.
        try extractZipToDir(allocator, &reader, out_dir_handle);

        // Walk the extracted tree collecting relative paths and modes.
        var entries = std.ArrayList(EntryInfo).empty;
        defer entries.deinit(allocator);
        try collectZipEntries(allocator, out_dir, "", &entries);

        const chosen = try self.selectArchiveEntry(allocator, entries.items);
        if (chosen == null) {
            std.log.err("No files found in zip archive. PackagePath [{s}]", .{self.opts.package_path});
            return error.NoFilesInArchive;
        }
        const chosen_name = chosen.?;

        const full_path = try std.fs.path.join(allocator, &[_][]const u8{ out_dir, chosen_name });
        defer allocator.free(full_path);
        const chosen_file = try std.fs.cwd().openFile(full_path, .{});
        defer chosen_file.close();
        const size = (try chosen_file.stat()).size;
        const out = try allocator.alloc(u8, size);
        _ = try chosen_file.readAll(out);

        return .{
            .data = out,
            .name = std.fs.path.basename(chosen_name),
            .package_path = chosen_name,
        };
    }

    /// selectArchiveEntry applies the executable filter, name-pattern file
    /// filter and asset scoring to the archive entries, returning the chosen
    /// entry name (or null when there are no candidates).
    fn selectArchiveEntry(self: *Filter, allocator: std.mem.Allocator, entries: []const EntryInfo) !?[]const u8 {
        var exec_files = std.ArrayList(EntryInfo).empty;
        defer exec_files.deinit(allocator);

        for (entries) |e| {
            if (e.mode & 0o111 != 0) try exec_files.append(allocator, e);
        }

        var candidates = entries;
        if (exec_files.items.len > 0) {
            std.log.debug("Filtering tar candidates to {d} executable file(s)", .{exec_files.items.len});
            candidates = exec_files.items;
        } else {
            std.log.debug("No executable files found in tar archive, considering all files", .{});
        }

        if (candidates.len == 0) return null;

        var filtered = candidates;
        var filtered_buf = std.ArrayList(EntryInfo).empty;
        defer filtered_buf.deinit(allocator);
        if (std.mem.indexOfScalar(u8, self.opts.name_pattern, '/')) |slash| {
            const file_pattern = self.opts.name_pattern[slash + 1 ..];
            for (candidates) |e| {
                if (globMatch(file_pattern, e.name) or globMatch(file_pattern, std.fs.path.basename(e.name))) {
                    try filtered_buf.append(allocator, e);
                }
            }
            if (filtered_buf.items.len == 0) {
                std.log.err("no files in archive matching pattern \"{s}\"", .{file_pattern});
                return error.NoFilesMatchingPattern;
            }
            // NOTE: filtered_buf outlives the block; keep it in function scope
            // so `filtered` never points into freed memory.
            filtered = filtered_buf.items;
        }

        var asset_list = std.ArrayList(Asset).empty;
        defer asset_list.deinit(allocator);
        for (filtered) |e| try asset_list.append(allocator, .{ .name = e.name });

        const picked = try self.filterAssets(allocator, self.repo_name, asset_list.items);
        return picked.name;
    }

    fn packagePathMatches(self: *Filter, allocator: std.mem.Allocator, entry_name: []const u8) bool {
        if (std.mem.eql(u8, entry_name, self.opts.package_path)) return true;
        const a = sanitizeName(allocator, entry_name, self.opts.current_version) catch return false;
        defer allocator.free(a);
        const b = sanitizeName(allocator, self.opts.package_path, self.opts.preferred_version) catch return false;
        defer allocator.free(b);
        return std.mem.eql(u8, a, b);
    }
};

const max_processed_bytes = 2 * 1024 * 1024 * 1024; // 2GB decompressed

/// Destination buffer for zip entry decompression in flate direct mode. Must
/// be at least flate.history_len + the preserved window so the writer's
/// defaultRebase (drain) can always satisfy the flate writer requests.
const zip_dest_buffer_size = 256 * 1024;

/// Extracts a zip archive, mirroring std.zip.extract but avoiding the 0.15.2
/// flate "reached unreachable code" panic: deflate entries are decompressed
/// in flate direct mode straight into the destination writer, which has a
/// working (drain/grow) rebase. std.zip's fixed max_window_len internal
/// buffer instead panics on deflate streams containing stored blocks.
fn extractZipToDir(allocator: std.mem.Allocator, stream: *std.fs.File.Reader, dest: std.fs.Dir) !void {
    const dest_buf = try allocator.alloc(u8, zip_dest_buffer_size);
    defer allocator.free(dest_buf);
    var iter = try std.zip.Iterator.init(stream);

    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (try iter.next()) |entry| {
        try extractZipEntry(stream, entry, &filename_buf, dest, dest_buf);
    }
}

fn extractZipEntry(stream: *std.fs.File.Reader, entry: std.zip.Iterator.Entry, filename_buf: []u8, dest: std.fs.Dir, dest_buf: []u8) !void {
    if (filename_buf.len < entry.filename_len) return error.ZipInsufficientBuffer;
    switch (entry.compression_method) {
        .store, .deflate => {},
        else => return error.UnsupportedCompressionMethod,
    }

    // Read the filename from the central directory record.
    try stream.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
    stream.interface.readSliceAll(filename_buf[0..entry.filename_len]) catch |err| switch (err) {
        error.ReadFailed => return stream.err.?,
        error.EndOfStream => return error.EndOfStream,
    };

    // Read the local file header to locate the compressed data.
    try stream.seekTo(entry.file_offset);
    const local = stream.interface.takeStruct(std.zip.LocalFileHeader, .little) catch |err| switch (err) {
        error.ReadFailed => return stream.err.?,
        error.EndOfStream => return error.EndOfStream,
    };
    if (!std.mem.eql(u8, &local.signature, &std.zip.local_file_header_sig)) return error.ZipInvalid;

    const data_offset = entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local.filename_len + local.extra_len;
    try stream.seekTo(data_offset);

    var filename = filename_buf[0..entry.filename_len];
    std.mem.replaceScalar(u8, filename, '\\', '/');
    if (isBadZipFilename(filename)) return error.ZipBadFilename;

    // Entries ending in '/' are directories.
    if (filename[filename.len - 1] == '/') {
        if (entry.uncompressed_size != 0) return error.ZipBadDirectorySize;
        try dest.makePath(filename[0 .. filename.len - 1]);
        return;
    }

    const out_file = blk: {
        if (std.fs.path.dirname(filename)) |dirname| {
            var parent_dir = try dest.makeOpenPath(dirname, .{});
            defer parent_dir.close();
            break :blk try parent_dir.createFile(std.fs.path.basename(filename), .{ .exclusive = true });
        }
        break :blk try dest.createFile(filename, .{ .exclusive = true });
    };
    defer out_file.close();
    var file_writer = out_file.writer(dest_buf);

    switch (entry.compression_method) {
        .store => {
            stream.interface.streamExact64(&file_writer.interface, entry.uncompressed_size) catch |err| switch (err) {
                error.ReadFailed => return stream.err.?,
                error.WriteFailed => return file_writer.err.?,
                error.EndOfStream => return error.ZipDecompressTruncated,
            };
        },
        .deflate => {
            // Direct mode (empty flate buffer): output streams straight into
            // the destination writer, whose defaultRebase drains to disk when
            // the buffer fills. The stdlib's indirect path panics (unreachable
            // rebase) on deflate streams with stored blocks.
            var decompress: std.compress.flate.Decompress = .init(&stream.interface, .raw, &.{});
            decompress.reader.streamExact64(&file_writer.interface, entry.uncompressed_size) catch |err| switch (err) {
                error.ReadFailed => return stream.err.?,
                error.WriteFailed => return file_writer.err orelse decompress.err.?,
                error.EndOfStream => return error.ZipDecompressTruncated,
            };
        },
        else => unreachable,
    }
    try file_writer.end();
}

fn isBadZipFilename(filename: []const u8) bool {
    if (filename.len == 0 or filename[0] == '/') return true;
    var it = std.mem.splitScalar(u8, filename, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

fn collectZipEntries(allocator: std.mem.Allocator, dir: []const u8, prefix: []const u8, out: *std.ArrayList(EntryInfo)) !void {
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |entry| {
        const rel = if (prefix.len == 0) try allocator.dupe(u8, entry.name) else try std.fs.path.join(allocator, &[_][]const u8{ prefix, entry.name });
        defer allocator.free(rel);
        if (entry.kind == .directory) {
            const sub = try std.fs.path.join(allocator, &[_][]const u8{ dir, entry.name });
            defer allocator.free(sub);
            try collectZipEntries(allocator, sub, rel, out);
        } else {
            var mode: u32 = 0;
            if (d.statFile(entry.name)) |stat| {
                mode = @intCast(stat.mode & 0o777);
            } else |_| {}
            try out.append(allocator, .{ .name = try allocator.dupe(u8, rel), .mode = mode });
        }
    }
}

fn deleteDirRecursive(path: []const u8) !void {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .directory) {
            try deleteDirRecursive(try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ path, entry.name }));
        } else {
            std.fs.cwd().deleteFile(try std.fs.path.join(std.heap.page_allocator, &[_][]const u8{ path, entry.name })) catch {};
        }
    }
    std.fs.cwd().deleteDir(path) catch {};
}

// ---------------------------------------------------------------------------
// selectCandidate / defaultIndex
// ---------------------------------------------------------------------------

fn selectCandidate(allocator: std.mem.Allocator, matches: []FilteredAsset, all_assets: []FilteredAsset, preferred: []const u8, version: []const u8) !FilteredAsset {
    if (matches.len == 0) {
        std.log.err("Could not find any compatible files", .{});
        return error.NoCompatibleFiles;
    }
    if (matches.len == 1) return matches[0];

    const generic = try displaySorted(allocator, matches);
    defer allocator.free(generic);

    var opts = std.ArrayList([]const u8).empty;
    defer opts.deinit(allocator);
    for (generic) |m| try opts.append(allocator, m.name);
    if (all_assets.len > matches.len) {
        try opts.append(allocator, "Show all");
    }

    const msg = try std.fmt.allocPrint(allocator, "Showing {d} assets out of {d}. Select an option ", .{ matches.len, all_assets.len });
    defer allocator.free(msg);

    const choice = try options_mod.selectWithDefault(msg, opts.items, defaultIndex(matches, preferred, version));
    if (std.mem.eql(u8, choice, "Show all")) {
        const all_generic = try displaySorted(allocator, all_assets);
        defer allocator.free(all_generic);
        var all_opts = std.ArrayList([]const u8).empty;
        defer all_opts.deinit(allocator);
        for (all_generic) |m| try all_opts.append(allocator, m.name);
        const choice2 = try options_mod.selectWithDefault("Select from all available assets:", all_opts.items, defaultIndex(all_assets, preferred, version));
        for (all_assets) |a| {
            if (std.mem.eql(u8, a.name, choice2)) return a;
        }
        return error.InvalidChoice;
    }
    for (matches) |m| {
        if (std.mem.eql(u8, m.name, choice)) return m;
    }
    return error.InvalidChoice;
}

fn defaultIndex(opts: []FilteredAsset, preferred: []const u8, version: []const u8) ?usize {
    if (preferred.len == 0) return null;
    for (opts, 0..) |fa, i| {
        const sn = sanitizeName(std.heap.page_allocator, fa.name, version) catch continue;
        if (std.mem.eql(u8, sn, preferred)) return i;
    }
    return null;
}

fn displaySorted(allocator: std.mem.Allocator, items: []FilteredAsset) ![]FilteredAsset {
    const out = try allocator.dupe(FilteredAsset, items);
    std.mem.sort(FilteredAsset, out, {}, struct {
        fn lessThan(_: void, a: FilteredAsset, b: FilteredAsset) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return out;
}

// ---------------------------------------------------------------------------
// SanitizeName
// ---------------------------------------------------------------------------

const Rep = struct { from: []const u8, to: []const u8 };
const ScoreKey = struct { key: []const u8, score: i32 };

/// SanitizeName removes irrelevant information (os/arch/version tokens) from a
/// file name, mirroring assets.SanitizeName (including its replacement order).
pub fn sanitizeName(allocator: std.mem.Allocator, name: []const u8, version: []const u8) ![]const u8 {
    var buf: [1024]u8 = undefined;
    const n = @min(name.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], name[0..n]);

    var reps = std.ArrayList(Rep).empty;
    defer reps.deinit(allocator);

    var first_pass = true;
    for (utils.getGoOS()) |os| {
        for (utils.getGoArch()) |arch| {
            var from_buf: [256]u8 = undefined;
            const joined = std.fmt.bufPrint(&from_buf, "{s}{s}", .{ os, arch }) catch return error.NameTooLong;
            try addRep(&reps, allocator, "_", joined);
            try addRep(&reps, allocator, "-", joined);
            try addRep(&reps, allocator, ".", joined);
            if (first_pass) {
                try addRep(&reps, allocator, "_", arch);
                try addRep(&reps, allocator, "-", arch);
                try addRep(&reps, allocator, ".", arch);
            }
        }
        try addRep(&reps, allocator, "_", os);
        try addRep(&reps, allocator, "-", os);
        try addRep(&reps, allocator, ".", os);
        first_pass = false;
    }

    try addRep(&reps, allocator, "_", version);
    try addRep(&reps, allocator, "_", utils.stripPrefix(version, "v") orelse version);
    try addRep(&reps, allocator, "-", version);
    try addRep(&reps, allocator, "-", utils.stripPrefix(version, "v") orelse version);

    // strings.NewReplacer semantics: scan left to right, first match wins,
    // replacements do not overlap.
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    defer {
        // The replacement strings are owned; free them (no-op on arenas).
        for (reps.items) |r| allocator.free(r.from);
    }
    var i: usize = 0;
    while (i < lower.len) {
        var matched = false;
        for (reps.items) |r| {
            if (r.from.len > 0 and std.mem.startsWith(u8, lower[i..], r.from)) {
                try out.appendSlice(allocator, r.to);
                i += r.from.len;
                matched = true;
                break;
            }
        }
        if (!matched) {
            try out.append(allocator, lower[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

fn addRep(reps: *std.ArrayList(Rep), allocator: std.mem.Allocator, prefix: []const u8, token: []const u8) !void {
    if (token.len == 0) return;
    const from = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, token });
    try reps.append(allocator, .{ .from = from, .to = "" });
}

// ---------------------------------------------------------------------------
// Extension / glob helpers
// ---------------------------------------------------------------------------

const non_binary_exts = [_][]const u8{ "txt", "sha256", "sha512", "sha1", "md5", "b3", "sum", "sig", "pem", "json", "yaml", "yml", "sbom", "msi", "deb", "rpm", "asc" };
const allowed_exts = [_][]const u8{ "gz", "zip", "xz", "tar", "bz2", "exe" };

pub fn isSupportedExt(filename: []const u8) bool {
    const ext = std.fs.path.extension(filename);
    if (ext.len <= 1) return true; // empty extension is allowed
    var buf: [64]u8 = undefined;
    const n = @min(ext.len - 1, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], ext[1 .. 1 + n]);

    for (non_binary_exts) |e| {
        if (std.mem.eql(u8, lower, e)) return false;
    }
    for (allowed_exts) |e| {
        if (std.mem.eql(u8, lower, e)) return true;
    }
    // Unknown extension: treated like filetype.GetType returning Unknown, which is allowed.
    return true;
}

const FileType = enum { none, gz, xz, bz2, tar, zip };

fn sniffType(data: []const u8) FileType {
    if (data.len >= 2 and data[0] == 0x1f and data[1] == 0x8b) return .gz;
    if (data.len >= 6 and std.mem.eql(u8, data[0..6], &.{ 0xfd, '7', 'z', 'X', 'Z', 0x00 })) return .xz;
    if (data.len >= 3 and data[0] == 'B' and data[1] == 'Z' and data[2] == 'h') return .bz2;
    if (data.len >= 4 and data[0] == 'P' and data[1] == 'K' and data[2] == 0x03 and data[3] == 0x04) return .zip;
    if (data.len >= 262 and std.mem.indexOf(u8, data[257..262], "ustar") != null) return .tar;
    if (data.len >= 265 and std.mem.indexOf(u8, data[257..265], "ustar") != null) return .tar;
    return .none;
}

/// Minimal Go filepath.Match-compatible glob: supports *, ? and [class].
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    return globMatchInner(pattern, name);
}

fn globMatchInner(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    while (p < pattern.len) {
        switch (pattern[p]) {
            '*' => {
                // collapse consecutive stars
                while (p < pattern.len and pattern[p] == '*') : (p += 1) {}
                if (p == pattern.len) return true;
                var i = n;
                while (i <= name.len) : (i += 1) {
                    if (globMatchInner(pattern[p..], name[i..])) return true;
                }
                return false;
            },
            '?' => {
                if (n >= name.len) return false;
                p += 1;
                n += 1;
            },
            '[' => {
                if (n >= name.len) return false;
                const matched = matchClass(pattern, p, name[n]) catch return false;
                if (!matched) return false;
                p = matchClassEnd(pattern, p);
                n += 1;
            },
            else => {
                if (n >= name.len or pattern[p] != name[n]) return false;
                p += 1;
                n += 1;
            },
        }
    }
    return n == name.len;
}

fn matchClass(pattern: []const u8, start: usize, c: u8) !bool {
    var i = start + 1;
    var negate = false;
    if (i < pattern.len and (pattern[i] == '^' or pattern[i] == '!')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pattern.len and pattern[i] != ']') {
        if (i + 2 < pattern.len and pattern[i + 1] == '-' and pattern[i + 2] != ']') {
            if (c >= pattern[i] and c <= pattern[i + 2]) matched = true;
            i += 3;
        } else {
            if (pattern[i] == c) matched = true;
            i += 1;
        }
        first = false;
    }
    if (first) return error.InvalidPattern;
    return if (negate) !matched else matched;
}

fn matchClassEnd(pattern: []const u8, start: usize) usize {
    var i = start + 1;
    if (i < pattern.len and (pattern[i] == '^' or pattern[i] == '!')) i += 1;
    while (i < pattern.len and pattern[i] != ']') : (i += 1) {}
    return @min(i + 1, pattern.len);
}

const testing = std.testing;

test "assets: sanitizeName strips arch tokens (platform-independent)" {
    const allocator = testing.allocator;
    // "amd64"/"x64" appear in the arch keyword list on every platform.
    const out = try sanitizeName(allocator, "bin_amd64", "v0.0.1");
    defer allocator.free(out);
    try testing.expectEqualStrings("bin", out);
}

test "assets: sanitizeName keeps extensions" {
    const allocator = testing.allocator;
    const out = try sanitizeName(allocator, "launchpad-x64.exe", "v1.0.0");
    defer allocator.free(out);
    try testing.expectEqualStrings("launchpad.exe", out);
}

test "assets: sanitizeName strips version with and without v" {
    const allocator = testing.allocator;
    const out = try sanitizeName(allocator, "mytool-v1.2.3-amd64", "v1.2.3");
    defer allocator.free(out);
    try testing.expectEqualStrings("mytool", out);
}

test "assets: sanitizeName is platform-scoped like the reference" {
    const allocator = testing.allocator;
    // On a Windows build the "linux" keyword is not in the OS list, so the
    // "-linux" token survives — exactly like the Go implementation.
    const builtin = @import("builtin");
    const out = try sanitizeName(allocator, "tool-linux-amd64", "v1.0.0");
    defer allocator.free(out);
    if (builtin.os.tag == .windows) {
        try testing.expectEqualStrings("tool-linux", out);
    } else {
        try testing.expectEqualStrings("tool", out);
    }
}

test "assets: isSupportedExt rejects checksum and text files" {
    try testing.expect(!isSupportedExt("foo.sha256"));
    try testing.expect(!isSupportedExt("foo.txt"));
    try testing.expect(!isSupportedExt("foo.sig"));
    try testing.expect(!isSupportedExt("foo.deb"));
}

test "assets: isSupportedExt allows archives and unknown extensions" {
    try testing.expect(isSupportedExt("foo.tar.gz"));
    try testing.expect(isSupportedExt("foo.zip"));
    try testing.expect(isSupportedExt("foo.exe"));
    try testing.expect(isSupportedExt("foo.zst"));
    try testing.expect(isSupportedExt("noext"));
}

test "assets: globMatch handles star and question" {
    try testing.expect(globMatch("gh_*_linux_amd64.tar.gz", "gh_2.40.0_linux_amd64.tar.gz"));
    try testing.expect(globMatch("gh-?.40.0-*", "gh-2.40.0-linux"));
    try testing.expect(!globMatch("gh_*_windows.zip", "gh_2.40.0_linux_amd64.tar.gz"));
}
