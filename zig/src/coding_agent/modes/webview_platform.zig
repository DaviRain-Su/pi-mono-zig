const std = @import("std");
const builtin = @import("builtin");

pub const Platform = enum {
    macos,
    linux,
    windows,
    unsupported,
};

pub const ZeroNativeDependencyState = enum {
    /// zero-native is intentionally isolated from build.zig.zon/dep.module
    /// until upstream exposes a stable module and stops reading app.zon from
    /// the consumer process cwd.
    isolated_adapter,
    /// A future build path attempted to consume zero-native as a normal Zig
    /// dependency before the module/app.zon caveat was resolved.
    unresolved_upstream_dependency,
};

pub const WebViewBackend = enum {
    zero_native_system_webview,
};

const macos_frameworks = [_][]const u8{
    "WebKit",
    "AppKit",
    "Foundation",
};

pub const ZeroNativeStrategy = struct {
    foundation: WebViewBackend,
    repository_url: []const u8,
    dependency_state: ZeroNativeDependencyState,
    uses_dep_module: bool,
    reads_app_zon_from_cwd: bool,
    metadata_source: []const u8,
    caveat: []const u8,
};

pub const BackendAvailability = union(enum) {
    available: AvailableBackend,
    unavailable: BackendDiagnostic,
};

pub const AvailableBackend = struct {
    backend: WebViewBackend,
    platform: Platform,
    required_frameworks: []const []const u8 = &.{},
    zero_native_strategy: ZeroNativeStrategy,
};

pub const BackendDiagnostic = struct {
    backend: WebViewBackend,
    platform: Platform,
    message: []const u8,
    requirements: []const u8,
    before_runtime_side_effects: bool,
    zero_native_isolated: bool,
    cwd_independent_metadata: bool,
};

pub const zero_native_strategy = ZeroNativeStrategy{
    .foundation = .zero_native_system_webview,
    .repository_url = "https://github.com/vercel-labs/zero-native",
    .dependency_state = .isolated_adapter,
    .uses_dep_module = false,
    .reads_app_zon_from_cwd = false,
    .metadata_source = "compiled pi WebView adapter constants",
    .caveat = "zero-native is selected as the native WebView foundation, but is isolated from build.zig.zon until upstream exposes a stable dep.module and removes consumer-cwd app.zon reads.",
};

pub fn hostPlatform() Platform {
    return platformFromOsTag(builtin.os.tag);
}

pub fn platformFromOsTag(tag: std.Target.Os.Tag) Platform {
    return switch (tag) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        else => .unsupported,
    };
}

pub fn preflightHostBackend() BackendAvailability {
    return preflightBackend(hostPlatform(), .isolated_adapter);
}

pub fn preflightBackend(platform: Platform, dependency_state: ZeroNativeDependencyState) BackendAvailability {
    if (dependency_state != .isolated_adapter) {
        return unavailable(platform, "zero-native dependency is not ready for direct Zig dep.module consumption", "Keep zero-native behind the isolated adapter until upstream exposes a stable module and cwd-independent app.zon handling.");
    }

    return switch (platform) {
        .macos => .{ .available = .{
            .backend = .zero_native_system_webview,
            .platform = .macos,
            .required_frameworks = &macos_frameworks,
            .zero_native_strategy = zero_native_strategy,
        } },
        .linux => unavailable(.linux, "WebView mode is gated on Linux until GTK4/WebKitGTK dependencies and zero-native host wiring are present", "Install GTK4 and WebKitGTK development packages, then wire the zero-native Linux system WebView host before enabling this backend."),
        .windows => unavailable(.windows, "WebView mode is gated on Windows until WebView2/zero-native host support exists", "Complete zero-native WebView2 host support or add pi-owned WebView2 host glue before enabling this backend."),
        .unsupported => unavailable(.unsupported, "WebView mode is not supported on this platform", "Use macOS with WebKit/AppKit/Foundation support, or wait for the guarded Linux/Windows backend to be implemented."),
    };
}

pub fn zeroNativeStrategyForCwd(_: []const u8) ZeroNativeStrategy {
    return zero_native_strategy;
}

fn unavailable(platform: Platform, message: []const u8, requirements: []const u8) BackendAvailability {
    return .{ .unavailable = .{
        .backend = .zero_native_system_webview,
        .platform = platform,
        .message = message,
        .requirements = requirements,
        .before_runtime_side_effects = true,
        .zero_native_isolated = true,
        .cwd_independent_metadata = true,
    } };
}

test "macOS WebView backend records required system frameworks" {
    const availability = preflightBackend(.macos, .isolated_adapter);
    const backend = switch (availability) {
        .available => |value| value,
        .unavailable => return error.ExpectedMacOSWebViewBackendAvailable,
    };

    try std.testing.expectEqual(WebViewBackend.zero_native_system_webview, backend.backend);
    try std.testing.expectEqual(Platform.macos, backend.platform);
    try std.testing.expectEqual(@as(usize, 3), backend.required_frameworks.len);
    try std.testing.expectEqualStrings("WebKit", backend.required_frameworks[0]);
    try std.testing.expectEqualStrings("AppKit", backend.required_frameworks[1]);
    try std.testing.expectEqualStrings("Foundation", backend.required_frameworks[2]);
    try std.testing.expect(!backend.zero_native_strategy.uses_dep_module);
    try std.testing.expect(!backend.zero_native_strategy.reads_app_zon_from_cwd);
}

test "Linux WebView backend returns actionable GTK4 WebKitGTK diagnostic" {
    const availability = preflightBackend(.linux, .isolated_adapter);
    const diagnostic = switch (availability) {
        .available => return error.ExpectedLinuxWebViewBackendDiagnostic,
        .unavailable => |value| value,
    };

    try std.testing.expectEqual(Platform.linux, diagnostic.platform);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "GTK4") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "WebKitGTK") != null);
    try std.testing.expect(diagnostic.before_runtime_side_effects);
}

test "Windows WebView backend is gated on WebView2 host support" {
    const availability = preflightBackend(.windows, .isolated_adapter);
    const diagnostic = switch (availability) {
        .available => return error.ExpectedWindowsWebViewBackendDiagnostic,
        .unavailable => |value| value,
    };

    try std.testing.expectEqual(Platform.windows, diagnostic.platform);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "WebView2") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "gated") != null);
    try std.testing.expect(diagnostic.before_runtime_side_effects);
}

test "unresolved zero-native dependency fails before partial integration" {
    const availability = preflightBackend(.macos, .unresolved_upstream_dependency);
    const diagnostic = switch (availability) {
        .available => return error.ExpectedZeroNativeDependencyDiagnostic,
        .unavailable => |value| value,
    };

    try std.testing.expect(std.mem.indexOf(u8, diagnostic.message, "dep.module") != null);
    try std.testing.expect(std.mem.indexOf(u8, diagnostic.requirements, "app.zon") != null);
    try std.testing.expect(diagnostic.before_runtime_side_effects);
    try std.testing.expect(diagnostic.zero_native_isolated);
}

test "zero-native metadata is cwd independent" {
    const from_repo_root = zeroNativeStrategyForCwd("/Users/davirian/dev/active/pi-mono-davirain");
    const from_zig_dir = zeroNativeStrategyForCwd("/Users/davirian/dev/active/pi-mono-davirain/zig");

    try std.testing.expectEqualStrings(from_repo_root.repository_url, from_zig_dir.repository_url);
    try std.testing.expectEqual(from_repo_root.dependency_state, from_zig_dir.dependency_state);
    try std.testing.expectEqualStrings(from_repo_root.metadata_source, from_zig_dir.metadata_source);
    try std.testing.expect(!from_repo_root.reads_app_zon_from_cwd);
}

test "unsupported WebView platforms fail with pre-runtime guard flags" {
    const availability = preflightBackend(.unsupported, .isolated_adapter);
    const diagnostic = switch (availability) {
        .available => return error.ExpectedUnsupportedPlatformDiagnostic,
        .unavailable => |value| value,
    };

    try std.testing.expectEqual(Platform.unsupported, diagnostic.platform);
    try std.testing.expect(diagnostic.before_runtime_side_effects);
    try std.testing.expect(diagnostic.cwd_independent_metadata);
}
