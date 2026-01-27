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
            }
        }

        if (url == null) {
            std.log.err("Usage: bin install <url> [--as <name>] [-a] [--provider <type>] [path]", .{});
            return;
        }

        try install_cmd.install(allocator, &conf, url.?, init.minimal.environ, init.io, .{ .alias = alias, .interactive = interactive, .provider = provider });
    } else if (std.mem.eql(u8, command, "update")) {
        var target: ?[]const u8 = null;
        var all_flag = false;

        while (args_iter.next()) |arg| {
            if (std.mem.eql(u8, arg, "--all")) {
                all_flag = true;
            } else if (target == null) {
                target = arg;
            }
        }
        try update_cmd.update(allocator, &conf, target, all_flag, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "list")) {
        try list_cmd.list(allocator, &conf);
    } else if (std.mem.eql(u8, command, "remove")) {
        const name = args_iter.next();
        if (name == null) {
            std.log.err("Usage: bin remove <name>", .{});
            return;
        }
        try remove_cmd.remove(allocator, &conf, name.?, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "ensure")) {
        try ensure_cmd.ensure(allocator, &conf, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "pin")) {
        const name = args_iter.next();
        if (name == null) {
            std.log.err("Usage: bin pin <name>", .{});
            return;
        }
        try pin_cmd.pin(allocator, &conf, name.?, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "unpin")) {
        const name = args_iter.next();
        if (name == null) {
            std.log.err("Usage: bin unpin <name>", .{});
            return;
        }
        try pin_cmd.unpin(allocator, &conf, name.?, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "prune")) {
        try prune_cmd.prune(allocator, &conf, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "clean")) {
        try clean_cmd.clean(allocator, &conf, init.minimal.environ, init.io);
    } else if (std.mem.eql(u8, command, "info")) {
        try info_cmd.info(allocator, &conf, init.minimal.environ, init.io);
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
        \\                   Flags: --as <name> to rename binary
        \\                          -a, --all-assets to interactively select assets
        \\                          --provider <type> for explicit provider (github/gitlab/codeberg)
        \\  update [name]    Update installed binaries (specific or all)
        \\                   Flags: --all to update all binaries
        \\  list             List installed binaries and versions
        \\  remove <name>    Remove installed binary (works with .exe)
        \\  ensure           Verify and reinstall missing binaries
        \\  pin <name>       Lock binary to current version
        \\  unpin <name>     Unlock binary for updates
        \\  prune            Remove dead entries from configuration
        \\  clean            Clear download/extraction cache
        \\  info             Show API rate limit information
        \\
        \\Global Flags:
        \\  -h, --help       Display this help and exit
        \\  -v, --version    Output version information and exit
        \\
    , .{});
}
