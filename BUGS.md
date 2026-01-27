# Bug Hunt Report

## High-Confidence Bugs Found (Confidence ≥ 80)

### Critical Issues (91-100)

#### 1. Memory Leak in extract.zig - findBestBinary
- **Confidence Score**: 95
- **File**: `src/extract.zig`
- **Line**: 103-107
- **Description**: The `best_file` path allocated at line 106 is never freed before returning. When a better-scoring file is found, the old best_file is freed, but the final best_file (the one returned) leaks.
- **Fix**: The caller `extractArchive` should free `best_entry` after calling `utils.copyFileAbsolute()`, or the function should return a path that the caller doesn't need to manage.

#### 2. Update Command Reinstalls Unnecessarily
- **Confidence Score**: 92
- **File**: `src/update.zig`
- **Line**: 107
- **Description**: The `updateOne` function always calls `install.install()` without checking if an update is actually needed. It simply re-installs from the same URL without comparing versions. This wastes bandwidth and time.
- **Fix**: Before calling install, check the latest version using `getLatestVersion()` and only reinstall if the version differs. Add logic similar to the default update case (lines 43-49) that does version comparison.

### Important Issues (80-90)

#### 3. Missing File Closure in clean.zig
- **Confidence Score**: 88
- **File**: `src/clean.zig`
- **Line**: 77-82
- **Description**: When opening a file fails, the function attempts to delete the file anyway, but if the file actually exists and can be opened, it's closed before deletion. However, if opening succeeds, the deletion happens with the file closed, which is correct. The issue is in lines 77-82 where the file is only closed inside the error branch, but then deletion is attempted. This could cause file locking issues on Windows.
- **Fix**: Remove the redundant file opening attempt. Use `std.Io.Dir.deleteFileAbsolute` directly without trying to open the file first. The current logic attempts to stat for file size but then deletes anyway, making the stat unnecessary.

#### 4. Silent Error Handling in ensure.zig
- **Confidence Score**: 85
- **File**: `src/ensure.zig`
- **Line**: 11-16
- **Description**: When checking if a file exists, only `FileNotFound` errors are handled to trigger reinstallation. Other errors (permission denied, path too long, etc.) are silently ignored, leaving potentially corrupted installations in place.
- **Fix**: Either propagate all errors as warnings/errors, or log them explicitly so users know why ensure is failing for specific binaries.

#### 5. Weak Hash Detection in checksum.zig
- **Confidence Score**: 83
- **File**: `src/checksum.zig`
- **Line**: 113
- **Description**: The checksum parser checks if a part is exactly 64 characters long to identify SHA256 hashes, but doesn't verify the characters are valid hexadecimal. This could match any 64-character string (not just hex) as a hash.
- **Fix**: After finding a 64-character string, verify all characters are valid hex digits (0-9, a-f, A-F) before returning it as the hash.

#### 6. Potential Memory Leak in update.zig
- **Confidence Score**: 82
- **File**: `src/update.zig`
- **Line**: 43-44
- **Description**: In the default update mode (checking for updates), `latest_version` is allocated and freed with defer. However, if the function continues to the next iteration and `getLatestVersion` fails, the allocation from the previous iteration's defer may not execute before the function returns an error. The defer scope is the while loop body, not the entire function.
- **Fix**: Either explicitly free `latest_version` before calling `getLatestVersion` on the next iteration, or restructure to handle memory more carefully.

#### 7. Incomplete Version Detection in install.zig
- **Confidence Score**: 80
- **File**: `src/install.zig`
- **Line**: 151-153
- **Description**: When parsing the @tag from URL, if the repository name contains an '@' character before the actual version tag (e.g., `user@company/repo@v1.0`), only the first '@' is considered, leaving `company/repo` as the repo name which is incorrect.
- **Fix**: Use `std.mem.lastIndexOfScalar(u8, repo_full, '@')` instead of `std.mem.indexOfScalar` to find the last '@' character, which is the correct delimiter for the version tag.

---

## Summary

**Total Bugs Found**: 7
- **Critical (91-100)**: 2
- **Important (80-90)**: 5

All issues have been identified with confidence scores ≥ 80, indicating they are genuine bugs requiring attention. The most critical issues are memory leaks that could lead to resource exhaustion over time, followed by logic bugs that affect the user experience.