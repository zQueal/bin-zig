//! goinstall provider mirroring pkg/providers/goinstall.go: builds a Go
//! module binary with `go install module@version` and returns the resulting
//! binary from GOPATH/bin.

const std = @import("std");
const http_util = @import("http_util.zig");
const providers = @import("providers.zig");
const utils = @import("utils.zig");

pub const GoInstall = struct {
    name: []const u8,
    repo: []const u8,
    tag: []const u8,
    latest_url: []const u8,

    pub fn init(allocator: std.mem.Allocator, u: []const u8) !GoInstall {
        const repo_url = utils.stripPrefix(u, "goinstall://") orelse u;
        var repo = repo_url;
        var tag: []const u8 = "latest";
        if (std.mem.lastIndexOfScalar(u8, repo_url, '@')) |i| {
            repo = repo_url[0..i];
            tag = repo_url[i + 1 ..];
        }

        var name = repo;
        if (std.mem.lastIndexOfScalar(u8, repo, '/')) |i| {
            name = repo[i + 1 ..];
        }

        const latest_url = try std.fmt.allocPrint(allocator, "https://proxy.golang.org/{s}/@latest", .{repo});

        return .{
            .name = try allocator.dupe(u8, name),
            .repo = try allocator.dupe(u8, repo),
            .tag = try allocator.dupe(u8, tag),
            .latest_url = latest_url,
        };
    }

    pub fn getID() []const u8 {
        return "goinstall";
    }

    fn getGoPath(allocator: std.mem.Allocator) ![]const u8 {
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "go", "env", "GOPATH" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.log.err("command 'go env GOPATH' failed: {s}", .{result.stderr});
            return error.GoNotFound;
        }
        return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \t\r\n"));
    }

    pub fn fetch(self: *GoInstall, allocator: std.mem.Allocator, client: *std.http.Client, opts: providers.FetchOpts) !providers.File {
        const go_path = try getGoPath(allocator);

        var tag = self.tag;
        if (opts.version.len > 0) tag = opts.version;

        if (!(tag.len > 0 and !std.mem.eql(u8, tag, "latest"))) {
            std.log.info("Getting latest release for {s}", .{self.repo});
            const latest = try self.getLatestVersion(allocator, client);
            tag = latest.version;
        } else {
            std.log.info("Getting {s} release for {s}", .{ tag, self.repo });
        }

        const module = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ self.repo, tag });
        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "go", "install", module },
            .max_output_bytes = 10 * 1024 * 1024,
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.log.err("failed to install package: {s}", .{result.stderr});
            return error.GoInstallFailed;
        }

        const bin_path = try std.fs.path.join(allocator, &[_][]const u8{ go_path, "bin", self.name });
        const file = std.fs.openFileAbsolute(bin_path, .{}) catch |err| {
            std.log.err("failed to open path '{s}': {}", .{ bin_path, err });
            return err;
        };
        defer file.close();
        const size = (try file.stat()).size;
        const data = try allocator.alloc(u8, size);
        _ = try file.readAll(data);

        return .{
            .data = data,
            .name = try allocator.dupe(u8, self.name),
            .version = try allocator.dupe(u8, tag),
        };
    }

    pub fn getLatestVersion(self: *const GoInstall, allocator: std.mem.Allocator, client: *std.http.Client) !providers.Latest {
        const body = try http_util.getBody(allocator, client, self.latest_url, &.{}, 1024 * 1024);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        if (parsed.value != .object) return error.InvalidResponse;
        const version = parsed.value.object.get("Version") orelse {
            std.log.err("version not found in response", .{});
            return error.NoVersion;
        };
        if (version != .string) return error.InvalidResponse;
        return .{ .version = try allocator.dupe(u8, version.string), .url = try allocator.dupe(u8, self.repo) };
    }
};
