const std = @import("std");
const checksum_mod = @import("checksum");

test "checksum: compute SHA256 hash" {
    const allocator = std.testing.allocator;

    const test_data = "Hello, World!";
    const expected_hash = "dffd6021bb2bd5b0af676290809ec3a53191dd81c7f70a4b28688a362182986f";

    const hash = try checksum_mod.compute(allocator, test_data);
    defer allocator.free(hash);

    try std.testing.expectEqualStrings(expected_hash, hash);
}

test "checksum: hash is consistent" {
    const allocator = std.testing.allocator;

    const test_data = "Test data for checksum";
    const hash1 = try checksum_mod.compute(allocator, test_data);
    defer allocator.free(hash1);
    const hash2 = try checksum_mod.compute(allocator, test_data);
    defer allocator.free(hash2);

    try std.testing.expectEqualStrings(hash1, hash2);
}

test "checksum: different inputs produce different hashes" {
    const allocator = std.testing.allocator;

    const data1 = "First data";
    const data2 = "Second data";
    const hash1 = try checksum_mod.compute(allocator, data1);
    defer allocator.free(hash1);
    const hash2 = try checksum_mod.compute(allocator, data2);
    defer allocator.free(hash2);

    try std.testing.expect(!std.mem.eql(u8, hash1, hash2));
}

test "checksum: empty string hash" {
    const allocator = std.testing.allocator;

    const empty_data = "";
    const expected_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    const hash = try checksum_mod.compute(allocator, empty_data);
    defer allocator.free(hash);

    try std.testing.expectEqualStrings(expected_hash, hash);
}

test "checksum: hash length is always 64 characters" {
    const allocator = std.testing.allocator;

    const test_cases = [_][]const u8{
        "a",
        "short",
        "A medium length string with various characters: 123!@#",
        "A very long string that contains many characters to test the SHA256 hashing function. This should still produce a consistent 64 character hexadecimal string output regardless of the input length.",
    };

    for (test_cases) |data| {
        const hash = try checksum_mod.compute(allocator, data);
        defer allocator.free(hash);

        try std.testing.expectEqual(@as(usize, 64), hash.len);
    }
}

test "checksum: hash output is valid hexadecimal" {
    const allocator = std.testing.allocator;

    const test_data = "Test hexadecimal validation";
    const hash = try checksum_mod.compute(allocator, test_data);
    defer allocator.free(hash);

    // Verify all characters are valid hex
    for (hash) |c| {
        const is_valid_hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        try std.testing.expect(is_valid_hex);
    }
}

test "checksum: verify matching hash" {
    const allocator = std.testing.allocator;

    const test_data = "Data to verify";
    const hash = try checksum_mod.compute(allocator, test_data);
    defer allocator.free(hash);

    // Verify should succeed for matching hash
    const result = try checksum_mod.verifyHash(allocator, test_data, hash);
    try std.testing.expect(result);
}

test "checksum: verify non-matching hash" {
    const allocator = std.testing.allocator;

    const test_data = "Data to verify";
    const wrong_hash = "0000000000000000000000000000000000000000000000000000000000000000";

    const result = try checksum_mod.verifyHash(allocator, test_data, wrong_hash);
    try std.testing.expect(!result);
}

test "checksum: verify with invalid hash format" {
    const allocator = std.testing.allocator;

    const test_data = "Data to verify";
    const invalid_hash = "not-a-valid-hash";

    // This should return an error
    _ = checksum_mod.verifyHash(allocator, test_data, invalid_hash) catch |err| {
        try std.testing.expect(err == error.InvalidHashFormat);
        return;
    };
    try std.testing.expect(false); // Should not reach here
}
