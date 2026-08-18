//! docker provider mirroring pkg/providers/docker.go: pulls a docker image and
//! installs a wrapper script that runs the image (docker run) with the current
//! directory mounted. The reference implementation talks to the docker daemon
//! SDK; this port shells out to the `docker` CLI for the pull, which is
//! behaviorally equivalent for end users.

const std = @import("std");
const providers = @import("providers.zig");
const utils = @import("utils.zig");

const sh_unix =
    \\#!/bin/sh
    \\termflag=$([ -t 0 ] && echo -n "-t")
    \\docker run --rm -i $termflag -v ${{PWD}}:/tmp/cmd -w /tmp/cmd {s}:{s} "$@"
;

const sh_windows =
    \\@echo off
    \\docker run --rm -i -t -v %cd%:/tmp/cmd -w /tmp/cmd {s}:{s} %*
\\
;

pub const Docker = struct {
    repo: []const u8,
    tag: []const u8,

    pub fn init(allocator: std.mem.Allocator, image_url: []const u8) !Docker {
        var image = utils.stripPrefix(image_url, "docker://") orelse image_url;
        var tag: []const u8 = "latest";
        if (std.mem.lastIndexOfScalar(u8, image, ':')) |i| {
            tag = image[i + 1 ..];
            image = image[0..i];
        }
        if (std.mem.count(u8, image, "/") == 0) {
            image = try std.fmt.allocPrint(allocator, "library/{s}", .{image});
        }
        return .{
            .repo = try allocator.dupe(u8, image),
            .tag = try allocator.dupe(u8, tag),
        };
    }

    pub fn getID() []const u8 {
        return "docker";
    }

    fn getImageName(repo: []const u8) []const u8 {
        var name = repo;
        if (std.mem.lastIndexOfScalar(u8, repo, '/')) |i| {
            name = repo[i + 1 ..];
        }
        return name;
    }

    pub fn fetch(self: *Docker, allocator: std.mem.Allocator, opts: providers.FetchOpts) !providers.File {
        var tag = self.tag;
        if (opts.version.len > 0) tag = opts.version;

        std.log.info("Pulling docker image {s}:{s}", .{ self.repo, tag });
        const image = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ self.repo, tag });

        // docker pull (the reference uses the daemon SDK; the CLI is the
        // equivalent user-facing operation).
        const pull_result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = &[_][]const u8{ "docker", "pull", image },
            .max_output_bytes = 64 * 1024 * 1024,
        });
        defer allocator.free(pull_result.stdout);
        defer allocator.free(pull_result.stderr);
        if (pull_result.term != .Exited or pull_result.term.Exited != 0) {
            std.log.err("docker pull failed: {s}", .{pull_result.stderr});
            return error.DockerPullFailed;
        }

        const builtin = @import("builtin");
        var name: []const u8 = undefined;
        var script: []const u8 = undefined;
        if (builtin.os.tag == .windows) {
            name = try std.fmt.allocPrint(allocator, "{s}.cmd", .{getImageName(self.repo)});
            script = try std.fmt.allocPrint(allocator, sh_windows, .{ self.repo, tag });
        } else {
            name = try allocator.dupe(u8, getImageName(self.repo));
            script = try std.fmt.allocPrint(allocator, sh_unix, .{ self.repo, tag });
        }

        return .{
            .data = script,
            .name = name,
            .version = try allocator.dupe(u8, tag),
        };
    }

    pub fn getLatestVersion(self: *const Docker, allocator: std.mem.Allocator, client: *std.http.Client) !providers.Latest {
        _ = client;
        // The reference never queries the registry; the stored tag is returned.
        return .{ .version = try allocator.dupe(u8, self.tag), .url = "" };
    }
};
