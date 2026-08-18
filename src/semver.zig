//! Lenient semantic-version parsing and comparison modeled on
//! github.com/hashicorp/go-version (used by the reference implementation).

const std = @import("std");

pub const Version = struct {
    segments: []const u64,
    prerelease: []const u8 = "",
    metadata: []const u8 = "",

    pub fn eql(a: Version, b: Version) bool {
        if (a.segments.len != b.segments.len) return false;
        for (a.segments, b.segments) |x, y| if (x != y) return false;
        return std.mem.eql(u8, a.prerelease, b.prerelease);
    }
};

/// Parses a version like go-version: optional v/V prefix, dot-separated
/// numeric core (any number of parts), optional -prerelease, optional
/// +metadata. Returns null for unparseable input.
pub fn parse(s: []const u8) ?Version {
    var rest = s;
    if (rest.len > 0 and (rest[0] == 'v' or rest[0] == 'V')) rest = rest[1..];
    if (rest.len == 0) return null;

    var metadata: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        metadata = rest[plus + 1 ..];
        rest = rest[0..plus];
    }

    var prerelease: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        prerelease = rest[dash + 1 ..];
        rest = rest[0..dash];
    }

    var segments = std.ArrayList(u64).empty;
    defer segments.deinit(std.heap.page_allocator);

    var it = std.mem.splitScalar(u8, rest, '.');
    while (it.next()) |part| {
        if (part.len == 0) return null;
        const n = std.fmt.parseInt(u64, part, 10) catch return null;
        segments.append(std.heap.page_allocator, n) catch return null;
    }
    if (segments.items.len == 0) return null;

    const owned = std.heap.page_allocator.dupe(u64, segments.items) catch return null;
    return .{
        .segments = owned,
        .prerelease = prerelease,
        .metadata = metadata,
    };
}

/// Compares two versions. Metadata is ignored (like go-version).
pub fn compare(a: Version, b: Version) std.math.Order {
    const max = @max(a.segments.len, b.segments.len);
    var i: usize = 0;
    while (i < max) : (i += 1) {
        const x = if (i < a.segments.len) a.segments[i] else 0;
        const y = if (i < b.segments.len) b.segments[i] else 0;
        if (x < y) return .lt;
        if (x > y) return .gt;
    }

    // Prerelease rules: no prerelease > prerelease.
    if (a.prerelease.len == 0 and b.prerelease.len != 0) return .gt;
    if (a.prerelease.len != 0 and b.prerelease.len == 0) return .lt;
    return comparePrerelease(a.prerelease, b.prerelease);
}

fn comparePrerelease(a: []const u8, b: []const u8) std.math.Order {
    if (std.mem.eql(u8, a, b)) return .eq;

    var ait = std.mem.splitScalar(u8, a, '.');
    var bit = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const aseg = ait.next();
        const bseg = bit.next();
        if (aseg == null and bseg == null) return .eq;
        if (aseg == null) return .lt; // shorter prerelease is lower
        if (bseg == null) return .gt;
        const av = aseg.?;
        const bv = bseg.?;
        const an: ?u64 = std.fmt.parseInt(u64, av, 10) catch null;
        const bn: ?u64 = std.fmt.parseInt(u64, bv, 10) catch null;
        if (an != null and bn != null) {
            if (an.? < bn.?) return .lt;
            if (an.? > bn.?) return .gt;
        } else if (an != null and bn == null) {
            return .lt; // numeric < alphanumeric
        } else if (an == null and bn != null) {
            return .gt;
        } else {
            const ord = std.mem.order(u8, av, bv);
            if (ord != .eq) return ord;
        }
    }
}
