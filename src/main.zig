const std = @import("std");
const config = @import("config.zig");
const install_cmd = @import("install.zig");
const list_cmd = @import("list.zig");
const remove_cmd = @import("remove.zig");
const update_cmd = @import("update.zig");
const ensure_cmd = @import("ensure.zig");
const pin_cmd = @import("pin.zig");
const prune_cmd = @import("prune.zig");
const clean_cmd = @import("clean.zig");
const info_cmd = @import("info.zig");

fn collectNames(allocator: std.mem.Allocator, args_iter: *std.process.Args.Iterator) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    errdefer names.deinit(allocator);

    while (args_iter.next()) |name| {
        try names.append(allocator, name);
    }

    if (names.items.len == 0) {
        return error.NoNamesProvided;
    }

    return names.toOwnedSlice(allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    // Get args iterator using the Init struct's args
    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    // Skip executable name
    _ = args_iter.next();

    // Get command
    const command_maybe = args_iter.next();
    if (command_maybe == null) {
        printHelp();
        return;
    }
    const command = command_maybe.?;

    // Load config
    var conf = try config.load(allocator, init.minimal.environ, init.io);
    defer conf.deinit();

    // Validate config
    try config.validate(&conf, init.io);

    const builtin = @import("builtin");
    if (conf.bin_dir.len == 0) {
        if (builtin.os.tag == .windows) {
            const local_app_data = init.minimal.environ.getAlloc(allocator, "LOCALAPPDATA") catch try init.minimal.environ.getAlloc(allocator, "USERPROFILE");
            defer allocator.free(local_app_data);
            const path = try std.fs.path.join(conf.arena.allocator(), &[_][]const u8{ local_app_data, "bin" });
            conf.bin_dir = path;
        } else {
            const home = init.minimal.environ.getAlloc(allocator, "HOME") catch return error.HomeNotFound;
            defer allocator.free(home);
            const path = try std.fs.path.join(conf.arena.allocator(), &[_][]const u8{ home, ".local", "bin" });
            conf.bin_dir = path;
        }
    }

    if (std.mem.eql(u8, command, "install")) {
        var url: ?[]const u8 = null;
        var alias: ?[]const u8 = null;
        var interactive = false;
        var provider: ?install_cmd.Provider = null;
        var install_path: ?[]const u8 = null;

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
                provider = if (std.mem.eql(u8, prov_str, "github")) .github else if (std.mem.eql(u8, prov_str, "gitlab")) .gitlab else if (std.mem.eql(u8, prov_str, "codeberg")) .codeberg else {
                    std.log.err("Unknown provider: {s}", .{prov_str});
                    std.log.err("Supported providers: github, gitlab, codeberg", .{});
                    return;
                };
            } else if (url == null) {
                url = arg;
            } else if (install_path == null) {
                install_path = arg;
            }
        }

        if (url == null) {
            std.log.err("Usage: bin install <url> [--as <name>] [-a] [--provider <type>] [path]", .{});
            return;
        }

        try install_cmd.install(allocator, &conf, url.?, init.minimal.environ, init.io, .{ .alias = alias, .interactive = interactive, .provider = provider, .install_path = install_path });
    } else if (std.mem.eql(u8, command, "update")) {
        var targets = std.ArrayList([]const u8).empty;
        defer targets.deinit(allocator);

        var all_flag = false;

        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--all")) {
                all_flag = true;
            } else {
                try targets.append(allocator, arg);
            }
        }

        try update_cmd.update(allocator, &conf, if (targets.items.len == 0) null else targets.items, all_flag, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "list")) {
        try list_cmd.list(allocator, &conf);
    } else if (std.mem.eql(u8, command, "remove")) {
        const names = try collectNames(allocator, &args_iter);
        defer allocator.free(names);

        try remove_cmd.remove(allocator, &conf, names, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "ensure")) {
        try ensure_cmd.ensure(allocator, &conf, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "pin")) {
        const names = try collectNames(allocator, &args_iter);
        defer allocator.free(names);

        try pin_cmd.pin(allocator, &conf, names, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "unpin")) {
        const names = try collectNames(allocator, &args_iter);
        defer allocator.free(names);

        try pin_cmd.unpin(allocator, &conf, names, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "prune")) {
        try prune_cmd.prune(allocator, &conf, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "clean")) {
        try clean_cmd.clean(allocator, &conf, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "info")) {
        try info_cmd.info(allocator, &conf, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "help")) {
        const subcommand = args_iter.next();
        if (subcommand == null) {
            printHelp();
            return;
        }
        printCommandHelp(subcommand.?);
        return;
    } else if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        printHelp();
    } else if (std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        std.debug.print("bin-zig 0.1.0\n", .{});
    } else {
        std.log.err("Unknown command: {s}", .{command});
        printHelp();
    }
}

fn printHelp() void {
    std.debug.print(
        \\Usage: bin <command> [args]
        \\
        \\Commands:
        \\  install <url>    Install from GitHub, GitLab, or Codeberg
        \\                   URL formats: https://, domain (github.com/), or short (user/repo)
        \\                   Arguments: [path] custom install directory (must exist, must be writable)
        \\                   Flags: --as <name> to rename binary
        \\                          -a, --all-assets to interactively select assets
        \\                          --provider <type> for explicit provider (github/gitlab/codeberg)
        \\  update [name...] Update installed binaries (specific or all)
        \\                   Flags: --all to update all binaries
        \\  list             List installed binaries and versions
        \\  remove <name...> Remove installed binaries (works with .exe)
        \\  ensure           Verify and reinstall missing binaries
        \\  pin <name...>    Lock binaries to current versions
        \\  unpin <name...>  Unlock binaries for updates
        \\  prune            Remove dead entries from configuration
        \\  clean            Clear download/extraction cache
        \\  info             Show API rate limit information
        \\  help [command]   Show help for specific command
        \\
        \\Global Flags:
        \\  -h, --help       Display this help and exit
        \\  -v, --version    Output version information and exit
        \\
    , .{});
}

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
