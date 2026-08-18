const std = @import("std");
const config = @import("config");

test "config: Config init sets empty state" {
    const allocator = std.testing.allocator;
    var conf = config.Config.init(allocator);
    defer conf.deinit();

    try std.testing.expectEqual(@as(usize, 0), conf.bins.count());
    try std.testing.expectEqual(@as(usize, 0), conf.default_path.len);
}

test "config: expandEnv expands $VAR and ${VAR}" {
    const allocator = std.testing.allocator;
    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("HOME", "/home/test");

    const out = try config.expandEnv(allocator, "$HOME/.bin", env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/home/test/.bin", out);

    const out2 = try config.expandEnv(allocator, "${HOME}/bin", env);
    defer allocator.free(out2);
    try std.testing.expectEqualStrings("/home/test/bin", out2);

    const out3 = try config.expandEnv(allocator, "no-vars", env);
    defer allocator.free(out3);
    try std.testing.expectEqualStrings("no-vars", out3);
}

test "config: save/load round-trips the JSON schema" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "config.json" });
    defer allocator.free(config_path);

    // Create the file so getConfigPath accepts BIN_CONFIG, with a default
    // path already set (avoids the interactive default-path prompt).
    {
        const f = try std.fs.cwd().createFile(config_path, .{});
        defer f.close();
        try f.writeAll("{\n    \"default_path\": \"/tmp/bin\",\n    \"bins\": {}\n}");
    }

    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("BIN_CONFIG", config_path);

    {
        var conf = try config.load(allocator, env);
        defer conf.deinit();
        try conf.bins.put("/usr/bin/gh", .{
            .path = "/usr/bin/gh",
            .remote_name = "gh",
            .version = "v2.40.0",
            .hash = "abc123",
            .url = "https://github.com/cli/cli",
            .provider = "github",
            .package_path = "bin/gh",
            .selected_asset = "gh_2.40.0_linux_amd64.tar.gz",
            .pinned = true,
        });
        try config.save(&conf);
    }

    {
        var conf = try config.load(allocator, env);
        defer conf.deinit();
        const b = conf.bins.get("/usr/bin/gh") orelse return error.TestFailed;
        try std.testing.expectEqualStrings("gh", b.remote_name);
        try std.testing.expectEqualStrings("v2.40.0", b.version);
        try std.testing.expectEqualStrings("abc123", b.hash);
        try std.testing.expectEqualStrings("bin/gh", b.package_path);
        try std.testing.expectEqualStrings("gh_2.40.0_linux_amd64.tar.gz", b.selected_asset);
        try std.testing.expect(b.pinned);
    }
}

test "config: getConfigPath resolution honors BIN_CONFIG" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);
    const config_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "myconf.json" });
    defer allocator.free(config_path);
    const f = try std.fs.cwd().createFile(config_path, .{});
    f.close();

    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    try env.put("BIN_CONFIG", config_path);
    const out = try config.getConfigPath(allocator, env);
    defer allocator.free(out);
    try std.testing.expectEqualStrings(config_path, out);
}

test "config: getBinPath finds managed binaries by basename" {
    const allocator = std.testing.allocator;
    var conf = config.Config.init(allocator);
    defer conf.deinit();
    try conf.bins.put("/home/u/.local/bin/gh", .{
        .path = "/home/u/.local/bin/gh",
        .remote_name = "gh",
        .version = "v2.40.0",
        .url = "https://github.com/cli/cli",
        .provider = "github",
    });

    var env = std.process.EnvMap.init(allocator);
    defer env.deinit();
    const out = try config.getBinPath(allocator, &conf, env, "gh");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("/home/u/.local/bin/gh", out);
}
