# Implementation Plan & Bug Fixes

This document outlines critical bug fixes and improvements needed for bin-zig.

---

## Priority 1: Critical Bugs & Missing Functionality

### Issue 1: Path Expansion Not Implemented
**Location**: `src/install.zig:65` - `validateAndResolvePath()`

**Problem**: Custom install paths are not expanded. `~/bin` and relative paths are not converted to absolute paths.

**Solution**:
```zig
fn validateAndResolvePath(allocator: std.mem.Allocator, path: []const u8, env: std.process.Environ, io: std.Io) ![]const u8 {
    var resolved_path = path;

    // Expand ~ to home directory
    if (std.mem.startsWith(u8, path, "~/")) {
        const home = try env.getAlloc(allocator, "HOME") catch b: {
            if (@import("builtin").os.tag == .windows) {
                break :b try env.getAlloc(allocator, "USERPROFILE");
            }
            return error.HomeNotFound;
        };
        defer allocator.free(home);
        resolved_path = try std.fs.path.join(allocator, &[_][]const u8{ home, path[2..] };
    }

    // Convert relative to absolute
    const abs_path = try std.fs.realpathAlloc(allocator, resolved_path);
    errdefer allocator.free(abs_path);

    // Check if directory exists (DO NOT create it)
    const dir = std.Io.Dir.openDirAbsolute(io, abs_path, .{}) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) {
            std.log.err("Install path does not exist: {s}", .{abs_path});
            std.log.err("Please create the directory first and try again.", .{});
            return error.PathNotFound;
        }
        return err;
    };
    defer dir.close(io);

    // Test writability
    const test_file_path = try std.fs.path.join(allocator, &[_][]const u8{ abs_path, ".bin_write_test" });
    defer allocator.free(test_file_path);

    const test_file = std.Io.Dir.createFileAbsolute(io, test_file_path, .{ .read = true }) catch {
        std.log.err("Install path is not writable: {s}", .{abs_path});
        return error.PathNotWritable;
    };
    test_file.close(io);
    std.Io.Dir.deleteFileAbsolute(io, test_file_path) catch {};

    return abs_path;
}
```

**Update function signature** (line 95):
```zig
pub fn install(allocator: std.mem.Allocator, conf: *config.Config, url: []const u8, env: std.process.Environ, io: std.Io, options: InstallOptions) !void {
    // ...
    const resolved_install_path = if (options.install_path) |path|
        try validateAndResolvePath(allocator, path, env, io)
    else
        null;
    // ...
}
```

---

### Issue 2: Hardcoded Response Size Limit
**Location**: `src/github.zig:49`, `src/gitlab.zig`, `src/codeberg.zig`

**Problem**: 1MB response limit will fail for projects with many release assets.

**Solution**: Make limit configurable and increase default:
```zig
const body_size = 10 * 1024 * 1024; // 10MB limit for response
```

Add to `DownloadOptions` or as a compile-time option if needed.

---

### Issue 3: No Test Coverage for Core Functionality
**Problem**: Only root.zig has tests. No tests for install, update, remove, config, providers, download, extract, or checksum.

**Solution**: Create comprehensive test suite.

#### Test Structure:
```
src/
├── tests/
│   ├── test_config.zig
│   ├── test_install.zig
│   ├── test_providers.zig
│   ├── test_download.zig
│   ├── test_extract.zig
│   └── test_checksum.zig
```

#### Example: `src/tests/test_config.zig`:
```zig
const std = @import("std");
const config = @import("../config.zig");

test "config: load empty config returns defaults" {
    const allocator = std.testing.allocator;
    var conf = try config.load(allocator, .{}, .{});
    defer conf.deinit();

    try std.testing.expectEqual(@as(u32, 4), conf.download_threads);
    try std.testing.expectEqual(@as(usize, 0), conf.bins.count());
}

test "config: save and load preserves data" {
    const allocator = std.testing.allocator;
    var conf = try config.load(allocator, .{}, .{});
    defer conf.deinit();

    try conf.bins.put(try allocator.dupe(u8, "test"), .{
        .path = try allocator.dupe(u8, "/path/to/test"),
        .remote_name = "test",
        .version = "v1.0.0",
        .url = "https://example.com/repo",
        .provider = "github",
        .pinned = false,
    });

    try config.save(&conf, .{}, .{});

    var conf2 = try config.load(allocator, .{}, .{});
    defer conf2.deinit();

    try std.testing.expectEqual(@as(usize, 1), conf2.bins.count());
}
```

#### Add test runner to `build.zig`:
```zig
// After existing test setup...
const test_bin_install = b.addTest(.{
    .root_source_file = b.path("src/tests/test_install.zig"),
    .target = target,
});
test_step.dependOn(&b.addRunArtifact(test_bin_install).step);
// ... add for each test file
```

---

## Priority 2: Code Quality & Maintainability



### Issue 4: No Config Value Validation
**Location**: `src/config.zig` - `load()` function

**Problem**: Config values loaded without validation (e.g., invalid bin_dir, empty URLs).

**Solution**: Add validation after loading:
```zig
pub fn validate(conf: *Config) !void {
    if (conf.bin_dir.len == 0) {
        return error.BinDirRequired;
    }

    // Validate bin_dir exists
    std.Io.Dir.openDirAbsolute(io, conf.bin_dir, .{}) catch |err| {
        std.log.err("bin_dir '{s}' is invalid: {}", .{conf.bin_dir, err});
        return error.InvalidBinDir;
    };

    // Validate thread count
    if (conf.download_threads == 0 or conf.download_threads > 32) {
        std.log.err("download_threads must be between 1 and 32", .{});
        return error.InvalidThreadCount;
    }

    // Validate tokens format (if provided)
    if (conf.tokens.github.len > 0 and !isValidTokenFormat(conf.tokens.github)) {
        return error.InvalidGitHubToken;
    }

    // Validate binaries
    var it = conf.bins.iterator();
    while (it.next()) |entry| {
        const bin = entry.value_ptr.*;
        if (bin.path.len == 0) return error.BinaryPathRequired;
        if (bin.url.len == 0) return error.BinaryUrlRequired;
        if (bin.version.len == 0) return error.BinaryVersionRequired;
    }
}
```

Call validation in `main.zig` after loading config:
```zig
var conf = try config.load(allocator, init.minimal.environ, init.io);
defer conf.deinit();
try config.validate(&conf);
```

---

### Issue 5: Duplicate Command Parsing Patterns
**Location**: `src/main.zig:106-148` - remove, pin, unpin commands

**Problem**: Identical ArrayList initialization pattern repeated 3 times.

**Solution**: Create helper function:
```zig
fn collectNames(allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator(Allocator)) ![]const []const u8 {
    var names = std.ArrayList([]const u8).init(allocator);
    errdefer names.deinit();

    while (args_iter.next()) |name| {
        try names.append(allocator, name);
    }

    if (names.items.len == 0) {
        return error.NoNamesProvided;
    }

    return names.toOwnedSlice();
}
```

Then use in each command:
```zig
} else if (std.mem.eql(u8, command, "remove")) {
    var names = try collectNames(allocator, &args_iter);
    defer allocator.free(names);

    try remove_cmd.remove(allocator, &conf, names, init.minimal.environ, init.io);
}
```

---

### Issue 6: Minimal Error Handling
**Location**: Throughout codebase - many bare `try` statements

**Problem**: Generic error messages don't help users understand what went wrong.

**Solution**: Add context to errors:
```zig
// Before
const file = try std.Io.Dir.openFileAbsolute(io, path, .{});

// After
const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| {
    std.log.err("Failed to open config file at '{s}': {}", .{path, err});
    return err;
};
```

Create error context wrapper:
```zig
fn withContext(comptime msg: []const u8, err: anyerror, args: anytype) error{ContextError} {
    std.log.err(msg, args);
    return err;
}

// Usage:
const file = withContext("Failed to open config file at '{s}'",
    std.Io.Dir.openFileAbsolute(io, path, .{}), .{path}) catch |e| return e;
```

---

### Issue 7: Orphan Code in root.zig
**Location**: `src/root.zig`

**Problem**: Contains demo functions not used anywhere in the project.

**Solution**: Remove unused code or convert to actual library exports:

**Option A**: Remove entirely (if root.zig is just placeholder):
```zig
//! By convention, root.zig is the root source file when making a package.
const std = @import("std");

// Export core types and functions for library usage
pub const Config = @import("config.zig").Config;
pub const Binary = @import("config.zig").Binary;

pub const install = @import("install.zig").install;
pub const update = @import("update.zig").update;
pub const remove = @import("remove.zig").remove;
```

**Option B**: Keep if library usage is intended:
```zig
//! Bin-zig library exports
const std = @import("std");

// Core functionality for programmatic use
pub const Config = @import("config.zig").Config;
pub const Binary = @import("config.zig").Binary;

pub fn installBinary(allocator: std.mem.Allocator, conf: *Config, url: []const u8, options: InstallOptions) !void {
    const env = try std.process.getEnviron(allocator);
    defer env.deinit();
    return @import("install.zig").install(allocator, conf, url, env, .{}, options);
}
```

---

## Priority 3: Documentation & UX Improvements

### Issue 8: CHANGES.md Stale Content
**Problem**: CHANGES.md documented implementation plan for features that are already implemented. Should track actual changes and work to be done.

**Solution**: Convert this file to track actual implementation status and bug fixes.

---

## Implementation Order

### Phase 1: Critical Functionality (Week 1)
1. Fix path expansion (Issue 1) - affects custom install paths
2. Increase response size limit (Issue 2) - prevents failures
3. Add config validation (Issue 4) - catches invalid configs early

### Phase 2: Code Quality (Week 2)
4. Remove orphan code (Issue 7) - clean up
5. Refactor command parsing (Issue 5) - reduce duplication
6. Improve error handling (Issue 6) - better UX

### Phase 3: Testing & Reliability (Week 3-4)
7. Implement test suite (Issue 3) - core functionality tests

---

## Testing Checklist

After implementing fixes:

### Issue 1: Path Expansion
- [ ] Test `~/bin` expands correctly on Unix
- [ ] Test relative paths convert to absolute
- [ ] Test Windows USERPROFILE expansion
- [ ] Test invalid paths fail gracefully

### Issue 2: Response Size
- [ ] Test with repository having >1MB release data
- [ ] Test with normal-sized repositories
- [ ] Verify no performance regression

### Issue 3: Tests
- [ ] Test config load/save
- [ ] Test URL parsing for all providers
- [ ] Test asset selection logic
- [ ] Test download functionality
- [ ] Test extraction for all formats
- [ ] Test SHA256 verification
- [ ] Test install/update/remove commands

### Issue 4: Validation
- [ ] Test invalid bin_dir
- [ ] Test invalid thread count
- [ ] Test invalid binary entries
- [ ] Test empty required fields

### Issue 5: Refactoring
- [ ] Verify all commands work after refactoring
- [ ] Test error messages unchanged

### Issue 6: Error Messages
- [ ] Verify descriptive error messages
- [ ] Test error recovery where possible

---

## Summary of Key Decisions

1. **Path Expansion**: Must support both `~` and relative paths. Use std.fs.realpathAlloc() for absolute conversion.

2. **Testing Strategy**: Add comprehensive test coverage for all core modules. Test suite should run with `zig build test`.

3. **Error Messages**: Wrap all try statements with context for better user experience.

4. **Library Usage**: Decide if root.zig should export library functions or be removed. Current recommendation: Export core types for potential library usage.

5. **Validation**: Add validate() function to config module and call immediately after loading.

6. **Response Limits**: Increase to 10MB for large repositories. Consider making configurable if needed.

7. **Refactoring**: Extract common patterns to reduce code duplication while maintaining functionality.

---

## Risk Assessment

| Issue | Risk Level | Impact | Effort | Priority |
|-------|-----------|---------|---------|----------|
| Path expansion | High | Users can't use ~ or relative paths | Medium | P1 |
| Response size | Medium | Fails on large repos | Low | P1 |
| No tests | High | Bugs go undetected | High | P1 |
| No validation | Medium | Invalid configs cause runtime errors | Medium | P1 |
| Duplicate code | Low | Maintenance burden | Low | P2 |
| Error handling | Medium | Poor UX on failures | Medium | P2 |
| Orphan code | Low | Confusion, small file size | Low | P2 |

---

## Next Steps

1. **Immediate**: Fix path expansion (Issue 1) and response limit (Issue 2)
2. **This Week**: Add config validation (Issue 4) and remove orphan code (Issue 7)
3. **Next Week**: Refactor command parsing (Issue 5) and improve errors (Issue 6)
4. **Following Weeks**: Implement comprehensive test suite (Issue 3)
