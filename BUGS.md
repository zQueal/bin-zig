# Bug Report for bin-zig

Last updated: January 26, 2026

## Critical Bugs (7)

### 1. Memory leak in JSON parsing
**File**: `src/github.zig:58-59`
**Confidence**: 95%
**Severity**: CRITICAL

The parsed JSON structure from `std.json.parseFromSlice` is never freed:

```zig
const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
// defer parsed.deinit(); // Caller needs the strings - BUT THIS IS NEVER CALLED!
```

**Impact**: Every install/update from GitHub leaks memory proportional to the JSON response size.

**Fix**: Add `defer parsed.deinit();` after the parse.

---

### 2. Out-of-bounds memory access - String slicing without length check
**File**: `src/remove.zig:13`
**Confidence**: 95%
**Severity**: CRITICAL

Removing ".exe" extension without verifying string has at least 4 characters:

```zig
if (std.mem.endsWith(u8, name, ".exe")) {
    input_clean = name[0 .. name.len - 4];  // CRASH if name.len < 4!
}
```

**Reproduction**: Pass "exe" (3 chars) or "xe" (2 chars) as binary name to remove command.

**Fix**: Check length before slicing:
```zig
if (name.len >= 4 and std.mem.endsWith(u8, name, ".exe")) {
    input_clean = name[0 .. name.len - 4];
}
```

---

### 3. Out-of-bounds memory access - Another instance
**File**: `src/remove.zig:18-19`
**Confidence**: 95%
**Severity**: CRITICAL

Same issue with `remote_clean` - slicing without length verification:

```zig
if (std.mem.endsWith(u8, remote_clean, ".exe")) {
    remote_clean = remote_clean[0..remote_clean.len-4];  // CRASH if len < 4!
}
```

**Fix**: Same length check as above.

---

### 4. Memory leak - prepareDownloadPath never freed
**File**: `src/install.zig:73-76`
**Confidence**: 90%
**Severity**: CRITICAL

`download_path` is allocated but never freed:

```zig
const download_path = try prepareDownloadPath(allocator, conf, asset_name, io);
try performDownload(allocator, &client, download_url, download_path, io, conf.download_threads);
try checksum_mod.verify(allocator, &client, release, asset_name, download_path, io);
try finalizeInstall(allocator, conf, env, io, download_path, url, repo, tag_name, "github", options.alias);
// download_path NEVER FREED!
```

**Impact**: Every installation leaks memory equal to the cache path length.

**Fix**: Add `defer allocator.free(download_path)` after allocation.

---

### 5. Memory leak - extractArchive return value
**File**: `src/install.zig:205`
**Confidence**: 90%
**Severity**: CRITICAL

The return value from `extract_mod.extractArchive` is leaked:

```zig
final_bin_path = try extract_mod.extractArchive(allocator, download_path, install_path_dir, install_name, io);
// final_bin_path is stored in new_bin.path but allocated separately
```

Then at line 215:
```zig
.path = try allocator.dupe(u8, final_bin_path),  // DUPLICATES the path!
```

The original `final_bin_path` from `extractArchive` is leaked.

**Impact**: Every archive extraction leaks the extracted binary path memory.

**Fix**: Add `defer allocator.free(final_bin_path)` after line 205.

---

### 6. Potential crash - URL parsing without validation
**File**: `src/update.zig:70`
**Confidence**: 88%
**Severity**: CRITICAL

When removing @ tag from repo name, no check if @ exists:

```zig
repo = it.next().?;  // unwrap
if (std.mem.indexOfScalar(u8, repo, '@')) |at| repo = repo[0..at];
```

Same pattern repeated at lines 80, 90 (GitLab and Codeberg).

**Impact**: Malformed URLs or unusual repo names could cause panics.

**Fix**: Add proper error handling:
```zig
repo = it.next() orelse return error.InvalidURL;
```

---

## Important Bugs (2)

### 7. Inefficient duplicate function call
**File**: `src/install.zig:66-67`
**Confidence**: 85%
**Severity**: IMPORTANT

`selectBestAsset` is called twice - once to score assets, once to get the selected asset:

```zig
_ = try github.selectBestAsset(allocator, release); // Score them
const asset_val = if (options.interactive) try selectGitHubAssetInteractively(release.assets, io) else (try github.selectBestAsset(allocator, release)) orelse return error.NoAssetFound;
```

**Impact**: Double the work for asset selection. Leaks memory from the first call's allocations.

**Fix**: Call once, store result, use it:
```zig
const best_asset_opt = try github.selectBestAsset(allocator, release);
const asset_val = if (options.interactive)
    try selectGitHubAssetInteractively(release.assets, io)
else
    best_asset_opt orelse return error.NoAssetFound;
```

Also affects:
- GitLab provider at lines 80-81
- Codeberg provider at lines 93-94

---

### 8. Code duplication - Interactive asset selection 3×
**File**: `src/install.zig:107-183`
**Confidence**: 90%
**Severity**: IMPORTANT

Three nearly identical functions for interactive asset selection:
- `selectGitHubAssetInteractively` (lines 107-131)
- `selectGitLabAssetInteractively` (lines 133-157)
- `selectCodebergAssetInteractively` (lines 159-183)

**Impact**: Maintenance burden - any fix to one must be replicated 3×. Bug risk from drift.

**Fix**: Create a generic template function or use type parameters.

---

### 9. Memory safety - Stack buffer truncation for long filenames
**File**: `src/extract.zig:91-95`
**Confidence**: 80%
**Severity**: IMPORTANT

Using a fixed-size stack buffer with `@min` for case conversion, but not handling cases where name exceeds buffer size:

```zig
var lower_name_buf: [256]u8 = undefined;
const actual_len = @min(name.len, 256);
const lower_name = std.ascii.lowerString(lower_name_buf[0..actual_len], name[0..actual_len]);
```

If `name.len > 256`, only the first 256 chars are lowercased. This causes incorrect matching.

**Impact**: May fail to correctly identify the best binary in large archives with long paths.

**Fix**: Either use a heap-allocated buffer for the full string, or use case-insensitive comparison that doesn't require allocation.

---

## Summary

**Total Bugs Found**: 9
- Critical: 6
- Important: 3

**Quick Wins** (highest impact, lowest effort):
1. Add `defer allocator.free()` for JSON parse result (github.zig:58-59)
2. Add length checks before `.exe` trimming in remove.zig (lines 13, 18-19)
3. Fix URL parsing null checks in update.zig (lines 70, 80, 90)

These three fixes would address immediate crash risks and memory leaks.