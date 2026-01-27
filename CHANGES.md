# Implementation Plan

This document outlines the implementation of four major features for bin-zig:
- Feature 5: Custom Install Path
- Feature 6: Multiple Binary Operations
- Feature 7: Explicit Provider Selection
- Feature 8: Per-Command Help

---

## FEATURE 5: Custom Install Path

### Summary
Allow users to specify a custom install path for binaries instead of using the default `bin_dir` from config.

### Changes Required

#### 1. src/install.zig - Update `InstallOptions` struct (line 32)
```zig
pub const InstallOptions = struct {
    alias: ?[]const u8 = null,
    interactive: bool = false,
    install_path: ?[]const u8 = null,  // NEW FIELD
};
```

#### 2. src/main.zig - Parse install path argument (after line 63)
- Collect positional arguments after flags
- Third non-flag argument becomes install path
- Pass to `install()` via options

Implementation pattern:
```zig
var install_path: ?[]const u8 = null;
while (args_iter.next()) |arg| {
    if (std.mem.eql(u8, arg, "--as")) {
        alias = args_iter.next() orelse { /* error */ };
    } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all-assets")) {
        interactive = true;
    } else if (url == null) {
        url = arg;
    } else if (install_path == null) {
        install_path = arg;
    }
}
```

#### 3. src/install.zig - Add path validation function (new function after line 105)
```zig
fn validateAndResolvePath(allocator: std.mem.Allocator, path: []const u8, io: std.Io) ![]const u8 {
    // Convert relative to absolute
    const abs_path = try std.fs.realpathAlloc(allocator, path);
    errdefer allocator.free(abs_path);

    // Check if directory exists (DO NOT create it)
    const dir = std.Io.Dir.openAbsolute(io, abs_path, {}) catch |err| {
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

    const test_file = std.Io.Dir.createFileAbsolute(io, test_file_path, .{ .read = true }) catch |err| {
        std.log.err("Install path is not writable: {s}", .{abs_path});
        return error.PathNotWritable;
    };
    test_file.close(io);
    std.Io.Dir.deleteFileAbsolute(io, test_file_path) catch {};

    return abs_path;
}
```

#### 4. src/install.zig - Update `install()` function (after line 37)
- Call validation if `install_path` provided
- Pass validated path to `finalizeInstall()`

Implementation:
```zig
pub fn install(allocator: std.mem.Allocator, conf: *config.Config, url: []const u8, env: std.process.Environ, io: std.Io, options: InstallOptions) !void {
    // Validate install path if provided
    const resolved_install_path = if (options.install_path) |path|
        try validateAndResolvePath(allocator, path, io)
    else
        null;
    defer if (resolved_install_path) |p| allocator.free(p);

    // ... rest of function ...

    // Pass resolved_install_path to finalizeInstall calls
    try finalizeInstall(allocator, conf, env, io, download_path, url, repo, tag_name, provider_name, options.alias, resolved_install_path);
}
```

#### 5. src/install.zig - Update `finalizeInstall()` signature (line 196)
```zig
fn finalizeInstall(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.Environ, io: std.Io, download_path: []const u8, url: []const u8, repo: []const u8, version: []const u8, provider_name: []const u8, alias: ?[]const u8, custom_path: ?[]const u8) !void
```

#### 6. src/install.zig - Update `finalizeInstall()` body (line 197)
```zig
const install_path_dir = custom_path orelse conf.bin_dir;
```

#### 7. Update README.md
Document custom install path usage:
```bash
# Absolute path
bin install cli/cli /usr/local/bin/gh

# Relative path (converted to absolute)
bin install cli/cli ~/bin/gh
bin install cli/cli ./bin/gh
```

---

## FEATURE 6: Multiple Binary Operations

### Summary
Allow `remove`, `pin`, `unpin`, and `update` commands to process multiple binaries in a single invocation.

### Changes Required

#### 1. src/main.zig - Update `remove` command (lines 88-94)
Replace single `name` with collection loop:
```zig
} else if (std.mem.eql(u8, command, "remove")) {
    var names = std.ArrayList([]const u8).init(allocator);
    defer names.deinit();

    while (args_iter.next()) |name| {
        try names.append(name);
    }

    if (names.items.len == 0) {
        std.log.err("Usage: bin remove <name...>", .{});
        return;
    }

    try remove_cmd.remove(allocator, &conf, names.items, init.minimal.environ, init.io);
}
```

#### 2. src/main.zig - Update `pin` command (lines 97-103)
Same pattern as remove:
```zig
} else if (std.mem.eql(u8, command, "pin")) {
    var names = std.ArrayList([]const u8).init(allocator);
    defer names.deinit();

    while (args_iter.next()) |name| {
        try names.append(name);
    }

    if (names.items.len == 0) {
        std.log.err("Usage: bin pin <name...>", .{});
        return;
    }

    try pin_cmd.pin(allocator, &conf, names.items, init.minimal.environ, init.io);
}
```

#### 3. src/main.zig - Update `unpin` command (lines 104-110)
Same pattern as remove:
```zig
} else if (std.mem.eql(u8, command, "unpin")) {
    var names = std.ArrayList([]const u8).init(allocator);
    defer names.deinit();

    while (args_iter.next()) |name| {
        try names.append(name);
    }

    if (names.items.len == 0) {
        std.log.err("Usage: bin unpin <name...>", .{});
        return;
    }

    try pin_cmd.unpin(allocator, &conf, names.items, init.minimal.environ, init.io);
}
```

#### 4. src/main.zig - Update `update` command (lines 74-85)
Collect multiple targets if `--all` not set:
```zig
} else if (std.mem.eql(u8, command, "update")) {
    var targets = std.ArrayList([]const u8).init(allocator);
    defer targets.deinit();

    var all_flag = false;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--all")) {
            all_flag = true;
        } else {
            try targets.append(arg);
        }
    }

    try update_cmd.update(allocator, &conf, if (targets.items.len == 0) null else targets.items, all_flag, init.minimal.environ, init.io);
}
```

#### 5. src/remove.zig - Refactor for multiple names (entire file)
```zig
const std = @import("std");
const config = @import("config.zig");

pub fn remove(allocator: std.mem.Allocator, conf: *config.Config, names: []const []const u8, env: std.process.Environ, io: std.Io) !void {
    _ = allocator;

    var successes: usize = 0;
    var failures = std.ArrayList([]const u8).init(allocator);
    defer failures.deinit();

    for (names) |name| {
        var it = conf.bins.iterator();
        var bin_to_remove: ?config.Binary = null;
        var key_to_remove: ?[]const u8 = null;

        var input_clean = name;
        if (std.mem.endsWith(u8, name, ".exe")) {
            input_clean = name[0 .. name.len - 4];
        }

        while (it.next()) |entry| {
            var remote_clean = entry.value_ptr.remote_name;
            if (std.mem.endsWith(u8, remote_clean, ".exe")) {
                remote_clean = remote_clean[0..remote_clean.len-4];
            }

            if (std.mem.eql(u8, remote_clean, input_clean)) {
                bin_to_remove = entry.value_ptr.*;
                key_to_remove = entry.key_ptr.*;
                break;
            }
        }

        if (bin_to_remove == null) {
            std.log.warn("Binary '{s}' not found in managed list.", .{name});
            try failures.append(name);
            continue;
        }

        // Remove file
        std.Io.Dir.deleteFileAbsolute(io, bin_to_remove.?.path) catch |err| {
            std.log.warn("Could not delete file {s}: {}", .{ bin_to_remove.?.path, err });
            try failures.append(name);
            continue;
        };

        // Remove from config
        _ = conf.bins.remove(key_to_remove.?);
        std.log.info("Successfully removed '{s}'", .{name});
        successes += 1;
    }

    // Save config once after all operations
    try config.save(conf, env, io);

    // Report summary
    if (successes > 0) {
        std.log.info("Successfully removed {d} binary(s)", .{successes});
    }
    if (failures.items.len > 0) {
        std.log.warn("Failed to remove: {s}", .{failures.items});
    }

    return if (successes == 0) error.AllOperationsFailed else if (failures.items.len > 0) error.SomeOperationsFailed else {};
}
```

#### 6. src/pin.zig - Refactor `pin()` for multiple names
```zig
const std = @import("std");
const config = @import("config.zig");

pub fn pin(allocator: std.mem.Allocator, conf: *config.Config, names: []const []const u8, env: std.process.Environ, io: std.Io) !void {
    _ = allocator;

    var successes: usize = 0;
    var failures = std.ArrayList([]const u8).init(allocator);
    defer failures.deinit();

    for (names) |name| {
        var found = false;
        var it = conf.bins.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.remote_name, name)) {
                entry.value_ptr.pinned = true;
                std.log.info("Pinned {s} to version {s}", .{ name, entry.value_ptr.version });
                successes += 1;
                found = true;
                break;
            }
        }

        if (!found) {
            std.log.warn("Binary '{s}' not found.", .{name});
            try failures.append(name);
        }
    }

    if (successes > 0) {
        try config.save(conf, env, io);
        std.log.info("Successfully pinned {d} binary(s)", .{successes});
    }
    if (failures.items.len > 0) {
        std.log.warn("Failed to pin: {s}", .{failures.items});
    }

    return if (successes == 0) error.AllOperationsFailed else if (failures.items.len > 0) error.SomeOperationsFailed else {};
}

pub fn unpin(allocator: std.mem.Allocator, conf: *config.Config, names: []const []const u8, env: std.process.Environ, io: std.Io) !void {
    _ = allocator;

    var successes: usize = 0;
    var failures = std.ArrayList([]const u8).init(allocator);
    defer failures.deinit();

    for (names) |name| {
        var found = false;
        var it = conf.bins.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.remote_name, name)) {
                entry.value_ptr.pinned = false;
                std.log.info("Unpinned {s}", .{name});
                successes += 1;
                found = true;
                break;
            }
        }

        if (!found) {
            std.log.warn("Binary '{s}' not found.", .{name});
            try failures.append(name);
        }
    }

    if (successes > 0) {
        try config.save(conf, env, io);
        std.log.info("Successfully unpinned {d} binary(s)", .{successes});
    }
    if (failures.items.len > 0) {
        std.log.warn("Failed to unpin: {s}", .{failures.items});
    }

    return if (successes == 0) error.AllOperationsFailed else if (failures.items.len > 0) error.SomeOperationsFailed else {};
}
```

#### 7. src/update.zig - Update to accept multiple targets (line 8)
```zig
pub fn update(allocator: std.mem.Allocator, conf: *config.Config, targets: ?[]const []const u8, all_flag: bool, env: std.process.Environ, io: std.Io) !void {
    if (all_flag) {
        std.log.info("Updating all binaries...", .{});
        var it = conf.bins.iterator();
        while (it.next()) |entry| {
            try updateOne(allocator, conf, entry.value_ptr.*, env, io);
        }
        return;
    }

    if (targets) |names| {
        for (names) |name| {
            var it = conf.bins.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.remote_name, name)) {
                    try updateOne(allocator, conf, entry.value_ptr.*, env, io);
                    break;
                }
            }
            std.log.err("Binary '{s}' not found in managed list.", .{name});
        }
        return;
    }

    // Default: Check for updates (no targets specified)
    std.log.info("Checking for updates...", .{});
    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();

    var it = conf.bins.iterator();
    var found_updates = false;
    while (it.next()) |entry| {
        const bin = entry.value_ptr.*;
        if (bin.pinned) continue;

        const latest_version = try getLatestVersion(allocator, &client, bin, conf);
        defer allocator.free(latest_version);

        if (!std.mem.eql(u8, bin.version, latest_version)) {
            std.log.info("  {s}: {s} -> {s} (update available)", .{ bin.remote_name, bin.version, latest_version });
            found_updates = true;
        }
    }

    if (!found_updates) {
        std.log.info("All binaries are up to date.", .{});
    } else {
        std.log.info("Run 'bin update --all' to update all binaries.", .{});
    }
}
```

#### 8. Update README.md
Document multiple operations:
```bash
# Remove multiple binaries
bin remove gh kubectl fzf

# Pin multiple binaries
bin pin terraform kubectl

# Update multiple binaries
bin update gh kubectl
```

---

## FEATURE 7: Explicit Provider Selection

### Summary
Allow users to explicitly specify a provider using `--provider` flag. Three supported URL formats:
1. Full URL: `https://github.com/cli/cli` (auto-detect)
2. Domain format: `github.com/cli/cli` (auto-detect)
3. Short format: `cli/cli` (requires `--provider` flag, defaults to github if not specified)

### Changes Required

#### 1. src/install.zig - Update `Provider` enum and `fromUrl()` (lines 11-30)
```zig
pub const Provider = enum {
    github,
    gitlab,
    codeberg,

    pub fn fromUrl(url: []const u8, explicit_provider: ?Provider) !Provider {
        // If explicit provider provided, use it
        if (explicit_provider) |prov| return prov;

        // Auto-detect from full URL (https://)
        if (std.mem.indexOf(u8, url, "https://github.com/") != null) return .github;
        if (std.mem.indexOf(u8, url, "https://gitlab.com/") != null) return .gitlab;
        if (std.mem.indexOf(u8, url, "https://codeberg.org/") != null) return .codeberg;

        // Auto-detect from domain format (github.com/)
        if (std.mem.indexOf(u8, url, "github.com/") != null) return .github;
        if (std.mem.indexOf(u8, url, "gitlab.com/") != null) return .gitlab;
        if (std.mem.indexOf(u8, url, "codeberg.org/") != null) return .codeberg;

        // Validate user/repo format (exactly one slash)
        var slash_count: usize = 0;
        var it = std.mem.splitScalar(u8, url, '/');
        var parts: [2][]const u8 = undefined;
        while (it.next()) |part| {
            if (slash_count < 2) {
                parts[slash_count] = part;
            }
            slash_count += 1;
        }

        if (slash_count != 2 or parts[0].len == 0 or parts[1].len == 0) {
            return error.InvalidURL;
        }

        // Default to github for "user/repo" format
        return .github;
    }

    pub fn prefix(self: Provider) []const u8 {
        return switch (self) {
            .github => "github.com/",
            .gitlab => "gitlab.com/",
            .codeberg => "codeberg.org/",
        };
    }
};
```

#### 2. src/install.zig - Update `InstallOptions` struct (line 32)
```zig
pub const InstallOptions = struct {
    alias: ?[]const u8 = null,
    interactive: bool = false,
    install_path: ?[]const u8 = null,
    provider: ?Provider = null,  // NEW FIELD
};
```

#### 3. src/main.zig - Add `--provider` flag parsing (after line 62)
```zig
} else if (std.mem.eql(u8, command, "install")) {
    var url: ?[]const u8 = null;
    var alias: ?[]const u8 = null;
    var interactive = false;
    var provider: ?install_cmd.Provider = null;

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--as")) {
            alias = args_iter.next() orelse {
                std.log.err("--as requires a name", .{});
                return;
            };
        } else if (std.mem.eql(u8, arg, "-a") or std.mem.eql(u8, arg, "--all-assets")) {
            interactive = true;
        } else if (std.mem.eql(u8, arg, "--provider")) {
            const prov_str = args_iter.next() orelse {
                std.log.err("--provider requires a type (github, gitlab, codeberg)", .{});
                return;
            };
            provider = if (std.mem.eql(u8, prov_str, "github")) .github
                       else if (std.mem.eql(u8, prov_str, "gitlab")) .gitlab
                       else if (std.mem.eql(u8, prov_str, "codeberg")) .codeberg
                       else {
                           std.log.err("Unknown provider: {s}", .{prov_str});
                           std.log.err("Supported providers: github, gitlab, codeberg", .{});
                           return;
                       };
        } else if (url == null) {
            url = arg;
        }
    }

    if (url == null) {
        std.log.err("Usage: bin install <url> [--as <name>] [-a] [--provider <type>] [path]", .{});
        return;
    }

    try install_cmd.install(allocator, &conf, url.?, init.minimal.environ, init.io, .{
        .alias = alias,
        .interactive = interactive,
        .provider = provider,
    });
```

#### 4. src/install.zig - Update `install()` function (line 41)
Update provider detection to use new signature:
```zig
const provider = try Provider.fromUrl(url, options.provider);
```

#### 5. src/install.zig - Handle different URL formats (after line 42)
Update URL parsing to work with all three formats:
```zig
const provider = try Provider.fromUrl(url, options.provider);
const pref = provider.prefix();

var rest: []const u8 = undefined;

// Handle full URL (https://)
if (std.mem.indexOf(u8, url, "https://") != null) {
    const idx = std.mem.indexOf(u8, url, pref).?;
    rest = url[idx + pref.len ..];
}
// Handle domain format (github.com/) or short format (user/repo)
else if (std.mem.indexOf(u8, url, pref) != null) {
    const idx = std.mem.indexOf(u8, url, pref).?;
    rest = url[idx + pref.len ..];
}
// Short format (user/repo)
else {
    rest = url;
}

var it = std.mem.splitScalar(u8, rest, '/');
const user = it.next() orelse return error.InvalidURL;
var repo_full = it.next() orelse return error.InvalidURL;
```

#### 6. Update README.md
Document all three URL formats:
```bash
# Full URL (auto-detect)
bin install https://github.com/cli/cli

# Domain format (auto-detect)
bin install github.com/cli/cli
bin install gitlab.com/gitlab-org/cli
bin install codeberg.org/mergiraf/mergiraf

# Short format (defaults to GitHub)
bin install cli/cli

# Short format with explicit provider
bin install --provider github cli/cli
bin install --provider gitlab gitlab-org/cli
bin install --provider codeberg mergiraf/mergiraf
```

---

## FEATURE 8: Per-Command Help

### Summary
Add `help` command that displays detailed help for specific commands.

### Changes Required

#### 1. src/main.zig - Add `help` command (after line 116)
```zig
} else if (std.mem.eql(u8, command, "help")) {
    const subcommand = args_iter.next();
    if (subcommand == null) {
        printHelp();
        return;
    }
    printCommandHelp(subcommand.?);
    return;
```

#### 2. src/main.zig - Create `printCommandHelp()` function (after line 151)
```zig
fn printCommandHelp(command: []const u8) void {
    if (std.mem.eql(u8, command, "install")) {
        std.debug.print(
            \\bin install <url> [path] - Install binary from GitHub, GitLab, or Codeberg
            \\
            \\Arguments:
            \\  url       Repository URL or user/repo
            \\            Supported formats:
            \\              - Full URL: https://github.com/cli/cli
            \\              - Domain: github.com/cli/cli
            \\              - Short: cli/cli (defaults to GitHub)
            \\  path      Optional custom install directory (absolute or relative)
            \\            Path must exist and be writable.
            \\
            \\Flags:
            \\  --as <name>         Install with custom alias instead of repo name
            \\  -a, --all-assets    Interactive mode to manually select from assets
            \\  --provider <type>    Explicit provider: github, gitlab, or codeberg
            \\
            \\Examples:
            \\  bin install cli/cli
            \\  bin install gitlab.com/gitlab-org/cli --as glab
            \\  bin install cli/cli ~/bin/gh
            \\  bin install cli/cli --as gh -a
            \\  bin install --provider gitlab gitlab-org/cli
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "update")) {
        std.debug.print(
            \\bin update [name...] - Update installed binaries
            \\
            \\Arguments:
            \\  name      One or more binary names to update (optional)
            \\
            \\Flags:
            \\  --all     Update all managed binaries
            \\
            \\Examples:
            \\  bin update           Check all binaries for updates
            \\  bin update gh        Update specific binary
            \\  bin update gh kubectl Update multiple binaries
            \\  bin update --all     Update all binaries
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "list")) {
        std.debug.print(
            \\bin list - List installed binaries and versions
            \\
            \\Displays all managed binaries with their version, path, and provider.
            \\
            \\Example output:
            \\  gh (version: v2.40.0, path: /home/user/.local/bin/gh, provider: github)
            \\  kubectl (version: v1.29.0, path: /home/user/.local/bin/kubectl, provider: github)
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "remove")) {
        std.debug.print(
            \\bin remove <name...> - Remove one or more installed binaries
            \\
            \\Arguments:
            \\  name      One or more binary names to remove
            \\
            \\Examples:
            \\  bin remove gh
            \\  bin remove gh kubectl fzf
            \\  bin remove gh.exe  (also works without .exe)
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "ensure")) {
        std.debug.print(
            \\bin ensure - Verify and reinstall missing binaries
            \\
            \\Checks all managed binaries and reinstalls any that are missing from disk.
            \\Useful for restoration after system maintenance or cleanup.
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "pin")) {
        std.debug.print(
            \\bin pin <name...> - Lock binary to current version
            \\
            \\Arguments:
            \\  name      One or more binary names to pin
            \\
            \\Pinned binaries will not be updated by 'bin update --all'.
            \\
            \\Examples:
            \\  bin pin terraform
            \\  bin pin terraform kubectl
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "unpin")) {
        std.debug.print(
            \\bin unpin <name...> - Unlock binary for updates
            \\
            \\Arguments:
            \\  name      One or more binary names to unpin
            \\
            \\Examples:
            \\  bin unpin terraform
            \\  bin unpin terraform kubectl
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "prune")) {
        std.debug.print(
            \\bin prune - Remove dead entries from configuration
            \\
            \\Removes entries for binaries that no longer exist on disk
            \\from the managed binaries list.
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "clean")) {
        std.debug.print(
            \\bin clean - Clear download/extraction cache
            \\
            \\Removes all cached downloaded files from the cache directory.
            \\Does not affect installed binaries.
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "info")) {
        std.debug.print(
            \\bin info - Show API rate limit information
            \\
            \\Displays current API rate limit status for GitHub, GitLab, and Codeberg.
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "help")) {
        std.debug.print(
            \\bin help [command] - Display help information
            \\
            \\Arguments:
            \\  command   Optional command to show detailed help for
            \\
            \\Examples:
            \\  bin help           Show general help
            \\  bin help install   Show detailed install command help
            \\
        , .{});
    } else {
        std.log.err("Unknown command: {s}", .{command});
        std.debug.print("\nRun 'bin help' to see all available commands.\n", .{});
    }
}
```

#### 3. src/main.zig - Update `printHelp()` to include help command (line 144)
```zig
\\  help [command]   Show help for specific command
```

#### 4. Update README.md
Add to Commands Reference table:
```markdown
| `bin help [command]`       | Show help for any command                     | `bin help install`                          |
```

---

## IMPLEMENTATION ORDER

1. **Feature 7** (Explicit Provider) - Foundation for install command URL parsing
2. **Feature 5** (Custom Install Path) - Builds on install command
3. **Feature 6** (Multiple Operations) - Independent feature
4. **Feature 8** (Per-Command Help) - Documentation layer

---

## TESTING CHECKLIST

After implementation:

### Feature 5: Custom Install Path
- [ ] Test absolute path installation
- [ ] Test relative path installation (converted to absolute)
- [ ] Test path doesn't exist (error message)
- [ ] Test path not writable (error message)
- [ ] Verify config stores absolute path

### Feature 6: Multiple Binary Operations
- [ ] Test multiple remove operations
- [ ] Test multiple pin operations
- [ ] Test multiple unpin operations
- [ ] Test multiple update operations
- [ ] Test continue-on-error (some succeed, some fail)
- [ ] Test all operations fail (return error)
- [ ] Test summary output

### Feature 7: Explicit Provider Selection
- [ ] Test full URL format (https://)
- [ ] Test domain format (github.com/)
- [ ] Test short format with default github
- [ ] Test short format with explicit provider (gitlab, codeberg)
- [ ] Test invalid provider (error message)
- [ ] Test invalid URL format (error message)

### Feature 8: Per-Command Help
- [ ] Test `bin help` (shows general help)
- [ ] Test `bin help install` (shows detailed install help)
- [ ] Test `bin help` for all commands
- [ ] Test `bin help invalid` (shows error)

---

## SUMMARY OF KEY DECISIONS

1. **Path Validation**: Path must exist and be writable. Not created automatically. User is notified if path is invalid.

2. **Error Reporting**: For multiple operations, if ALL operations fail, return an error. If some succeed, continue processing and report summary of failures.

3. **Help Command**: Included in general help output. `bin help` shows general help, `bin help <command>` shows detailed help.

4. **URL Format Validation**: Validates that short format (user/repo) contains exactly one slash with non-empty parts.

5. **Multiple Operations Summary**: Shows success count and simple list of failed names.

6. **Continue-on-Error Strategy**: Process all operations regardless of individual failures. Report summary at the end.
