const std = @import("std");
const ai = @import("ai");
const config_mod = @import("../../config/config.zig");
const extension_runtime = @import("../extension_runtime.zig");
const package_manager = @import("../../packages/package_manager.zig");
const resources_mod = @import("../../resources/resources.zig");
const sdk = @import("pi_extension_sdk.zig");
const tools_common = @import("../../tools/common.zig");
const wasm_manifest = @import("wasm_manifest.zig");

const TEMPLATE_ROOT = "templates/extension-wasm-zig";
const TEMPLATE_FILES = [_][]const u8{
    "build.zig",
    "pi-extension.json",
    "sdk/pi_extension_sdk.zig",
    "src/main.zig",
    "test/main.zig",
    "wasm/.gitkeep",
};

test "VAL-CROSS final Zig author workflow copy install execute drift update remove" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer ai.model_registry.resetForTesting();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);

    const package_root = try copyTemplateToTmp(allocator, &tmp, "project/author-plugin");
    defer allocator.free(package_root);
    try runTemplateBuild(allocator, package_root);

    const unsupported = try sdk.unsupportedHostApiDiagnosticAlloc(
        allocator,
        "com.pi.template.echo",
        "template.echo",
        "Workflow.RemoteWasm.load?token=pi-author-secret",
    );
    defer allocator.free(unsupported);
    try expectContains(unsupported, "\"category\":\"unsupported_host_api\"");
    try expectContains(unsupported, "unsupported host API denied");
    try expectContains(unsupported, "token=[REDACTED]");
    try expectNotContains(unsupported, "pi-author-secret");

    var initial_manifest = try wasm_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer initial_manifest.deinit(allocator);
    try std.testing.expect(initial_manifest == .valid);
    try std.testing.expectEqualStrings("template.echo", initial_manifest.valid.tool_id);

    var install_result = try runPackageCommand(allocator, &.{ "install", package_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer install_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);
    try expectContains(install_result.stdout, "Installed ");
    try std.testing.expectEqualStrings("", install_result.stderr);

    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const persisted_source = try installedPackageSource(allocator, settings_path);
    defer allocator.free(persisted_source);

    try expectRuntimeDenied(allocator, home_dir, agent_dir, project_dir, "missing_policy");

    const initial_policy_key = try extension_runtime.wasmPolicyLookupKey(
        allocator,
        extension_runtime.WasmManifestHandoff.fromManifest(&initial_manifest.valid),
    );
    defer allocator.free(initial_policy_key);
    try writeAuthorSettings(allocator, settings_path, persisted_source, initial_policy_key, "template.echo");

    {
        var runtime_set = try startAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
        defer runtime_set.deinit();
        try std.testing.expectEqual(@as(usize, 1), runtime_set.entries.len);
        try std.testing.expectEqual(@as(usize, 0), runtime_set.diagnostics.len);
        try executeAuthorTool(
            allocator,
            &runtime_set,
            "template.echo",
            "{\"message\":\"hello author\"}",
            "{\"ok\":true,\"output\":{\"message\":\"hello author\"}}",
        );
        try std.testing.expectEqualStrings("template.echo", runtime_set.entries[0].tool_id);
        try std.testing.expect(std.mem.indexOf(u8, runtime_set.entries[0].policy_lookup_key, initial_manifest.valid.artifact_sha256) != null);
        try std.testing.expect(try runtime_set.unloadPackage(package_root));
        try expectNoAuthorTool(allocator, &runtime_set, "template.echo");
    }

    const lock_path = try std.fs.path.join(allocator, &.{ agent_dir, "extensions.lock.json" });
    defer allocator.free(lock_path);
    const lock_before_drift = try readFile(allocator, lock_path);
    defer allocator.free(lock_before_drift);

    try appendFile(allocator, initial_manifest.valid.artifact_absolute_path, "\nDRIFT");
    try expectRuntimeDenied(allocator, home_dir, agent_dir, project_dir, "package_root_digest_mismatch");
    const lock_after_drift = try readFile(allocator, lock_path);
    defer allocator.free(lock_after_drift);
    try std.testing.expectEqualStrings(lock_before_drift, lock_after_drift);

    try writeEditedAuthorSource(allocator, package_root);
    try writeEditedAuthorManifest(allocator, package_root);
    try runTemplateBuild(allocator, package_root);
    try expectRuntimeDenied(allocator, home_dir, agent_dir, project_dir, "package_root_digest_mismatch");

    var update_result = try runPackageCommand(allocator, &.{ "update", package_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{"/usr/bin/true"},
    });
    defer update_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), update_result.exit_code);
    try expectContains(update_result.stdout, "Updated ");

    var edited_manifest = try wasm_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer edited_manifest.deinit(allocator);
    try std.testing.expect(edited_manifest == .valid);
    try std.testing.expectEqualStrings("fixture.echo", edited_manifest.valid.tool_id);
    try expectContains(edited_manifest.valid.output_schema_json, "\"echo\"");
    try std.testing.expect(!std.mem.eql(u8, initial_manifest.valid.artifact_sha256, edited_manifest.valid.artifact_sha256));

    try expectRuntimeDenied(allocator, home_dir, agent_dir, project_dir, "missing_policy");
    const edited_policy_key = try extension_runtime.wasmPolicyLookupKey(
        allocator,
        extension_runtime.WasmManifestHandoff.fromManifest(&edited_manifest.valid),
    );
    defer allocator.free(edited_policy_key);
    try writeAuthorSettings(allocator, settings_path, persisted_source, edited_policy_key, "fixture.echo");

    {
        var runtime_set = try startAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
        defer runtime_set.deinit();
        try std.testing.expectEqual(@as(usize, 1), runtime_set.entries.len);
        try std.testing.expectEqual(@as(usize, 0), runtime_set.diagnostics.len);
        try executeAuthorTool(
            allocator,
            &runtime_set,
            "fixture.echo",
            "{\"operation\":\"echo\",\"value\":\"edited runtime output\"}",
            "{\"ok\":true,\"tool\":\"fixture.echo\",\"echo\":\"edited runtime output\"}",
        );
    }

    var remove_result = try runPackageCommand(allocator, &.{ "remove", package_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer remove_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), remove_result.exit_code);
    try expectContains(remove_result.stdout, "Removed ");

    const settings_after_remove = try readFile(allocator, settings_path);
    defer allocator.free(settings_after_remove);
    try expectNotContains(settings_after_remove, persisted_source);

    const lock_after_remove = try readFile(allocator, lock_path);
    defer allocator.free(lock_after_remove);
    try expectNotContains(lock_after_remove, edited_manifest.valid.artifact_sha256);
    try expectNotContains(lock_after_remove, edited_manifest.valid.package_root_sha256);

    var removed_runtime_set = try startAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
    defer removed_runtime_set.deinit();
    try std.testing.expectEqual(@as(usize, 0), removed_runtime_set.entries.len);
    try expectNoAuthorTool(allocator, &removed_runtime_set, "template.echo");
    try expectNoAuthorTool(allocator, &removed_runtime_set, "fixture.echo");
}

const CommandCapture = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: *CommandCapture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

fn runPackageCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    options: package_manager.ExecuteOptions,
) !CommandCapture {
    var stdout: std.Io.Writer.Allocating = .init(allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(allocator);
    defer stderr.deinit();
    var parsed = try package_manager.parsePackageCommand(allocator, args);
    defer parsed.deinit(allocator);
    const result = try package_manager.executePackageCommand(
        allocator,
        std.testing.io,
        parsed,
        options,
        &stdout.writer,
        &stderr.writer,
    );
    return .{
        .exit_code = result.exit_code,
        .stdout = try allocator.dupe(u8, stdout.written()),
        .stderr = try allocator.dupe(u8, stderr.written()),
    };
}

fn startAuthorRuntimeSet(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
) !extension_runtime.LockedWasmRuntimeSet {
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    try env_map.put("PI_OFFLINE", "1");
    var runtime_config = try config_mod.loadRuntimeConfigWithOptions(
        allocator,
        std.testing.io,
        &env_map,
        project_dir,
        .{ .discover_models = false },
    );
    defer runtime_config.deinit();

    return extension_runtime.startLockedWasmPackageRuntimes(allocator, std.testing.io, &runtime_config, .{
        .cwd = project_dir,
        .agent_dir = runtime_config.agent_dir,
        .global = resources_mod.SettingsResources{ .packages = runtime_config.global_settings.packages },
        .project = resources_mod.SettingsResources{ .packages = runtime_config.project_settings.packages },
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    });
}

fn executeAuthorTool(
    allocator: std.mem.Allocator,
    runtime_set: *extension_runtime.LockedWasmRuntimeSet,
    tool_name: []const u8,
    params_json: []const u8,
    expected_output: []const u8,
) !void {
    var agent_tool = (try runtime_set.agentTool(allocator, tool_name)) orelse return error.ExpectedAuthorTool;
    defer extension_runtime.deinitAgentTool(allocator, &agent_tool);
    try std.testing.expect(agent_tool.execute != null);
    var params = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{});
    defer params.deinit();
    const result = try agent_tool.execute.?(allocator, "author-workflow", params.value, agent_tool.execute_context, null, null, null);
    defer tools_common.deinitContentBlocks(allocator, result.content);
    try std.testing.expectEqual(@as(usize, 1), result.content.len);
    try std.testing.expectEqualStrings(expected_output, result.content[0].text.text);
}

fn expectNoAuthorTool(
    allocator: std.mem.Allocator,
    runtime_set: *extension_runtime.LockedWasmRuntimeSet,
    tool_name: []const u8,
) !void {
    if (try runtime_set.agentTool(allocator, tool_name)) |tool| {
        var owned = tool;
        defer extension_runtime.deinitAgentTool(allocator, &owned);
        return error.ExpectedNoAuthorTool;
    }
}

fn expectRuntimeDenied(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    expected_kind: []const u8,
) !void {
    var runtime_set = try startAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
    defer runtime_set.deinit();
    try std.testing.expectEqual(@as(usize, 0), runtime_set.entries.len);
    var saw_expected = false;
    for (runtime_set.diagnostics) |diagnostic| {
        if (std.mem.eql(u8, diagnostic.kind, expected_kind)) saw_expected = true;
    }
    try std.testing.expect(saw_expected);
    try expectNoAuthorTool(allocator, &runtime_set, "template.echo");
}

fn writeAuthorSettings(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    source: []const u8,
    policy_key: []const u8,
    tool_scope: []const u8,
) !void {
    const source_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = source }, .{});
    defer allocator.free(source_json);
    const policy_key_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = policy_key }, .{});
    defer allocator.free(policy_key_json);
    const tool_scope_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = tool_scope }, .{});
    defer allocator.free(tool_scope_json);
    const settings = try std.fmt.allocPrint(allocator,
        \\{{"packages":[{{"source":{s}}}],"extensionPolicies":{{{s}:{{"resourceLimits":{{"toolScopes":[{s}],"outputBytes":65536}}}}}}}}
    , .{ source_json, policy_key_json, tool_scope_json });
    defer allocator.free(settings);
    try tools_common.writeFileAbsolute(std.testing.io, settings_path, settings, true);
}

fn installedPackageSource(allocator: std.mem.Allocator, settings_path: []const u8) ![]u8 {
    const settings = try readFile(allocator, settings_path);
    defer allocator.free(settings);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, settings, .{});
    defer parsed.deinit();
    const packages = parsed.value.object.get("packages").?.array;
    const first = packages.items[0];
    return switch (first) {
        .string => |value| try allocator.dupe(u8, value),
        .object => |object| try allocator.dupe(u8, object.get("source").?.string),
        else => error.InvalidPackageSource,
    };
}

fn copyTemplateToTmp(allocator: std.mem.Allocator, tmp: anytype, package_relative_path: []const u8) ![]u8 {
    try tmp.dir.createDirPath(std.testing.io, package_relative_path);
    for (TEMPLATE_FILES) |relative_path| {
        if (std.fs.path.dirname(relative_path)) |dirname| {
            const target_dir = try std.fs.path.join(allocator, &.{ package_relative_path, dirname });
            defer allocator.free(target_dir);
            try tmp.dir.createDirPath(std.testing.io, target_dir);
        }
        const source_path = try std.fs.path.join(allocator, &.{ TEMPLATE_ROOT, relative_path });
        defer allocator.free(source_path);
        const bytes = try readFile(allocator, source_path);
        defer allocator.free(bytes);
        const target_path = try std.fs.path.join(allocator, &.{ package_relative_path, relative_path });
        defer allocator.free(target_path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = target_path, .data = bytes });
    }
    return absoluteTmpPath(allocator, &tmp.sub_path, package_relative_path);
}

fn runTemplateBuild(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build", "-p", "." },
        .cwd = .{ .path = package_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) {
        std.debug.print("zig build stdout:\n{s}\nzig build stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.TemplateBuildFailed;
    }
}

fn writeEditedAuthorSource(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const source_path = try std.fs.path.join(allocator, &.{ package_root, "src/main.zig" });
    defer allocator.free(source_path);
    try tools_common.writeFileAbsolute(std.testing.io, source_path,
        \\const sdk = @import("pi-extension-sdk");
        \\
        \\const input_schema_json =
        \\    \\{"type":"object","required":["operation","value"],"properties":{"operation":{"type":"string"},"value":{"type":"string"}}}
        \\;
        \\const output_schema_json =
        \\    \\{"type":"object","required":["ok","tool","echo"],"properties":{"ok":{"type":"boolean"},"tool":{"type":"string"},"echo":{"type":"string"}}}
        \\;
        \\
        \\const metadata_json = sdk.staticMetadataJson(
        \\    "fixture.echo",
        \\    "Pi Zig Edited Fixture Echo",
        \\    "0.2.0",
        \\    "Returns fixture echo output after an author rebuild.",
        \\);
        \\const schema_json = sdk.staticSchemaJson(input_schema_json, output_schema_json);
        \\const edited_execute_output = "{\"ok\":true,\"tool\":\"fixture.echo\",\"echo\":\"edited runtime output\"}";
        \\
        \\export fn metadata() i32 {
        \\    return sdk.ptr(metadata_json);
        \\}
        \\
        \\export fn metadata_len() i32 {
        \\    return sdk.len(metadata_json);
        \\}
        \\
        \\export fn schema() i32 {
        \\    return sdk.ptr(schema_json);
        \\}
        \\
        \\export fn schema_len() i32 {
        \\    return sdk.len(schema_json);
        \\}
        \\
        \\export fn execute(input_ptr: [*]const u8, input_len: usize) i32 {
        \\    _ = input_ptr;
        \\    _ = input_len;
        \\    return sdk.ptr(edited_execute_output);
        \\}
        \\
        \\export fn execute_len() i32 {
        \\    return sdk.len(edited_execute_output);
        \\}
        \\
    , true);
}

fn writeEditedAuthorManifest(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    try tools_common.writeFileAbsolute(std.testing.io, manifest_path,
        \\{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.pi.template.echo",
        \\  "name": "Pi Zig Edited Fixture Echo",
        \\  "version": "0.2.0",
        \\  "description": "Edited capability-free Zig WASM tool extension template.",
        \\  "artifact": {
        \\    "kind": "wasm-component",
        \\    "path": "wasm/plugin.wasm"
        \\  },
        \\  "tool": {
        \\    "id": "fixture.echo",
        \\    "description": "Returns fixture echo output after an author rebuild.",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "required": ["operation", "value"],
        \\      "properties": {
        \\        "operation": { "type": "string" },
        \\        "value": { "type": "string" }
        \\      }
        \\    },
        \\    "outputSchema": {
        \\      "type": "object",
        \\      "required": ["ok", "tool", "echo"],
        \\      "properties": {
        \\        "ok": { "type": "boolean" },
        \\        "tool": { "type": "string" },
        \\        "echo": { "type": "string" }
        \\      }
        \\    }
        \\  },
        \\  "capabilities": [],
        \\  "resourceLimits": {
        \\    "timeoutMs": 1000,
        \\    "outputBytes": 65536
        \\  }
        \\}
        \\
    , true);
}

fn appendFile(allocator: std.mem.Allocator, path: []const u8, suffix: []const u8) !void {
    const before = try readFile(allocator, path);
    defer allocator.free(before);
    const after = try std.mem.concat(allocator, u8, &.{ before, suffix });
    defer allocator.free(after);
    try tools_common.writeFileAbsolute(std.testing.io, path, after, true);
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(1024 * 1024));
}

fn absoluteTmpPath(allocator: std.mem.Allocator, tmp_sub_path: []const u8, relative: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const rel = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp_sub_path, relative });
    defer allocator.free(rel);
    return std.fs.path.resolve(allocator, &.{ cwd, rel });
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
