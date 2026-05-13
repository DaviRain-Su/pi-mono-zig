const common = @import("common.zig");
const std = common.std;
const agent = common.agent;
const ai = common.ai;
const sdk = common.sdk;
const wasm_manifest = common.wasm_manifest;
const normalConstructionFactory = common.normalConstructionFactory;
const forcedWasmSuccessToolCallFactory = common.forcedWasmSuccessToolCallFactory;
const verifyWasmSuccessResultFactory = common.verifyWasmSuccessResultFactory;
const forcedUpdatedWasmSuccessToolCallFactory = common.forcedUpdatedWasmSuccessToolCallFactory;
const verifyUpdatedWasmSuccessResultFactory = common.verifyUpdatedWasmSuccessResultFactory;
const postRemoveConstructionFactory = common.postRemoveConstructionFactory;
const runNormalTemplateInvocation = common.runNormalTemplateInvocation;
const runNormalUpdatedTemplateInvocation = common.runNormalUpdatedTemplateInvocation;
const runNormalConstructionCase = common.runNormalConstructionCase;
const runPackageCommand = common.runPackageCommand;
const startAuthorRuntimeSet = common.startAuthorRuntimeSet;
const executeAuthorTool = common.executeAuthorTool;
const expectNoAuthorTool = common.expectNoAuthorTool;
const expectRuntimeDenied = common.expectRuntimeDenied;
const expectRuntimeDeniedWithFields = common.expectRuntimeDeniedWithFields;
const expectRuntimeDiagnosticWithFields = common.expectRuntimeDiagnosticWithFields;
const writeAuthorSettings = common.writeAuthorSettings;
const installedPackageSource = common.installedPackageSource;
const extractApprovalTarget = common.extractApprovalTarget;
const copyTemplateToTmp = common.copyTemplateToTmp;
const writeNativeDynamicPackage = common.writeNativeDynamicPackage;
const runTemplateBuild = common.runTemplateBuild;
const writeEditedAuthorSource = common.writeEditedAuthorSource;
const writeEditedAuthorManifest = common.writeEditedAuthorManifest;
const appendFile = common.appendFile;
const readFile = common.readFile;
const absoluteTmpPath = common.absoluteTmpPath;
const expectContains = common.expectContains;
const expectNotContains = common.expectNotContains;

test "VAL-CROSS final Zig author workflow copy install execute drift update remove" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer ai.model_registry.resetForTesting();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project");
    try tmp.dir.createDirPath(std.testing.io, "project/sessions");
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const session_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project/sessions");
    defer allocator.free(session_dir);

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
    try expectContains(install_result.stdout, "runtime: wasm");
    try expectContains(install_result.stdout, "trust: locked");
    try expectContains(install_result.stdout, "approval target: wasm:locked:user:");
    try expectContains(install_result.stdout, initial_manifest.valid.package_root_sha256);
    try expectContains(install_result.stdout, initial_manifest.valid.artifact_sha256);
    try std.testing.expectEqualStrings("", install_result.stderr);
    const initial_policy_key = try extractApprovalTarget(allocator, install_result.stdout);
    defer allocator.free(initial_policy_key);

    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const persisted_source = try installedPackageSource(allocator, settings_path);
    defer allocator.free(persisted_source);

    var list_result = try runPackageCommand(allocator, &.{"list"}, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer list_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), list_result.exit_code);
    try expectContains(list_result.stdout, persisted_source);
    try expectContains(list_result.stdout, "scope: user");
    try expectContains(list_result.stdout, "runtime: wasm");
    try expectContains(list_result.stdout, "trust: locked");
    const listed_initial_policy_key = try extractApprovalTarget(allocator, list_result.stdout);
    defer allocator.free(listed_initial_policy_key);
    try std.testing.expectEqualStrings(initial_policy_key, listed_initial_policy_key);

    const lock_path = try std.fs.path.join(allocator, &.{ agent_dir, "extensions.lock.json" });
    defer allocator.free(lock_path);
    const settings_before_native_rejection = try readFile(allocator, settings_path);
    defer allocator.free(settings_before_native_rejection);
    const lock_before_native_rejection = try readFile(allocator, lock_path);
    defer allocator.free(lock_before_native_rejection);
    const native_root = try writeNativeDynamicPackage(allocator, &tmp, "project/native-dynamic-plugin");
    defer allocator.free(native_root);
    var native_install = try runPackageCommand(allocator, &.{ "install", native_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer native_install.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 1), native_install.exit_code);
    try std.testing.expectEqualStrings("", native_install.stdout);
    try expectContains(native_install.stderr, "unsupported artifact kind");
    try expectContains(native_install.stderr, "native-dylib");
    const settings_after_native_rejection = try readFile(allocator, settings_path);
    defer allocator.free(settings_after_native_rejection);
    const lock_after_native_rejection = try readFile(allocator, lock_path);
    defer allocator.free(lock_after_native_rejection);
    try std.testing.expectEqualStrings(settings_before_native_rejection, settings_after_native_rejection);
    try std.testing.expectEqualStrings(lock_before_native_rejection, lock_after_native_rejection);

    try expectRuntimeDenied(allocator, home_dir, agent_dir, project_dir, "missing_policy");

    try writeAuthorSettings(allocator, settings_path, persisted_source, initial_policy_key, "template.echo");

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .factory = normalConstructionFactory },
        .{ .factory = forcedWasmSuccessToolCallFactory },
        .{ .factory = verifyWasmSuccessResultFactory },
        .{ .factory = forcedUpdatedWasmSuccessToolCallFactory },
        .{ .factory = verifyUpdatedWasmSuccessResultFactory },
        .{ .factory = postRemoveConstructionFactory },
    });

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
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "default construction", .{
        .include_installed_wasm_tools = true,
    }, .text, "default construction ok\n");
    try runNormalTemplateInvocation(allocator, home_dir, agent_dir, project_dir, session_dir, registration.getModel(), initial_manifest.valid.artifact_sha256);

    var project_install = try runPackageCommand(allocator, &.{ "install", package_root, "-l" }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer project_install.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), project_install.exit_code);
    try expectContains(project_install.stdout, "scope: project");
    const project_policy_key = try extractApprovalTarget(allocator, project_install.stdout);
    defer allocator.free(project_policy_key);
    try expectContains(project_policy_key, "wasm:locked:project:");
    try std.testing.expect(std.mem.indexOf(u8, project_policy_key, initial_manifest.valid.artifact_sha256) != null);
    try expectRuntimeDiagnosticWithFields(allocator, home_dir, agent_dir, project_dir, "missing_policy", &.{
        "scope=project",
        initial_manifest.valid.package_root_sha256,
        initial_manifest.valid.artifact_sha256,
    }, 1);
    var project_remove = try runPackageCommand(allocator, &.{ "remove", package_root, "-l" }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer project_remove.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), project_remove.exit_code);
    try expectContains(project_remove.stdout, "Removed ");
    {
        var runtime_set = try startAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
        defer runtime_set.deinit();
        try std.testing.expectEqual(@as(usize, 1), runtime_set.entries.len);
        try std.testing.expectEqualStrings("template.echo", runtime_set.entries[0].tool_id);
    }

    const lock_before_drift = try readFile(allocator, lock_path);
    defer allocator.free(lock_before_drift);

    try appendFile(allocator, initial_manifest.valid.artifact_absolute_path, "\nDRIFT");
    try expectRuntimeDenied(allocator, home_dir, agent_dir, project_dir, "artifact_digest_mismatch");
    const lock_after_drift = try readFile(allocator, lock_path);
    defer allocator.free(lock_after_drift);
    try std.testing.expectEqualStrings(lock_before_drift, lock_after_drift);

    try writeEditedAuthorSource(allocator, package_root);
    try writeEditedAuthorManifest(allocator, package_root);
    try runTemplateBuild(allocator, package_root);
    try expectRuntimeDenied(allocator, home_dir, agent_dir, project_dir, "artifact_digest_mismatch");

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

    try expectRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "policy_digest_mismatch", &.{
        initial_manifest.valid.package_root_sha256,
        edited_manifest.valid.package_root_sha256,
        initial_manifest.valid.artifact_sha256,
        edited_manifest.valid.artifact_sha256,
        "attemptedPolicy=",
        "requiredPolicy=",
    });

    var updated_list_result = try runPackageCommand(allocator, &.{"list"}, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer updated_list_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), updated_list_result.exit_code);
    const edited_policy_key = try extractApprovalTarget(allocator, updated_list_result.stdout);
    defer allocator.free(edited_policy_key);
    try expectContains(edited_policy_key, edited_manifest.valid.package_root_sha256);
    try expectContains(edited_policy_key, edited_manifest.valid.artifact_sha256);
    try std.testing.expect(!std.mem.eql(u8, initial_policy_key, edited_policy_key));
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
    try runNormalUpdatedTemplateInvocation(allocator, home_dir, agent_dir, project_dir, session_dir, registration.getModel(), edited_manifest.valid.artifact_sha256);

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
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "post-remove construction", .{
        .include_installed_wasm_tools = true,
    }, .text, "post-remove construction ok\n");
}
