const std = @import("std");
const cli = @import("cli.zig");
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

pub const std_options: std.Options = .{
    .log_level = .debug,
    .logFn = cli.logFn,
};

/// Maps a Zig error to the reference's Go-style error message text.
fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.CommandAborted => "command aborted",
        error.InvalidInput => "invalid input",
        error.DryRunExit => "Updates found, exit (dry-run mode).",
        else => @errorName(err),
    };
}

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

    cli.init(env);

    var args = std.ArrayList([]const u8).empty;
    while (args_iter.next()) |a| try args.append(allocator, a);

    var exit_code: u8 = 0;
    run(allocator, env, args.items[1..]) catch |err| {
        exit_code = switch (err) {
            error.DryRunExit => 3,
            else => 1,
        };
        cli.errorLine("command failed", errorMessage(err));
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
    cli.debug_enabled = debug;
    if (debug) std.log.info("debug logs enabled, version: {s}", .{version_string});

    // No arguments defaults to `list` (reference behavior).
    if (argv.len == 0) {
        var conf = try config.load(allocator, env);
        defer conf.deinit();
        return list_cmd.list(allocator, &conf, env);
    }

    const command = argv[0];

    // Root-level flags.
    if (std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) {
        printHelp();
        return;
    }
    if (std.mem.eql(u8, command, "help")) {
        if (argv.len > 1) {
            if (resolveCommand(argv[1])) |sub| {
                printCommandHelp(sub);
                return;
            }
        }
        printHelp();
        return;
    }
    if (std.mem.eql(u8, command, "-v") or std.mem.eql(u8, command, "--version")) {
        std.debug.print("bin version {s}\n", .{version_string});
        return;
    }

    const cmd_name = resolveCommand(command) orelse {
        cli.stderrLine("unknown command: bin {s}\n", .{command});
        std.process.exit(1);
    };

    // Per-command help (cobra intercepts -h/--help before running the command).
    for (argv[1..]) |a| {
        if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            printCommandHelp(cmd_name);
            return;
        }
    }

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
    } else if (std.mem.eql(u8, cmd_name, "completion")) {
        return cmdCompletion(argv[1..]);
    }
    unreachable;
}

fn cmdCompletion(args: []const []const u8) !void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")) {
        printCompletionHelp();
        return;
    }
    const shell = args[0];
    if (std.mem.eql(u8, shell, "bash") or std.mem.eql(u8, shell, "zsh") or std.mem.eql(u8, shell, "fish") or std.mem.eql(u8, shell, "powershell")) {
        std.debug.print("{s}", .{completionScript(shell)});
        return;
    }
    std.log.err("invalid argument \"{s}\" for \"bin completion\"", .{shell});
    std.log.err("valid arguments are: \"bash\", \"fish\", \"powershell\", \"zsh\"", .{});
    return error.InvalidArgument;
}

fn completionScript(shell: []const u8) []const u8 {
    const commands = "completion ensure help install list pin prune remove unpin update clean info";
    if (std.mem.eql(u8, shell, "bash")) {
        return tryCatch("\n# bash completion for bin\n_bin_completions() {{\n    local cur=\"${{COMP_WORDS[COMP_CWORD]}}\"\n    COMPREPLY=( $(compgen -W \"{s}\" -- \"${{cur}}\") )\n}}\ncomplete -F _bin_completions bin\n", .{commands});
    } else if (std.mem.eql(u8, shell, "zsh")) {
        return tryCatch("\n#compdef bin\n_bin() {{\n    local -a cmds\n    cmds=({s})\n    _describe 'command' cmds\n}}\ncompdef _bin bin\n", .{commands});
    } else if (std.mem.eql(u8, shell, "fish")) {
        return tryCatch("\n# fish completion for bin\ncomplete -c bin -f -a '{s}'\n", .{commands});
    }
    return tryCatch("\n# powershell completion for bin\nRegister-ArgumentCompleter -Native -CommandName bin -ScriptBlock {{\n    param($wordToComplete, $commandAst, $cursorPosition)\n    '{s}'.Split(' ') | Where-Object {{ $_ -like \"$wordToComplete*\" }} | ForEach-Object {{ [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }}\n}}\n", .{commands});
}

fn tryCatch(comptime fmt: []const u8, args: anytype) []const u8 {
    var buf: [4096]u8 = undefined;
    return std.fmt.bufPrint(&buf, fmt, args) catch "";
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
        .{ "completion", "completion" },
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
        } else {
            try names.append(allocator, a);
        }
    }
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
        \\  completion  Generate the autocompletion script for the specified shell
        \\  ensure      Ensures that all binaries listed in the configuration are present
        \\  help        Help about any command
        \\  install     Installs the specified binary from a url
        \\  list        List binaries managed by bin
        \\  pin         Pins current version of the binaries
        \\  prune       Prunes binaries that no longer exist in the system
        \\  remove      Removes binaries managed by bin
        \\  unpin       Unpins current version of the binaries
        \\  update      Updates one or multiple binaries managed by bin
        \\  clean       Clears the download cache (zig extension)
        \\  info        Shows API rate limit information (zig extension)
        \\
        \\Flags:
        \\      --debug     Enable debug mode
        \\  -h, --help      help for bin
        \\  -v, --version   version for bin
        \\
        \\Use "bin [command] --help" for more information about a command.
        \\
    , .{});
}

fn printCompletionHelp() void {
    std.debug.print(
        \\Generate the autocompletion script for bin for the specified shell.
        \\See each sub-command's help for details on how to use the generated script.
        \\
        \\Usage:
        \\  bin completion [command]
        \\
        \\Available Commands:
        \\  bash        Generate the autocompletion script for bash
        \\  fish        Generate the autocompletion script for fish
        \\  powershell  Generate the autocompletion script for powershell
        \\  zsh         Generate the autocompletion script for zsh
        \\
        \\Flags:
        \\  -h, --help   help for completion
        \\
        \\Global Flags:
        \\      --debug   Enable debug mode
        \\
        \\Use "bin completion [command] --help" for more information about a command.
        \\
    , .{});
}

/// Per-command help in cobra's layout (Usage + Flags).
fn printCommandHelp(command: []const u8) void {
    if (std.mem.eql(u8, command, "install")) {
        std.debug.print(
            \\Installs the specified binary from a url
            \\
            \\Usage:
            \\  bin install <url> [name | path] [flags]
            \\
            \\Aliases:
            \\  install, i
            \\
            \\Flags:
            \\  -a, --all               Show all possible download options (skip scoring & filtering)
            \\  -f, --force             Force the installation even if the file already exists
            \\  -h, --help              help for install
            \\  -n, --name string       Glob pattern to select a specific asset (use asset/file for archive contents)
            \\  -p, --provider string   Forces to use a specific provider
            \\
            \\Global Flags:
            \\      --debug   Enable debug mode
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "update")) {
        std.debug.print(
            \\Updates one or multiple binaries managed by bin
            \\
            \\Usage:
            \\  bin update [binary_path] [flags]
            \\
            \\Aliases:
            \\  update, u
            \\
            \\Flags:
            \\  -a, --all                 Show all possible download options (skip scoring & filtering)
            \\  -c, --continue-on-error   Continues to update next package if an error is encountered
            \\      --dry-run             Only show status, don't prompt for update
            \\  -h, --help                help for update
            \\  -p, --skip-path-check     Skips path checking when looking into packages
            \\  -y, --yes                 Assume yes to update prompt
            \\
            \\Global Flags:
            \\      --debug   Enable debug mode
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "ensure")) {
        std.debug.print(
            \\Ensures that all binaries listed in the configuration are present
            \\
            \\Usage:
            \\  bin ensure [binary_path]... [flags]
            \\
            \\Aliases:
            \\  ensure, e
            \\
            \\Flags:
            \\  -h, --help   help for ensure
            \\
            \\Global Flags:
            \\      --debug   Enable debug mode
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "list")) {
        std.debug.print(
            \\List binaries managed by bin
            \\
            \\Usage:
            \\  bin list [flags]
            \\
            \\Aliases:
            \\  list, ls
            \\
            \\Flags:
            \\  -h, --help   help for list
            \\
            \\Global Flags:
            \\      --debug   Enable debug mode
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "pin")) {
        std.debug.print(
            \\Pins current version of the binaries
            \\
            \\Usage:
            \\  bin pin [<name> | <paths...>] [flags]
            \\
            \\Flags:
            \\  -h, --help   help for pin
            \\
            \\Global Flags:
            \\      --debug   Enable debug mode
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "unpin")) {
        std.debug.print(
            \\Unpins current version of the binaries
            \\
            \\Usage:
            \\  bin unpin [<name> | <paths...>] [flags]
            \\
            \\Flags:
            \\  -h, --help   help for unpin
            \\
            \\Global Flags:
            \\      --debug   Enable debug mode
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "remove")) {
        std.debug.print(
            \\Removes binaries managed by bin
            \\
            \\Usage:
            \\  bin remove [<name> | <paths...>] [flags]
            \\
            \\Aliases:
            \\  remove, rm
            \\
            \\Flags:
            \\  -h, --help   help for remove
            \\
            \\Global Flags:
            \\      --debug   Enable debug mode
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "prune")) {
        std.debug.print(
            \\Prunes binaries that no longer exist in the system
            \\
            \\Usage:
            \\  bin prune [flags]
            \\
            \\Flags:
            \\  -f, --force   Bypass confirmation prompt
            \\  -h, --help    help for prune
            \\
            \\Global Flags:
            \\      --debug   Enable debug mode
            \\
        , .{});
    } else if (std.mem.eql(u8, command, "completion")) {
        printCompletionHelp();
    } else if (std.mem.eql(u8, command, "clean") or std.mem.eql(u8, command, "info")) {
        printHelp();
    } else {
        printHelp();
    }
}
