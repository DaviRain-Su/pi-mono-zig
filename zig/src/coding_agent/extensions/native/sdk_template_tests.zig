const std = @import("std");
const extension_manifest = @import("../extension_manifest.zig");
const native_sdk = @import("pi_native_extension_sdk.zig");

const TEMPLATE_ROOT = "templates/extension-native-zig";
const TEMPLATE_FILES = [_][]const u8{
    "build.zig",
    "pi-extension.json",
    "sdk/pi_native_extension_sdk.zig",
    "src/main.zig",
    "test/main.zig",
    "native/.gitkeep",
};

test "native sdk template uses only public native sdk boundary names" {
    const allocator = std.testing.allocator;
    for (TEMPLATE_FILES) |relative_path| {
        const path = try std.fs.path.join(allocator, &.{ TEMPLATE_ROOT, relative_path });
        defer allocator.free(path);
        const bytes = try readRepoFile(allocator, path);
        defer allocator.free(bytes);
        try expectNotContains(bytes, "../../../../");
        try expectNotContains(bytes, "/Users/");
        try expectNotContains(bytes, "src/coding_agent");
        try expectNotContains(bytes, "packages/");
        try expectNotContains(bytes, "extension_host");
        try expectNotContains(bytes, "extension_runtime");
        try expectNotContains(bytes, "native_runtime");
        try expectNotContains(bytes, "dlopen");
        try expectNotContains(bytes, "LoadLibrary");
    }

    const main_zig = try readRepoFile(allocator, TEMPLATE_ROOT ++ "/src/main.zig");
    defer allocator.free(main_zig);
    try expectContains(main_zig, "@import(\"pi-native-extension-sdk\")");
    try expectContains(main_zig, "pi_native_extension_abi_version");
    try expectContains(main_zig, "pi_native_extension_metadata_ptr");
    try expectContains(main_zig, "pi_native_extension_execute");

    const public_sdk = try readRepoFile(allocator, "src/coding_agent/extensions/native/pi_native_extension_sdk.zig");
    defer allocator.free(public_sdk);
    const template_sdk = try readRepoFile(allocator, TEMPLATE_ROOT ++ "/sdk/pi_native_extension_sdk.zig");
    defer allocator.free(template_sdk);
    try std.testing.expectEqualStrings(public_sdk, template_sdk);
}

test "native sdk template builds standalone validates locally and emits package metadata" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_root = try copyTemplateToTmp(allocator, &tmp);
    defer allocator.free(package_root);

    try runTemplateBuild(allocator, package_root);
    try runTemplateValidate(allocator, package_root);

    const manifest_text = try readAbsoluteFile(allocator, package_root, "pi-extension.json");
    defer allocator.free(manifest_text);
    const author_validation = try native_sdk.validateManifestTextAlloc(allocator, manifest_text, expectedManifest());
    defer allocator.free(author_validation);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"schemaVersion\":\"pi-extension.v1\",\"runtime\":\"native\",\"abi\":\"pi_native_extension_abi_v0\",\"packageId\":\"com.pi.native.template.echo\",\"toolName\":\"native.echo\"}",
        author_validation,
    );

    var parsed = try extension_manifest.parseManifestText(
        allocator,
        package_root,
        "pi-extension.json",
        manifest_text,
    );
    defer parsed.deinit(allocator);
    try std.testing.expect(parsed == .valid);
    try std.testing.expectEqual(.native, parsed.valid.runtime_kind);
    try std.testing.expectEqualStrings("com.pi.native.template.echo", parsed.valid.id);
    try std.testing.expectEqual(@as(usize, 1), parsed.valid.tools.array.items.len);

    const snapshot = try parsed.valid.registrySnapshotJson(allocator);
    defer allocator.free(snapshot);
    try expectContains(snapshot, "\"kind\":\"native\"");
    try expectContains(snapshot, "\"adapter\":\"zig-native-static-host\"");
    try expectContains(snapshot, "\"name\":\"native.echo\"");
    try expectContains(snapshot, "\"outputSchema\"");

    const artifact_path = try templateArtifactPath(allocator, package_root);
    defer allocator.free(artifact_path);
    _ = try std.Io.Dir.statFile(.cwd(), std.testing.io, artifact_path, .{});

    const invalid_manifest =
        \\{"schemaVersion":"pi-extension.v1","id":"com.pi.native.template.echo","name":"Pi Native Zig Echo Template","version":"0.1.0","runtime":{"kind":"native","entrypoint":{"descriptor":"native://dynamic/com.pi.native.template.echo","dynamic_library_path":"native/lib.dylib"},"limits":{"timeoutMs":30000,"outputBytes":65536,"toolScopes":["native.echo"]}},"tools":[{"name":"native.echo","inputSchema":{},"outputSchema":{}}],"capabilities":{"exports":[{"id":"native.echo","kind":"tool","version":"0.1.0"}],"imports":[]}}
    ;
    const invalid_result = try native_sdk.validateManifestTextAlloc(allocator, invalid_manifest, expectedManifest());
    defer allocator.free(invalid_result);
    try expectContains(invalid_result, "\"ok\":false");
    try expectContains(invalid_result, "$.runtime.entrypoint.dynamic_library_path");
    try expectContains(invalid_result, "manifest.unsupported_native_entrypoint_field");
}

fn expectedManifest() native_sdk.ExpectedManifest {
    return .{
        .id = "com.pi.native.template.echo",
        .name = "Pi Native Zig Echo Template",
        .version = "0.1.0",
        .runtime_descriptor = "native://dynamic/com.pi.native.template.echo",
        .tool_name = "native.echo",
        .timeout_ms = 30000,
        .output_bytes = 65536,
    };
}

fn copyTemplateToTmp(allocator: std.mem.Allocator, tmp: anytype) ![]u8 {
    try tmp.dir.createDir(std.testing.io, "package", .default_dir);
    try tmp.dir.createDir(std.testing.io, "package/sdk", .default_dir);
    try tmp.dir.createDir(std.testing.io, "package/src", .default_dir);
    try tmp.dir.createDir(std.testing.io, "package/test", .default_dir);
    try tmp.dir.createDir(std.testing.io, "package/native", .default_dir);
    for (TEMPLATE_FILES) |relative_path| {
        const source_path = try std.fs.path.join(allocator, &.{ TEMPLATE_ROOT, relative_path });
        defer allocator.free(source_path);
        const bytes = try readRepoFile(allocator, source_path);
        defer allocator.free(bytes);
        const target_path = try std.fs.path.join(allocator, &.{ "package", relative_path });
        defer allocator.free(target_path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = target_path, .data = bytes });
    }
    const package_root_z = try tmp.dir.realPathFileAlloc(std.testing.io, "package", allocator);
    defer allocator.free(package_root_z);
    return allocator.dupe(u8, package_root_z);
}

fn runTemplateBuild(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build", "-p", "." },
        .cwd = .{ .path = package_root },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) {
        std.debug.print("native zig build stdout:\n{s}\nnative zig build stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.TemplateBuildFailed;
    }
}

fn runTemplateValidate(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build", "-p", ".", "validate" },
        .cwd = .{ .path = package_root },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) {
        std.debug.print("native zig build validate stdout:\n{s}\nnative zig build validate stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.TemplateValidationFailed;
    }
}

fn templateArtifactPath(allocator: std.mem.Allocator, package_root: []const u8) ![]u8 {
    const builtin = @import("builtin");
    const ext = switch (builtin.os.tag) {
        .macos => "dylib",
        .windows => "dll",
        else => "so",
    };
    const artifact_name = switch (builtin.os.tag) {
        .windows => try std.fmt.allocPrint(allocator, "pi_native_template_echo.{s}", .{ext}),
        else => try std.fmt.allocPrint(allocator, "libpi_native_template_echo.{s}", .{ext}),
    };
    defer allocator.free(artifact_name);
    const platform_dir = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ @tagName(builtin.os.tag), @tagName(builtin.cpu.arch) });
    defer allocator.free(platform_dir);
    return std.fs.path.join(allocator, &.{ package_root, "native", platform_dir, artifact_name });
}

fn readRepoFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(512 * 1024));
}

fn readAbsoluteFile(allocator: std.mem.Allocator, root: []const u8, relative_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ root, relative_path });
    defer allocator.free(path);
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(512 * 1024));
}

fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

fn expectNotContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) == null);
}

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}
