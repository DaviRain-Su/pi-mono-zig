const std = @import("std");
const wasm_manifest = @import("wasm_manifest.zig");
const sdk = @import("pi_extension_sdk.zig");

const TEMPLATE_ROOT = "templates/extension-wasm-zig";
const TEMPLATE_FILES = [_][]const u8{
    "build.zig",
    "pi-extension.json",
    "sdk/pi_extension_sdk.zig",
    "src/main.zig",
    "test/main.zig",
    "wasm/.gitkeep",
};

test "zig sdk facade serializes deterministic author-facing metadata schema execute diagnostics" {
    const allocator = std.testing.allocator;

    const metadata_json = try sdk.metadataJsonAlloc(allocator, .{
        .id = "com.example.echo",
        .name = "Example Echo",
        .version = "0.1.0",
        .description = "Echoes one message.",
    });
    defer allocator.free(metadata_json);
    try std.testing.expectEqualStrings(
        "{\"id\":\"com.example.echo\",\"name\":\"Example Echo\",\"version\":\"0.1.0\",\"description\":\"Echoes one message.\"}",
        metadata_json,
    );

    const schema_json = try sdk.schemaJsonAlloc(allocator, .{
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"message\"],\"properties\":{\"message\":{\"type\":\"string\"}}}",
        .output_schema_json = "{\"type\":\"object\",\"required\":[\"message\"],\"properties\":{\"message\":{\"type\":\"string\"}}}",
    });
    defer allocator.free(schema_json);
    try std.testing.expectEqualStrings(
        "{\"inputSchema\":{\"type\":\"object\",\"required\":[\"message\"],\"properties\":{\"message\":{\"type\":\"string\"}}},\"outputSchema\":{\"type\":\"object\",\"required\":[\"message\"],\"properties\":{\"message\":{\"type\":\"string\"}}}}",
        schema_json,
    );

    const success_json = try sdk.successJsonAlloc(allocator, "{\"message\":\"hello\"}");
    defer allocator.free(success_json);
    try std.testing.expectEqualStrings("{\"ok\":true,\"output\":{\"message\":\"hello\"}}", success_json);

    const echo_json = try sdk.executeMessageEchoAlloc(allocator, "{\"message\":\"hello\"}", "template.echo");
    defer allocator.free(echo_json);
    try std.testing.expectEqualStrings("{\"ok\":true,\"output\":{\"message\":\"hello\"}}", echo_json);

    const malformed_json = try sdk.executeMessageEchoAlloc(allocator, "[]", "template.echo");
    defer allocator.free(malformed_json);
    try std.testing.expectEqualStrings(
        "{\"ok\":false,\"error\":{\"category\":\"invalid_input\",\"message\":\"execute input must be a JSON object with a string message field\"}}",
        malformed_json,
    );

    const diagnostic_json = try sdk.diagnosticJsonAlloc(allocator, .{
        .extension_id = "com.example.echo",
        .tool_id = "template.echo",
        .phase = .execute,
        .category = "unsupported_host_api",
        .message = "blocked Authorization: Bearer pi-template-secret and x-api-key: pi-template-header-secret",
        .details = "https://example.test/run?api_key=pi-template-query-secret&access_token=pi-template-access-secret payload sk-pi-template-secret",
    });
    defer allocator.free(diagnostic_json);
    try std.testing.expectEqualStrings(
        "{\"runtime\":\"wasm\",\"severity\":\"error\",\"extensionId\":\"com.example.echo\",\"toolId\":\"template.echo\",\"phase\":\"execute\",\"category\":\"unsupported_host_api\",\"message\":\"blocked Authorization: Bearer [REDACTED] and x-api-key: [REDACTED]\",\"details\":\"https://example.test/run?api_key=[REDACTED]&access_token=[REDACTED] payload [REDACTED]\"}",
        diagnostic_json,
    );

    const unsupported_json = try sdk.unsupportedHostApiDiagnosticAlloc(
        allocator,
        "com.example.echo",
        "template.echo",
        "Workflow.RemoteWasm.load?token=pi-unsupported-secret",
    );
    defer allocator.free(unsupported_json);
    try std.testing.expectEqualStrings(
        "{\"runtime\":\"wasm\",\"severity\":\"error\",\"extensionId\":\"com.example.echo\",\"toolId\":\"template.echo\",\"phase\":\"execute\",\"category\":\"unsupported_host_api\",\"message\":\"unsupported host API denied: Workflow.RemoteWasm.load?token=[REDACTED]\",\"details\":\"\"}",
        unsupported_json,
    );
}

test "zig extension template layout uses only public sdk boundary names" {
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
        try expectNotContains(bytes, "Workflow");
        try expectNotContains(bytes, "Wiki");
        try expectNotContains(bytes, "Review");
        try expectNotContains(bytes, "marketplace");
        try expectNotContains(bytes, "remoteWasm");
        try expectNotContains(bytes, "webSimulator");
        try expectNotContains(bytes, "native-dynamic");
    }

    const main_zig = try readRepoFile(allocator, TEMPLATE_ROOT ++ "/src/main.zig");
    defer allocator.free(main_zig);
    try expectContains(main_zig, "@import(\"pi-extension-sdk\")");
    try expectContains(main_zig, "sdk.staticMetadataJson");
    try expectContains(main_zig, "sdk.staticSchemaJson");

    const manifest_text = try readRepoFile(allocator, TEMPLATE_ROOT ++ "/pi-extension.json");
    defer allocator.free(manifest_text);
    try expectContains(manifest_text, "\"schemaVersion\": \"pi-extension.v0\"");
    try expectContains(manifest_text, "\"kind\": \"wasm-component\"");
    try expectContains(manifest_text, "\"path\": \"wasm/plugin.wasm\"");
    try expectContains(manifest_text, "\"capabilities\": []");

    const public_sdk = try readRepoFile(allocator, "src/coding_agent/extensions/wasm/pi_extension_sdk.zig");
    defer allocator.free(public_sdk);
    const template_sdk = try readRepoFile(allocator, TEMPLATE_ROOT ++ "/sdk/pi_extension_sdk.zig");
    defer allocator.free(template_sdk);
    try std.testing.expectEqualStrings(public_sdk, template_sdk);
}

test "zig extension template builds standalone and validates reproducibly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const package_root = try copyTemplateToTmp(allocator, &tmp);
    defer allocator.free(package_root);

    try runTemplateBuild(allocator, package_root);
    try runTemplateTests(allocator, package_root);
    const first_manifest_bytes = try readAbsoluteFile(allocator, package_root, wasm_manifest.MANIFEST_FILE_NAME);
    defer allocator.free(first_manifest_bytes);
    var first_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer first_result.deinit(allocator);
    try expectValidTemplateManifest(&first_result);

    const first_artifact_sha256 = try allocator.dupe(u8, first_result.valid.artifact_sha256);
    defer allocator.free(first_artifact_sha256);
    const first_package_root_sha256 = try allocator.dupe(u8, first_result.valid.package_root_sha256);
    defer allocator.free(first_package_root_sha256);

    try runTemplateBuild(allocator, package_root);
    const second_manifest_bytes = try readAbsoluteFile(allocator, package_root, wasm_manifest.MANIFEST_FILE_NAME);
    defer allocator.free(second_manifest_bytes);
    var second_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer second_result.deinit(allocator);
    try expectValidTemplateManifest(&second_result);

    try std.testing.expectEqualStrings(first_manifest_bytes, second_manifest_bytes);
    try std.testing.expectEqualStrings(first_artifact_sha256, second_result.valid.artifact_sha256);
    try std.testing.expectEqualStrings(first_package_root_sha256, second_result.valid.package_root_sha256);
}

test "zig sdk template validation rejects dynamic native and product surfaces" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try copyTemplateToTmp(allocator, &tmp);
    defer allocator.free(package_root);
    try runTemplateBuild(allocator, package_root);

    var native_result = try wasm_manifest.validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example.native","name":"Native","version":"0.1.0","description":"Rejected","artifact":{"kind":"native-dynamic","path":"wasm/plugin.wasm"},"tool":{"id":"native.tool","description":"Rejected","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer native_result.deinit(allocator);
    try expectInvalid(&native_result, "$.artifact.kind", "unsupported artifact kind \"native-dynamic\"; expected wasm-component");

    var product_result = try wasm_manifest.validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example.product","name":"Product","version":"0.1.0","description":"Rejected","artifact":{"kind":"wasm-component","path":"wasm/plugin.wasm"},"tool":{"id":"product.tool","description":"Rejected","inputSchema":{},"outputSchema":{}},"capabilities":[],"workflowPreset":"blocked"}
    );
    defer product_result.deinit(allocator);
    try expectInvalid(&product_result, "$.workflowPreset", "unsupported v0 trust/product surface");

    var web_simulator_result = try wasm_manifest.validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example.web-simulator","name":"Web Simulator","version":"0.1.0","description":"Rejected","artifact":{"kind":"wasm-component","path":"wasm/plugin.wasm"},"tool":{"id":"web.tool","description":"Rejected","inputSchema":{},"outputSchema":{}},"capabilities":[],"webSimulator":{"enabled":true}}
    );
    defer web_simulator_result.deinit(allocator);
    try expectInvalid(&web_simulator_result, "$.webSimulator", "unsupported v0 trust/product surface");

    var slash_commands_result = try wasm_manifest.validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example.slash-command","name":"Slash Command","version":"0.1.0","description":"Rejected","artifact":{"kind":"wasm-component","path":"wasm/plugin.wasm"},"tool":{"id":"slash.tool","description":"Rejected","inputSchema":{},"outputSchema":{"metadata":{"slashCommands":["/run"]}}},"capabilities":[]}
    );
    defer slash_commands_result.deinit(allocator);
    try expectInvalid(&slash_commands_result, "$.tool.outputSchema.metadata.slashCommands", "unsupported v0 trust/product surface");
}

fn copyTemplateToTmp(allocator: std.mem.Allocator, tmp: anytype) ![]u8 {
    try tmp.dir.createDir(std.testing.io, "package", .default_dir);
    try tmp.dir.createDir(std.testing.io, "package/sdk", .default_dir);
    try tmp.dir.createDir(std.testing.io, "package/src", .default_dir);
    try tmp.dir.createDir(std.testing.io, "package/test", .default_dir);
    try tmp.dir.createDir(std.testing.io, "package/wasm", .default_dir);
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
        std.debug.print("zig build stdout:\n{s}\nzig build stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.TemplateBuildFailed;
    }
}

fn runTemplateTests(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build", "-p", ".", "test" },
        .cwd = .{ .path = package_root },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) {
        std.debug.print("zig build test stdout:\n{s}\nzig build test stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.TemplateTestsFailed;
    }
}

fn expectValidTemplateManifest(result: *wasm_manifest.ValidationResult) !void {
    try std.testing.expect(result.* == .valid);
    try std.testing.expectEqualStrings("pi-extension.v0", result.valid.schema_version);
    try std.testing.expectEqualStrings("com.pi.template.echo", result.valid.id);
    try std.testing.expectEqualStrings("template.echo", result.valid.tool_id);
    try std.testing.expectEqual(wasm_manifest.ArtifactKind.wasm_component, result.valid.artifact_kind);
    try std.testing.expectEqualStrings("wasm/plugin.wasm", result.valid.artifact_path);
    try std.testing.expectEqual(@as(usize, 0), result.valid.requested_capabilities.len);
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"required\":[\"message\"],\"properties\":{\"message\":{\"type\":\"string\"}}}",
        result.valid.input_schema_json,
    );
    try std.testing.expectEqualStrings(
        "{\"type\":\"object\",\"required\":[\"message\"],\"properties\":{\"message\":{\"type\":\"string\"}}}",
        result.valid.output_schema_json,
    );
}

fn expectInvalid(result: *wasm_manifest.ValidationResult, expected_path: []const u8, expected_message: []const u8) !void {
    try std.testing.expect(result.* == .invalid);
    try std.testing.expectEqual(@as(usize, 1), result.invalid.len);
    try std.testing.expectEqualStrings(expected_path, result.invalid[0].path);
    try std.testing.expectEqualStrings(expected_message, result.invalid[0].message);
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
