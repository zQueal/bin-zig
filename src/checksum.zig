const std = @import("std");

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
