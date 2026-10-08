const std = @import("std");
const cli = @import("cli.zig");
const config = @import("config.zig");
const install_mod = @import("install.zig");
const prompt = @import("prompt.zig");
const providers = @import("providers.zig");
const semver = @import("semver.zig");

pub const UpdateOpts = struct {
    yes_to_update: bool = false,
    dry_run: bool = false,
    all: bool = false,
    skip_path_check: bool = false,
    continue_on_error: bool = false,
    /// Binaries to leave alone, as names or managed paths (repeatable, like the
    /// reference's --exclude/-x StringSlice flag).
    exclude: []const []const u8 = &.{},
};

const UpdateInfo = struct {
    version: []const u8,
    url: []const u8,
};

/// Mirrors cmd/update.go of the reference implementation.
pub fn update(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, args: []const []const u8, opts: UpdateOpts) !void {
    // Process-lifetime and thread-safe: a stalled attempt can be abandoned while
    // still inside this client (see timeout.zig), so it is never torn down, and
    // its allocator must be safe to use from the attempt threads.
    var client = std.http.Client{ .allocator = std.heap.smp_allocator };
    try client.ca_bundle.rescan(std.heap.smp_allocator);

    // Resolve which binaries to process.
    var bins_to_process = std.StringHashMap(config.Binary).init(allocator);
    defer bins_to_process.deinit();
    var bin_paths = std.ArrayList([]const u8).empty;
    defer bin_paths.deinit(allocator);

    if (args.len > 0) {
        for (args) |a| {
            const bin = resolveManagedPath(allocator, conf, env, a) catch |err| {
                if (err == error.NotManaged) std.log.err("binary {s} is not managed by bin", .{a});
                return err;
            };
            const b = conf.bins.get(bin) orelse {
                std.log.err("binary {s} is not managed by bin", .{bin});
                return error.NotManaged;
            };
            try bins_to_process.put(bin, b);
            try bin_paths.append(allocator, bin);
        }
    } else {
        var it = conf.bins.iterator();
        while (it.next()) |entry| {
            try bins_to_process.put(entry.key_ptr.*, entry.value_ptr.*);
            try bin_paths.append(allocator, entry.key_ptr.*);
        }
    }

    // Excluded binaries (--exclude/-x): each value resolves to a config key
    // exactly like a positional argument does, and the entry is then skipped
    // with the reference's log line.
    var excluded = std.StringHashMap(void).init(allocator);
    defer excluded.deinit();
    for (opts.exclude) |e| {
        const key = resolveManagedPath(allocator, conf, env, e) catch |err| {
            if (err == error.NotManaged) std.log.err("binary {s} is not managed by bin", .{e});
            return err;
        };
        try excluded.put(key, {});
    }

    var to_update = std.ArrayList(struct { info: UpdateInfo, bin: config.Binary, path: []const u8 }).empty;
    defer to_update.deinit(allocator);
    var update_failures = std.ArrayList([]const u8).empty;
    defer update_failures.deinit(allocator);

    // Build the list of binaries that need a network version check (skipping
    // excluded and pinned ones with the same log lines as the reference).
    var jobs = std.ArrayList(CheckJob).empty;
    defer jobs.deinit(std.heap.smp_allocator);
    for (bin_paths.items) |p| {
        const b = bins_to_process.get(p).?;
        if (excluded.contains(p)) {
            std.log.info("{s} is excluded from updates", .{p});
            continue;
        }
        if (b.pinned) {
            std.log.info("{s} is a pinned binary", .{p});
            continue;
        }
        try jobs.append(std.heap.smp_allocator, .{ .path = p, .bin = b });
    }

    // Check all binaries concurrently: the version checks are independent
    // network round-trips, so a small thread pool turns ~N seconds of
    // sequential latency into ~N/parallelism. The workers allocate from the
    // thread-safe std.heap.smp_allocator (the main arena is not thread-safe).
    var check_ctx = CheckCtx{
        .allocator = std.heap.smp_allocator,
        .conf = conf,
        .jobs = jobs.items,
    };
    const parallelism = @min(jobs.items.len, default_update_parallelism);
    if (parallelism > 1 and jobs.items.len > 1) {
        var threads = try std.heap.smp_allocator.alloc(std.Thread, parallelism);
        defer std.heap.smp_allocator.free(threads);
        for (0..parallelism) |i| {
            threads[i] = try std.Thread.spawn(.{}, checkWorker, .{&check_ctx});
        }
        for (threads) |t| t.join();
    } else if (jobs.items.len == 1) {
        checkWorker(&check_ctx);
    }

    var results = check_ctx.results;
    defer results.deinit(std.heap.smp_allocator);

    for (results.items) |r| {
        const p = r.path;
        if (r.err) |err| {
            if (opts.continue_on_error) {
                try update_failures.append(allocator, try std.fmt.allocPrint(allocator, "Error while getting latest version of {s}: {s}", .{ p, @errorName(err) }));
                continue;
            }
            return err;
        }
        if (r.info) |info| {
            try to_update.append(allocator, .{ .info = info, .bin = r.bin, .path = p });
        }
    }

    if (to_update.items.len == 0 and update_failures.items.len == 0) {
        std.log.info("All binaries are up to date", .{});
        return;
    }

    if (opts.dry_run) {
        std.log.err("Updates found, exit (dry-run mode).", .{});
        return error.DryRunExit;
    }

    if (to_update.items.len > 0 and !opts.yes_to_update) {
        for (update_failures.items) |f| std.log.warn("{s}", .{f});
        update_failures.clearRetainingCapacity();
        try prompt.confirm("Do you want to continue?");
    }

    for (to_update.items) |item| {
        const ui = item.info;
        const b = item.bin;

        var provider = providers.Provider.new(allocator, ui.url, b.provider) catch |err| {
            if (opts.continue_on_error) {
                try update_failures.append(allocator, try std.fmt.allocPrint(allocator, "Error while creating provider for {s}: {s}", .{ ui.url, @errorName(err) }));
                continue;
            }
            return err;
        };
        std.log.debug("Using provider '{s}' for '{s}'", .{ provider.getID(), ui.url });

        const p_result = provider.fetch(allocator, &client, fetchOptsFor(opts, b)) catch |err| {
            if (opts.continue_on_error) {
                try update_failures.append(allocator, try std.fmt.allocPrint(allocator, "Error while fetching {s}: {s}", .{ ui.url, @errorName(err) }));
                continue;
            }
            return err;
        };

        const hash = try install_mod.saveToDisk(allocator, env, p_result.name, p_result.version, p_result.data, b.path, true);

        // Note: Pinned is intentionally NOT preserved here (matches the
        // reference implementation).
        try config.upsertBinary(conf, .{
            .path = b.path,
            .remote_name = p_result.name,
            .version = p_result.version,
            .hash = hash,
            .url = ui.url,
            .provider = provider.getID(),
            .package_path = p_result.package_path,
            .selected_asset = p_result.selected_asset,
        });

        const expanded = try config.expandEnv(allocator, b.path, env);
        defer allocator.free(expanded);
        std.log.info("Done updating {s} to {s}", .{ expanded, cli.green(ui.version) });
    }

    for (update_failures.items) |f| std.log.warn("{s}", .{f});
}

/// Resolves a positional argument or an --exclude value to the config key it
/// names. A value that is neither in PATH nor managed by bin comes back as
/// error.NotManaged, instead of the bare error.FileNotFound that lookPath
/// reports for it.
///
/// Deliberately log-free: the test runner counts every err-level log as a test
/// failure, so the user-facing message belongs to the call sites.
fn resolveManagedPath(allocator: std.mem.Allocator, conf: *config.Config, env: std.process.EnvMap, arg: []const u8) ![]const u8 {
    return config.getBinPath(allocator, conf, env, arg) catch |err| switch (err) {
        error.FileNotFound, error.BinPathNotFound => return error.NotManaged,
        else => return err,
    };
}

/// Fetch options for updating `b`. AutoSelectPrevious mirrors the reference
/// (marcosnils/bin#312): outside --all, the artefact picked on the previous
/// install/upgrade is re-selected without prompting, exactly as `ensure`
/// already does. Without it `update` always shows the candidate menu — the
/// "Showing N assets out of M. Select an option" prompt — even when the
/// stored selection is unambiguous.
pub fn fetchOptsFor(opts: UpdateOpts, b: config.Binary) providers.FetchOpts {
    return .{
        .all = opts.all,
        .package_name = b.remote_name,
        .package_path = b.package_path,
        .skip_path_check = opts.skip_path_check,
        .previous_asset = b.selected_asset,
        .previous_version = b.version,
        .auto_select_previous = !opts.all,
    };
}

/// Mirrors cmd/getLatestVersion: no update when versions are equal or when the
/// current version is a semver >= the latest.
fn getLatestVersion(allocator: std.mem.Allocator, client: *std.http.Client, b: *const config.Binary, p: *providers.Provider) !?UpdateInfo {
    std.log.debug("Checking updates for {s}", .{b.path});
    const latest = try p.getLatestVersion(allocator, client);

    if (std.mem.eql(u8, b.version, latest.version)) return null;

    const b_semver = semver.parse(b.version);
    const v_semver = semver.parse(latest.version);
    if (b_semver != null and v_semver != null) {
        const order = semver.compare(v_semver.?, b_semver.?);
        if (order != .gt) return null;
    }

    std.log.debug("Found new version {s} for {s} at {s}", .{ latest.version, b.path, latest.url });
    std.log.info("{s} {s} -> {s} ({s})", .{ b.path, cli.yellow(b.version), cli.green(latest.version), latest.url });
    return .{ .version = latest.version, .url = latest.url };
}

// ---------------------------------------------------------------------------
// Parallel update checking
// ---------------------------------------------------------------------------

const default_update_parallelism = 10;

const CheckJob = struct {
    path: []const u8,
    bin: config.Binary,
};

const CheckResult = struct {
    path: []const u8,
    bin: config.Binary,
    info: ?UpdateInfo = null,
    err: ?anyerror = null,
};

const CheckCtx = struct {
    allocator: std.mem.Allocator,
    conf: *config.Config,
    jobs: []const CheckJob,
    next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    mutex: std.Thread.Mutex = .{},
    results: std.ArrayList(CheckResult) = .empty,
};

fn checkWorker(ctx: *CheckCtx) void {
    // Each worker gets its own HTTP client: concurrent TLS handshakes on a
    // shared client race in the 0.15.2 stdlib. Per-worker clients still get
    // keep-alive reuse across the requests that worker performs.
    var client = std.http.Client{ .allocator = ctx.allocator };
    client.ca_bundle.rescan(ctx.allocator) catch return;
    // Not deinit'ed: an abandoned attempt (see timeout.zig) can still be inside
    // this client. `ctx.allocator` is already the thread-safe smp allocator.

    while (true) {
        const i = ctx.next.fetchAdd(1, .monotonic);
        if (i >= ctx.jobs.len) break;
        const job = ctx.jobs[i];

        var result = CheckResult{ .path = job.path, .bin = job.bin };
        var provider = providers.Provider.new(ctx.allocator, job.bin.url, job.bin.provider) catch |err| {
            result.err = err;
            ctx.mutex.lock();
            defer ctx.mutex.unlock();
            ctx.results.append(ctx.allocator, result) catch {};
            continue;
        };
        std.log.debug("Using provider '{s}' for '{s}'", .{ provider.getID(), job.bin.url });

        result.info = getLatestVersion(ctx.allocator, &client, &job.bin, &provider) catch |err| blk: {
            result.err = err;
            break :blk null;
        };
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        ctx.results.append(ctx.allocator, result) catch {};
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "update: fetchOptsFor re-selects the previous artefact unless --all" {
    const b = config.Binary{
        .path = "/home/u/.local/bin/tool",
        .remote_name = "tool",
        .version = "v1.0.0",
        .hash = "abc123",
        .url = "https://github.com/x/tool",
        .provider = "github",
        .package_path = "bin/tool",
        .selected_asset = "tool_1.0.0_linux_amd64.tar.gz",
    };

    // Default: the artefact chosen on the previous install is re-selected
    // without prompting (marcosnils/bin#312 — `ensure` always did this,
    // `update` did not, so it always showed the candidate menu).
    const o = fetchOptsFor(.{}, b);
    try std.testing.expect(o.auto_select_previous);
    try std.testing.expect(!o.all);
    try std.testing.expectEqualStrings(b.selected_asset, o.previous_asset);
    try std.testing.expectEqualStrings(b.version, o.previous_version);
    try std.testing.expectEqualStrings(b.remote_name, o.package_name);
    try std.testing.expectEqualStrings(b.package_path, o.package_path);

    // --all asks for every candidate, so nothing is auto-selected.
    const all = fetchOptsFor(.{ .all = true }, b);
    try std.testing.expect(all.all);
    try std.testing.expect(!all.auto_select_previous);
}

test "update: --exclude resolves names to config keys and rejects unmanaged ones" {
    const allocator = std.testing.allocator;
    var conf = config.Config.init(allocator);
    defer conf.deinit();
    try conf.bins.put("/home/u/.local/bin/tool", .{
        .path = "/home/u/.local/bin/tool",
        .remote_name = "tool",
        .version = "v1.0.0",
        .url = "https://github.com/x/tool",
        .provider = "github",
    });

    // An empty environment keeps the PATH lookup from finding anything, so the
    // name resolves through the managed-binary fallback.
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    const resolved = try resolveManagedPath(allocator, &conf, env, "tool");
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings("/home/u/.local/bin/tool", resolved);

    // A value bin does not manage is an error, not a silent no-op.
    try std.testing.expectError(error.NotManaged, resolveManagedPath(allocator, &conf, env, "not-managed"));
}

test "update: an excluded binary is never version-checked" {
    // update() keeps scratch allocations for its whole lifetime (the caller
    // passes an arena), so the test uses one too.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var conf = config.Config.init(allocator);
    defer conf.deinit();
    try conf.bins.put("/home/u/.local/bin/tool", .{
        .path = "/home/u/.local/bin/tool",
        .remote_name = "tool",
        .version = "v1.0.0",
        // Unresolvable on purpose: if --exclude ever stops skipping this entry
        // the version check runs, fails on the host name, and the test fails.
        .url = "https://invalid.invalid/x/tool",
        .provider = "github",
    });

    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();

    // The only managed binary is excluded, so nothing is checked at all.
    try update(allocator, &conf, env, &.{}, .{ .exclude = &.{"tool"} });
}
