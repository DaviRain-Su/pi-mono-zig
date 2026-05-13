const common = @import("common.zig");
const std = common.std;
const agent = common.agent;
const ai = common.ai;
const native_loader = common.native_loader;
const native_manifest = common.native_manifest;
const wasm_manifest = common.wasm_manifest;
const normalConstructionFactory = common.normalConstructionFactory;
const forcedWasmSuccessToolCallFactory = common.forcedWasmSuccessToolCallFactory;
const verifyWasmSuccessResultFactory = common.verifyWasmSuccessResultFactory;
const forcedNativeSuccessToolCallFactory = common.forcedNativeSuccessToolCallFactory;
const verifyNativeSuccessResultFactory = common.verifyNativeSuccessResultFactory;
const aggregatePostRemoveConstructionFactory = common.aggregatePostRemoveConstructionFactory;
const runNormalTemplateInvocation = common.runNormalTemplateInvocation;
const runNormalNativeInvocation = common.runNormalNativeInvocation;
const runNormalConstructionCase = common.runNormalConstructionCase;
const expectBuiltToolAbsent = common.expectBuiltToolAbsent;
const runPackageCommand = common.runPackageCommand;
const buildAggregateAuthorTools = common.buildAggregateAuthorTools;
const expectMixedRuntimeDeniedWithFields = common.expectMixedRuntimeDeniedWithFields;
const expectMixedRuntimeProjectDenied = common.expectMixedRuntimeProjectDenied;
const writeAggregateAuthorSettings = common.writeAggregateAuthorSettings;
const extractApprovalTarget = common.extractApprovalTarget;
const extractApprovalTargetWithPrefix = common.extractApprovalTargetWithPrefix;
const copyTemplateToTmp = common.copyTemplateToTmp;
const copyNativeTemplateToTmp = common.copyNativeTemplateToTmp;
const runTemplateBuild = common.runTemplateBuild;
const runNativeTemplateBuild = common.runNativeTemplateBuild;
const runNativeTemplateValidate = common.runNativeTemplateValidate;
const writePackageRootDriftFile = common.writePackageRootDriftFile;
const expectPackageTreeExcludesProductSurfaces = common.expectPackageTreeExcludesProductSurfaces;
const readFile = common.readFile;
const absoluteTmpPath = common.absoluteTmpPath;
const expectContains = common.expectContains;
const expectNotContains = common.expectNotContains;

test "VAL-CROSS aggregate mixed runtime author workflow and CI boundary gate" {
    if (native_loader.unsupportedPlatformReasonForTesting()) |_| return;
    if (@import("builtin").os.tag != .macos) return;

    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    defer ai.model_registry.resetForTesting();

    try tmp.dir.createDirPath(std.testing.io, "home/.pi/agent");
    try tmp.dir.createDirPath(std.testing.io, "project/sessions");
    const home_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home");
    defer allocator.free(home_dir);
    const agent_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const project_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project");
    defer allocator.free(project_dir);
    const session_dir = try absoluteTmpPath(allocator, &tmp.sub_path, "project/sessions");
    defer allocator.free(session_dir);
    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const lock_path = try std.fs.path.join(allocator, &.{ agent_dir, "extensions.lock.json" });
    defer allocator.free(lock_path);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, settings_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, lock_path, .{}));

    const wasm_root = try copyTemplateToTmp(allocator, &tmp, "project/aggregate-wasm-author-plugin");
    defer allocator.free(wasm_root);
    const native_root = try copyNativeTemplateToTmp(allocator, &tmp, "project/aggregate-native-author-plugin");
    defer allocator.free(native_root);
    try runTemplateBuild(allocator, wasm_root);
    try runNativeTemplateBuild(allocator, native_root);
    try runNativeTemplateValidate(allocator, native_root);

    try expectPackageTreeExcludesProductSurfaces(allocator, wasm_root);
    try expectPackageTreeExcludesProductSurfaces(allocator, native_root);

    var wasm_manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, wasm_root);
    defer wasm_manifest_result.deinit(allocator);
    try std.testing.expect(wasm_manifest_result == .valid);
    var native_manifest_result = try native_manifest.validateManifestFile(allocator, std.testing.io, native_root);
    defer native_manifest_result.deinit(allocator);
    try std.testing.expect(native_manifest_result == .valid);
    try std.testing.expectEqualStrings("template.echo", wasm_manifest_result.valid.tool_id);
    try std.testing.expectEqualStrings("native.echo", native_manifest_result.valid.tool_name);

    var wasm_install = try runPackageCommand(allocator, &.{ "install", wasm_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer wasm_install.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), wasm_install.exit_code);
    try expectContains(wasm_install.stdout, "runtime: wasm");
    try expectContains(wasm_install.stdout, "approval target: wasm:locked:user:");
    const wasm_policy_key = try extractApprovalTarget(allocator, wasm_install.stdout);
    defer allocator.free(wasm_policy_key);

    var native_install = try runPackageCommand(allocator, &.{ "install", native_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer native_install.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), native_install.exit_code);
    try expectContains(native_install.stdout, "runtime: native");
    try expectContains(native_install.stdout, "approval target: native:locked:user:");
    const native_policy_key = try extractApprovalTarget(allocator, native_install.stdout);
    defer allocator.free(native_policy_key);

    var initial_list = try runPackageCommand(allocator, &.{"list"}, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer initial_list.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), initial_list.exit_code);
    try expectContains(initial_list.stdout, "runtime: wasm");
    try expectContains(initial_list.stdout, "runtime: native");
    try expectContains(initial_list.stdout, "policy: denied");
    try expectNotContains(initial_list.stdout, "Web Simulator");
    try expectNotContains(initial_list.stdout, "marketplace");

    try expectMixedRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "missing_policy", &.{
        "tool=template.echo",
        wasm_manifest_result.valid.package_root_sha256,
        wasm_manifest_result.valid.artifact_sha256,
    }, "missing_policy", &.{
        "tool=native.echo",
        "scope=user",
        native_manifest_result.valid.package_root_sha256,
        native_manifest_result.valid.selected_artifact_sha256,
    });

    try writeAggregateAuthorSettings(allocator, settings_path, &.{
        .{ .source = wasm_root, .policy_key = wasm_policy_key, .tool_scope = "template.echo" },
        .{ .source = native_root, .policy_key = native_policy_key, .tool_scope = "native.echo" },
    });

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .factory = normalConstructionFactory },
        .{ .factory = forcedWasmSuccessToolCallFactory },
        .{ .factory = verifyWasmSuccessResultFactory },
        .{ .factory = forcedNativeSuccessToolCallFactory },
        .{ .factory = verifyNativeSuccessResultFactory },
        .{ .factory = forcedWasmSuccessToolCallFactory },
        .{ .factory = verifyWasmSuccessResultFactory },
        .{ .factory = forcedNativeSuccessToolCallFactory },
        .{ .factory = verifyNativeSuccessResultFactory },
        .{ .factory = aggregatePostRemoveConstructionFactory },
    });

    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "mixed construction", .{
        .include_installed_wasm_tools = true,
        .include_installed_native_tools = true,
    }, .text, "mixed construction ok\n");
    try runNormalTemplateInvocation(allocator, home_dir, agent_dir, project_dir, session_dir, registration.getModel(), wasm_manifest_result.valid.artifact_sha256);
    try runNormalNativeInvocation(allocator, home_dir, agent_dir, project_dir, session_dir, registration.getModel(), native_manifest_result.valid.selected_artifact_sha256);

    var project_wasm_install = try runPackageCommand(allocator, &.{ "install", wasm_root, "-l" }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer project_wasm_install.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), project_wasm_install.exit_code);
    try expectContains(project_wasm_install.stdout, "scope: project");
    var project_native_install = try runPackageCommand(allocator, &.{ "install", native_root, "-l" }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer project_native_install.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), project_native_install.exit_code);
    try expectContains(project_native_install.stdout, "scope: project");
    try expectMixedRuntimeProjectDenied(allocator, home_dir, agent_dir, project_dir);
    var project_wasm_remove = try runPackageCommand(allocator, &.{ "remove", wasm_root, "-l" }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer project_wasm_remove.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), project_wasm_remove.exit_code);
    var project_native_remove = try runPackageCommand(allocator, &.{ "remove", native_root, "-l" }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer project_native_remove.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), project_native_remove.exit_code);

    const lock_before_drift = try readFile(allocator, lock_path);
    defer allocator.free(lock_before_drift);
    try writePackageRootDriftFile(allocator, wasm_root, "aggregate-wasm-drift.txt", "wasm root drift");
    try writePackageRootDriftFile(allocator, native_root, "aggregate-native-drift.txt", "native root drift");
    try expectMixedRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "package_root_digest_mismatch", &.{
        wasm_manifest_result.valid.package_root_sha256,
        "actual=",
    }, "package_root_digest_mismatch", &.{
        native_manifest_result.valid.package_root_sha256,
        "actual=",
    });
    const lock_after_drift = try readFile(allocator, lock_path);
    defer allocator.free(lock_after_drift);
    try std.testing.expectEqualStrings(lock_before_drift, lock_after_drift);

    var wasm_update = try runPackageCommand(allocator, &.{ "update", wasm_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{"/usr/bin/true"},
    });
    defer wasm_update.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), wasm_update.exit_code);
    var native_update = try runPackageCommand(allocator, &.{ "update", "--extension", native_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer native_update.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), native_update.exit_code);

    var updated_wasm_manifest = try wasm_manifest.validateManifestFile(allocator, std.testing.io, wasm_root);
    defer updated_wasm_manifest.deinit(allocator);
    try std.testing.expect(updated_wasm_manifest == .valid);
    var updated_native_manifest = try native_manifest.validateManifestFile(allocator, std.testing.io, native_root);
    defer updated_native_manifest.deinit(allocator);
    try std.testing.expect(updated_native_manifest == .valid);
    try std.testing.expect(!std.mem.eql(u8, wasm_manifest_result.valid.package_root_sha256, updated_wasm_manifest.valid.package_root_sha256));
    try std.testing.expect(!std.mem.eql(u8, native_manifest_result.valid.package_root_sha256, updated_native_manifest.valid.package_root_sha256));

    try expectMixedRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "policy_digest_mismatch", &.{
        wasm_manifest_result.valid.package_root_sha256,
        updated_wasm_manifest.valid.package_root_sha256,
        "attemptedPolicy=",
        "requiredPolicy=",
    }, "policy_digest_mismatch", &.{
        native_manifest_result.valid.package_root_sha256,
        updated_native_manifest.valid.package_root_sha256,
        "attemptedPolicy=",
        "requiredPolicy=",
    });

    var updated_list = try runPackageCommand(allocator, &.{"list"}, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer updated_list.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), updated_list.exit_code);
    const updated_wasm_policy_key = try extractApprovalTargetWithPrefix(allocator, updated_list.stdout, "wasm:locked:user:");
    defer allocator.free(updated_wasm_policy_key);
    const updated_native_policy_key = try extractApprovalTargetWithPrefix(allocator, updated_list.stdout, "native:locked:user:");
    defer allocator.free(updated_native_policy_key);
    try expectContains(updated_wasm_policy_key, updated_wasm_manifest.valid.package_root_sha256);
    try expectContains(updated_native_policy_key, updated_native_manifest.valid.package_root_sha256);
    try writeAggregateAuthorSettings(allocator, settings_path, &.{
        .{ .source = wasm_root, .policy_key = updated_wasm_policy_key, .tool_scope = "template.echo" },
        .{ .source = native_root, .policy_key = updated_native_policy_key, .tool_scope = "native.echo" },
    });

    try runNormalTemplateInvocation(allocator, home_dir, agent_dir, project_dir, session_dir, registration.getModel(), updated_wasm_manifest.valid.artifact_sha256);
    try runNormalNativeInvocation(allocator, home_dir, agent_dir, project_dir, session_dir, registration.getModel(), updated_native_manifest.valid.selected_artifact_sha256);

    var wasm_remove = try runPackageCommand(allocator, &.{ "remove", wasm_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer wasm_remove.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), wasm_remove.exit_code);
    var native_remove = try runPackageCommand(allocator, &.{ "remove", native_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer native_remove.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), native_remove.exit_code);

    var removed_tools = try buildAggregateAuthorTools(allocator, home_dir, agent_dir, project_dir, .{});
    defer removed_tools.deinit();
    try std.testing.expectEqual(@as(usize, 0), removed_tools.locked_wasm_runtimes.?.entries.len);
    try std.testing.expectEqual(@as(usize, 0), removed_tools.locked_native_runtimes.?.entries.len);
    try expectBuiltToolAbsent(removed_tools.items, "template.echo");
    try expectBuiltToolAbsent(removed_tools.items, "native.echo");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "aggregate post-remove construction", .{
        .include_installed_wasm_tools = true,
        .include_installed_native_tools = true,
    }, .text, "aggregate post-remove construction ok\n");
}
