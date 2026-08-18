const std = @import("std");
const providers = @import("providers");

fn providerId(allocator: std.mem.Allocator, url: []const u8, provider_name: []const u8) ![]const u8 {
    const p = try providers.Provider.new(allocator, url, provider_name);
    return p.getID();
}

test "providers: detect github from full URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = try providerId(allocator, "https://github.com/user/repo", "");
    try std.testing.expectEqualStrings("github", id);
}

test "providers: detect gitlab from full URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = try providerId(allocator, "https://gitlab.com/user/repo", "");
    try std.testing.expectEqualStrings("gitlab", id);
}

test "providers: detect codeberg from full URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = try providerId(allocator, "https://codeberg.org/user/repo", "");
    try std.testing.expectEqualStrings("codeberg", id);
}

test "providers: detect helm from get.helm.sh" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = try providerId(allocator, "https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz", "");
    try std.testing.expectEqualStrings("helm", id);
}

test "providers: detect hashicorp from releases.hashicorp.com" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = try providerId(allocator, "https://releases.hashicorp.com/terraform/1.9.0", "");
    try std.testing.expectEqualStrings("hashicorp", id);
}

test "providers: detect docker from docker:// prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = try providerId(allocator, "docker://hashicorp/terraform", "");
    try std.testing.expectEqualStrings("docker", id);
}

test "providers: detect goinstall from goinstall:// prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = try providerId(allocator, "goinstall://github.com/charmbracelet/glow", "");
    try std.testing.expectEqualStrings("goinstall", id);
}

test "providers: explicit provider requires a parseable URL (Go parity)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The reference implementation cannot parse short "user/repo" forms even
    // with -p: the URL becomes https://user/repo with no owner+repo path.
    const result = providers.Provider.new(allocator, "user/repo", "codeberg");
    try std.testing.expectError(error.InvalidURL, result);
}

test "providers: github.com URL resolves with explicit provider" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const id = try providerId(allocator, "github.com/user/repo", "github");
    try std.testing.expectEqualStrings("github", id);
}

test "providers: unknown host errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const result = providers.Provider.new(allocator, "https://example.com/foo", "");
    try std.testing.expectError(error.UnknownProvider, result);
}

test "providers: github URL parses owner/repo and releases tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const uri = try std.Uri.parse("https://github.com/cli/cli/releases/tag/v2.40.0");
    const gh = try providers.github.GitHub.init(allocator, uri, "");
    try std.testing.expectEqualStrings("cli", gh.owner);
    try std.testing.expectEqualStrings("cli", gh.repo);
    try std.testing.expectEqualStrings("v2.40.0", gh.tag);
}

test "providers: github URL splits @tag from the repo (update-bug fix)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const uri = try std.Uri.parse("https://github.com/cli/cli@v2.40.0");
    const gh = try providers.github.GitHub.init(allocator, uri, "");
    try std.testing.expectEqualStrings("cli", gh.owner);
    try std.testing.expectEqualStrings("cli", gh.repo);
    try std.testing.expectEqualStrings("v2.40.0", gh.tag);
}

test "providers: hashicorp URL parses repo and tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const uri = try std.Uri.parse("https://releases.hashicorp.com/terraform/1.9.0");
    const hc = try providers.hashicorp.HashiCorp.init(allocator, uri);
    try std.testing.expectEqualStrings("terraform", hc.repo);
    try std.testing.expectEqualStrings("1.9.0", hc.tag);
}

test "providers: helm URL parses the pinned version" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const uri = try std.Uri.parse("https://get.helm.sh/helm-v3.16.3-linux-amd64.tar.gz");
    const h = try providers.helm.Helm.init(allocator, uri);
    try std.testing.expectEqualStrings("v3.16.3", h.tag);
}

test "providers: docker URL parses image and tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const d = try providers.docker.Docker.init(allocator, "docker://hashicorp/terraform:1.5.0");
    try std.testing.expectEqualStrings("hashicorp/terraform", d.repo);
    try std.testing.expectEqualStrings("1.5.0", d.tag);
}

test "providers: docker URL defaults to library/ and latest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const d = try providers.docker.Docker.init(allocator, "docker://alpine");
    try std.testing.expectEqualStrings("library/alpine", d.repo);
    try std.testing.expectEqualStrings("latest", d.tag);
}

test "providers: goinstall URL parses repo and tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const g = try providers.goinstall.GoInstall.init(allocator, "goinstall://github.com/charmbracelet/glow@v1.5.1");
    try std.testing.expectEqualStrings("glow", g.name);
    try std.testing.expectEqualStrings("github.com/charmbracelet/glow", g.repo);
    try std.testing.expectEqualStrings("v1.5.1", g.tag);
}

test "providers: semver comparison drives update checks" {
    const semver = providers.semver;
    const a = semver.parse("v1.2.3").?;
    const b = semver.parse("1.2.10").?;
    try std.testing.expect(semver.compare(b, a) == .gt);
    const c = semver.parse("v2.0.0-rc1").?;
    try std.testing.expect(semver.compare(c, b) == .gt); // 2.x core beats 1.x
    const d = semver.parse("v2.0.0").?;
    try std.testing.expect(semver.compare(d, c) == .gt); // release > prerelease
}
