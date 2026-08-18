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

const version_string = "dev";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const gpa_allocator = gpa.allocator();

    // The whole program is arena-backed: releases and installs allocate
    // liberally with the understanding that everything is freed at exit.
    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args_iter = try std.process.argsWithAllocator(allocator);
    defer args_iter.deinit();

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();

    var args = std.ArrayList([]const u8).empty;
    while (args_iter.next()) |a| try args.append(allocator, a);

    var exit_code: u8 = 0;
    run(allocator, env, args.items[1..]) catch |err| {
        exit_code = switch (err) {
            error.DryRunExit => 3,
            else => 1,
        };
        std.log.err("command failed: {s}", .{@errorName(err)});
    };

    std.process.exit(exit_code);
}

fn run(allocator: std.mem.Allocator, env: std.process.EnvMap, args: []const []const u8) !void {
    // Global --debug flag (cobra persistent flag: may appear anywhere).
    var debug = false;
    var filtered = std.ArrayList([]const u8).empty;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--debug")) {
            debug = true;
        } else {
            try filtered.append(allocator, a);
        }
    }
    const argv = filtered.items;
    if (debug) std.log.info("debug logs enabled, version: {s}", .{version_string});

    // No arguments defaults to `list` (reference behavior).
    if (argv.len == 0) {
        var conf = try config.load(allocator, env);
        defer conf.deinit();
        return list_cmd.list(allocator, &conf, env);
    }

    const command = argv[0];

    // Root-level flags.
    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "help")) {
        printHelp();
        return;
    }
    if (std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        std.debug.print("{s}\n", .{version_string});
        return;
    }

    const cmd_name = resolveCommand(command) orelse {
        std.debug.print("unknown command: bin {s}\n", .{command});
        std.process.exit(1);
    };

    var conf = try config.load(allocator, env);
    defer conf.deinit();

    if (std.mem.eql(u8, cmd_name, "install")) {
        return cmdInstall(allocator, &conf, env, argv[1..]);
    } else if (std.mem.eql(u8, cmd_name, "update")) {
        return cmdUpdate(allocator, &conf, env, argv[1..]);
    } else if (std.mem.eql(u8, cmd_name, "list")) {
        return list_cmd.list(allocator, &conf, env);
    } else if (std.mem.eql(u8, cmd_name, "remove")) {
        return remove_cmd.remove(allocator, &conf, env, argv[1..]);
    } else if (std.mem.eql(u8, cmd_name, "ensure")) {
        return ensure_cmd.ensure(allocator, &conf, env, argv[1..]);
    } else if (std.mem.eql(u8, cmd_name, "pin")) {
        return pin_cmd.pin(allocator, &conf, env, argv[1..], true);
    } else if (std.mem.eql(u8, cmd_name, "unpin")) {
        return pin_cmd.pin(allocator, &conf, env, argv[1..], false);
    } else if (std.mem.eql(u8, cmd_name, "prune")) {
        return cmdPrune(allocator, &conf, env, argv[1..]);
    } else if (std.mem.eql(u8, cmd_name, "clean")) {
        return clean_cmd.clean(allocator, &conf, env);
    } else if (std.mem.eql(u8, cmd_name, "info")) {
        return info_cmd.info(allocator);
    }
    unreachable;
}

fn resolveCommand(command: []const u8) ?[]const u8 {
    const aliases = [_][2][]const u8{
        .{ "install", "install" },
        .{ "i", "install" },
        .{ "update", "update" },
        .{ "u", "update" },
        .{ "ensure", "ensure" },
        .{ "e", "ensure" },
        .{ "list", "list" },
        .{ "ls", "list" },
        .{ "remove", "remove" },
        .{ "rm", "remove" },
        .{ "pin", "pin" },
        .{ "unpin", "unpin" },
        .{ "prune", "prune" },
        .{ "clean", "clean" },
        .{ "info", "info" },
    };
    for (aliases) |pair| {
        if (std.mem.eql(u8, command, pair[0])) return pair[1];
    }
    return null;
}

fn cmdInstall(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, args: []const []const u8) !void {
    var opts = install_cmd.InstallOpts{};
    var positionals = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--provider")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            opts.provider = args[i];
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--name")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            opts.name_pattern = args[i];
        } else {
            try positionals.append(allocator, a);
        }
    }
    if (positionals.items.len == 0) {
        std.log.err("install requires a url", .{});
        return error.UrlRequired;
    }

    const url = positionals.items[0];
    var resolved_path: []const u8 = conf.default_path;
    if (positionals.items.len > 1) {
        resolved_path = positionals.items[1];
        // A name (no forward slash) is joined with the default path.
        if (std.mem.indexOfScalar(u8, resolved_path, '/') == null) {
            resolved_path = try std.fs.path.join(allocator, &[_][]const u8{ conf.default_path, resolved_path });
        }
    }

    return install_cmd.install(allocator, conf, env, url, resolved_path, opts);
}

fn cmdUpdate(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, args: []const []const u8) !void {
    var opts = update_cmd.UpdateOpts{};
    var names = std.ArrayList([]const u8).empty;
    var exclude = std.ArrayList([]const u8).empty;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--dry-run")) {
            opts.dry_run = true;
        } else if (std.mem.eql(u8, a, "-y") or std.mem.eql(u8, a, "--yes")) {
            opts.yes_to_update = true;
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--all")) {
            opts.all = true;
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--skip-path-check")) {
            opts.skip_path_check = true;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--continue-on-error")) {
            opts.continue_on_error = true;
        } else if (std.mem.eql(u8, a, "-x") or std.mem.eql(u8, a, "--exclude")) {
            i += 1;
            if (i >= args.len) return error.MissingFlagValue;
            try exclude.append(allocator, args[i]);
        } else {
            try names.append(allocator, a);
        }
    }
    opts.exclude = exclude.items;
    return update_cmd.update(allocator, conf, env, names.items, opts);
}

fn cmdPrune(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, args: []const []const u8) !void {
    var force = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--force")) force = true;
    }
    return prune_cmd.prune(allocator, conf, env, force);
}

fn printHelp() void {
    std.debug.print(
        \\Effortless binary manager
        \\
        \\Usage:
        \\  bin [command]
        \\
        \\Available Commands:
        \\  ensure    Ensures that all binaries listed in the configuration are present
        \\  help      Help about any command
        \\  install   Installs the specified binary from a url
        \\  list      List binaries managed by bin
        \\  pin       Pins current version of the binaries
        \\  prune     Prunes binaries that no longer exist in the system
        \\  remove    Removes binaries managed by bin
        \\  unpin     Unpins current version of the binaries
        \\  update    Updates one or multiple binaries managed by bin
        \\  clean     Clears the download cache (zig extension)
        \\  info      Shows API rate limit information (zig extension)
        \\
        \\Flags:
        \\      --debug   Enable debug mode
        \\  -h, --help    help for bin
        \\  -v, --version version for bin
        \\
        \\Use "bin [command] --help" for more information about a command.
        \\
    , .{});
}
