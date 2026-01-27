const std = @import("std");
const install_mod = @import("install");

test "providers: detect github from full URL" {
    const provider = install_mod.Provider.fromUrl("https://github.com/user/repo", null);
    try std.testing.expectEqual(install_mod.Provider.github, provider);
}

test "providers: detect gitlab from full URL" {
    const provider = install_mod.Provider.fromUrl("https://gitlab.com/user/repo", null);
    try std.testing.expectEqual(install_mod.Provider.gitlab, provider);
}

test "providers: detect codeberg from full URL" {
    const provider = install_mod.Provider.fromUrl("https://codeberg.org/user/repo", null);
    try std.testing.expectEqual(install_mod.Provider.codeberg, provider);
}

test "providers: detect github from domain format" {
    const provider = install_mod.Provider.fromUrl("github.com/user/repo", null);
    try std.testing.expectEqual(install_mod.Provider.github, provider);
}

test "providers: detect gitlab from domain format" {
    const provider = install_mod.Provider.fromUrl("gitlab.com/user/repo", null);
    try std.testing.expectEqual(install_mod.Provider.gitlab, provider);
}

test "providers: detect codeberg from domain format" {
    const provider = install_mod.Provider.fromUrl("codeberg.org/user/repo", null);
    try std.testing.expectEqual(install_mod.Provider.codeberg, provider);
}

test "providers: default to github for short format" {
    const provider = install_mod.Provider.fromUrl("user/repo", null);
    try std.testing.expectEqual(install_mod.Provider.github, provider);
}

test "providers: explicit provider overrides auto-detection" {
    const provider = install_mod.Provider.fromUrl("user/repo", .codeberg);
    try std.testing.expectEqual(install_mod.Provider.codeberg, provider);
}

test "providers: reject invalid URL format" {
    const result = install_mod.Provider.fromUrl("invalid-url", null);
    try std.testing.expectError(error.InvalidURL, result);
}

test "providers: reject URL with missing repo" {
    const result = install_mod.Provider.fromUrl("user", null);
    try std.testing.expectError(error.InvalidURL, result);
}

test "providers: reject URL with too many slashes" {
    const result = install_mod.Provider.fromUrl("user/repo/extra", null);
    try std.testing.expectError(error.InvalidURL, result);
}

test "providers: github prefix returns correct string" {
    const provider = install_mod.Provider.github;
    try std.testing.expectEqualStrings("github.com/", provider.prefix());
}

test "providers: gitlab prefix returns correct string" {
    const provider = install_mod.Provider.gitlab;
    try std.testing.expectEqualStrings("gitlab.com/", provider.prefix());
}

test "providers: codeberg prefix returns correct string" {
    const provider = install_mod.Provider.codeberg;
    try std.testing.expectEqualStrings("codeberg.org/", provider.prefix());
}

test "providers: parse URL with tag" {
    // Test URL with @tag format
    const url_with_tag = "user/repo@v1.2.3";
    const provider = install_mod.Provider.fromUrl(url_with_tag, null);
    try std.testing.expectEqual(install_mod.Provider.github, provider);

    // Note: Full tag parsing happens in install() function,
    // this test just verifies Provider.fromUrl works with @ syntax
}

test "providers: parse full URL with tag" {
    const url_with_tag = "https://github.com/user/repo@v2.0.0";
    const provider = install_mod.Provider.fromUrl(url_with_tag, null);
    try std.testing.expectEqual(install_mod.Provider.github, provider);
}
