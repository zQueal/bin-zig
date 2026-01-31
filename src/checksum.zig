const std = @import("std");
const utils = @import("utils.zig");
const github = @import("github.zig");

pub fn compute(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
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

pub fn verifyHash(allocator: std.mem.Allocator, data: []const u8, expected_hash: []const u8) !bool {
    const actual_hash = try compute(allocator, data);
    defer allocator.free(actual_hash);

    // Verify hash format
    if (expected_hash.len != 64) {
        return error.InvalidHashFormat;
    }

    // Verify all characters are valid hex
    for (expected_hash) |c| {
        const is_valid_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!is_valid_hex) {
            return error.InvalidHashFormat;
        }
    }

    // Compare hashes (case-insensitive)
    return std.mem.eql(u8, actual_hash, expected_hash);
}

pub fn verify(allocator: std.mem.Allocator, client: *std.http.Client, release: github.Release, asset_name: []const u8, file_path: []const u8, io: std.Io) !void {
    const checksum_asset = findChecksumAsset(release, asset_name) orelse {
        std.log.warn("No checksum file found for {s}, skipping verification.", .{asset_name});
        return;
    };

    std.log.info("Verifying checksum using {s}...", .{checksum_asset.name});

    // Download checksum file into memory
    const uri = try std.Uri.parse(checksum_asset.browser_download_url);
    var req = try client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
        .headers = .{
            .user_agent = .{ .override = "bin-zig-cli" },
            .connection = .{ .override = "close" },
        },
    });
    defer req.deinit();

    var head_buf: [1024]u8 = undefined;
    var resp = try req.receiveHead(&head_buf);
    if (resp.head.status != .ok) return error.ChecksumDownloadFailed;

    const body_limit = 1024 * 1024; // 1MB
    var transfer_buf: [8192]u8 = undefined;
    var reader = resp.reader(&transfer_buf);
    const body = try reader.allocRemaining(allocator, .limited(body_limit));
    defer allocator.free(body);

    const expected_hash = try parseChecksum(body, asset_name) orelse {
        std.log.warn("Checksum for {s} not found in {s}", .{ asset_name, checksum_asset.name });
        return;
    };

    var actual_hash: [64]u8 = undefined;
    try utils.computeSha256(io, file_path, &actual_hash);

    // computeSha256 returns hex string in actual_hash
    const actual_hash_slice = std.mem.sliceTo(&actual_hash, 0);

    if (std.mem.eql(u8, expected_hash, actual_hash_slice)) {
        std.log.info("Checksum verified: OK", .{});
    } else {
        std.log.err("Checksum verification FAILED!", .{});
        std.log.err("  Expected: {s}", .{expected_hash});
        std.log.err("  Actual:   {s}", .{actual_hash_slice});
        return error.ChecksumMismatch;
    }
}

fn findChecksumAsset(release: github.Release, target_asset: []const u8) ?github.Asset {
    _ = target_asset;
    for (release.assets) |asset| {
        const name = asset.name;
        // Common checksum file patterns
        if (std.mem.indexOf(u8, name, "hashes") != null or
            std.mem.indexOf(u8, name, "checksum") != null or
            std.mem.indexOf(u8, name, "SHA256SUMS") != null or
            std.mem.endsWith(u8, name, ".sha256"))
        {
            return asset;
        }
    }
    return null;
}

fn parseChecksum(content: []const u8, asset_name: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, asset_name) != null) {
            // Usually "HASH  FILE" or "HASH *FILE" or just "HASH" if it's .sha256 file
            var parts = std.mem.splitAny(u8, trimmed, " \t*");
            while (parts.next()) |part| {
                if (part.len == 64) { // SHA256 hex is 64 chars
                    // Validate all characters are valid hex
                    var is_valid_hex = true;
                    for (part) |c| {
                        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) {
                            is_valid_hex = false;
                            break;
                        }
                    }
                    if (is_valid_hex) {
                        return part;
                    }
                }
            }
        }
    }
    return null;
}
