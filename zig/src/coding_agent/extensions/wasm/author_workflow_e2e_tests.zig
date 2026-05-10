const std = @import("std");
const agent = @import("agent");
const ai = @import("ai");
const config_mod = @import("../../config/config.zig");
const extension_runtime = @import("../extension_runtime.zig");
const interactive_mode = @import("../../interactive_mode.zig");
const native_loader = @import("../native/native_loader.zig");
const native_manifest = @import("../native/native_manifest.zig");
const package_manager = @import("../../packages/package_manager.zig");
const print_mode = @import("../../modes/print_mode.zig");
const resources_mod = @import("../../resources/resources.zig");
const sdk = @import("pi_extension_sdk.zig");
const session_mod = @import("../../sessions/session.zig");
const tool_selection_mod = @import("../../tool_selection.zig");
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
const NATIVE_TEMPLATE_ROOT = "templates/extension-native-zig";
const NATIVE_TEMPLATE_FILES = [_][]const u8{
    "build.zig",
    "pi-extension.json",
    "sdk/pi_native_extension_sdk.zig",
    "src/main.zig",
    "test/main.zig",
    "native/.gitkeep",
};

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

test "VAL-CROSS-030 CI matrix keeps aggregate native runtime boundaries explicit" {
    const allocator = std.testing.allocator;
    const zig_ci = try readFile(allocator, "../.github/workflows/zig-ci.yml");
    defer allocator.free(zig_ci);
    const node_ci = try readFile(allocator, "../.github/workflows/ci.yml");
    defer allocator.free(node_ci);

    try expectContains(zig_ci, "os: [ubuntu-latest, macos-latest, windows-latest]");
    try expectContains(zig_ci, "ZIG_VERSION=0.16.0");
    try expectContains(zig_ci, "Linux Zig smoke");
    try expectContains(zig_ci, "zig build check-external-tools --summary all");
    try expectContains(zig_ci, "Skipping Linux zig build/test because Zig 0.16.0 SIGSEGVs");
    try expectContains(zig_ci, "if: runner.os == 'Windows'");
    try expectContains(zig_ci, "if: runner.os == 'macOS'");
    try expectContains(zig_ci, "zig build test --summary all");
    try expectContains(zig_ci, "Zig CI Test Summary");
    try expectContains(node_ci, "npm run check");
    try expectNotContains(zig_ci, "Web Simulator");
    try expectNotContains(zig_ci, "marketplace");
    try expectNotContains(zig_ci, "signing");
}

test "VAL-RUNTIME normal agent construction includes installed wasm tools with filters" {
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

    const package_root = try copyTemplateToTmp(allocator, &tmp, "project/runtime-tool-plugin");
    defer allocator.free(package_root);
    try runTemplateBuild(allocator, package_root);

    var install_result = try runPackageCommand(allocator, &.{ "install", package_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer install_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);

    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const persisted_source = try installedPackageSource(allocator, settings_path);
    defer allocator.free(persisted_source);

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const policy_key = try extension_runtime.wasmPolicyLookupKey(
        allocator,
        extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid),
    );
    defer allocator.free(policy_key);
    try writeAuthorSettings(allocator, settings_path, persisted_source, policy_key, "template.echo");

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
        .{ .factory = normalConstructionFactory },
    });

    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "default construction", .{
        .include_installed_wasm_tools = true,
    }, .text, "default construction ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "selected builtins", .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{ "read", "grep" }),
        .include_installed_wasm_tools = true,
    }, .text, "selected builtins ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "selected wasm", .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{"template.echo"}),
        .include_installed_wasm_tools = true,
    }, .text, "selected wasm ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "no tools", .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{}),
        .include_builtin_tools = false,
        .include_installed_wasm_tools = false,
    }, .text, "no tools ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "no builtins", .{
        .include_builtin_tools = false,
        .include_installed_wasm_tools = true,
    }, .text, "no builtins ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "no tools explicit wasm", .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{"template.echo"}),
        .include_installed_wasm_tools = true,
    }, .text, "no tools explicit wasm ok\n");
    try runNormalConstructionCase(allocator, home_dir, agent_dir, project_dir, registration.getModel(), "json construction", .{
        .include_installed_wasm_tools = true,
    }, .json, null);
}

test "VAL-RUNTIME installed wasm executes through normal session history and error results" {
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

    const package_root = try copyTemplateToTmp(allocator, &tmp, "project/runtime-execution-plugin");
    defer allocator.free(package_root);
    try runTemplateBuild(allocator, package_root);

    var install_result = try runPackageCommand(allocator, &.{ "install", package_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer install_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);

    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const persisted_source = try installedPackageSource(allocator, settings_path);
    defer allocator.free(persisted_source);

    var manifest_result = try wasm_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer manifest_result.deinit(allocator);
    try std.testing.expect(manifest_result == .valid);
    const policy_key = try extension_runtime.wasmPolicyLookupKey(
        allocator,
        extension_runtime.WasmManifestHandoff.fromManifest(&manifest_result.valid),
    );
    defer allocator.free(policy_key);
    try writeAuthorSettings(allocator, settings_path, persisted_source, policy_key, "template.echo");

    const registration = try ai.providers.faux.registerFauxProvider(allocator, .{});
    defer registration.unregister();
    try registration.setResponses(&[_]ai.providers.faux.FauxResponseStep{
        .{ .factory = forcedWasmSuccessToolCallFactory },
        .{ .factory = verifyWasmSuccessResultFactory },
        .{ .factory = forcedWasmInvalidInputToolCallFactory },
        .{ .factory = verifyWasmInvalidResultFactory },
    });

    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();

    var app_context = interactive_mode.AppContext.init(project_dir, std.testing.io);
    var built_tools = try interactive_mode.buildAgentToolsWithOptions(allocator, &app_context, .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{"template.echo"}),
        .runtime_config = &runtime_config,
        .resource_options = .{
            .cwd = project_dir,
            .agent_dir = runtime_config.agent_dir,
            .global = interactive_mode.settingsResources(runtime_config.global_settings),
            .project = interactive_mode.settingsResources(runtime_config.project_settings),
            .include_default_extensions = false,
            .include_default_skills = false,
            .include_default_prompts = false,
            .include_default_themes = false,
        },
    });
    defer built_tools.deinit();
    try std.testing.expect(built_tools.locked_wasm_runtimes != null);
    try std.testing.expectEqual(@as(usize, 1), built_tools.locked_wasm_runtimes.?.entries.len);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_dir,
        .system_prompt = "sys",
        .model = registration.getModel(),
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    var success_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer success_stdout.deinit();
    var success_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer success_stderr.deinit();
    const success_exit = try print_mode.runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "call installed wasm",
        .{ .mode = .text, .install_signal_handlers = false },
        &success_stdout.writer,
        &success_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), success_exit);
    try std.testing.expectEqualStrings("installed wasm success observed\n", success_stdout.writer.buffered());
    try std.testing.expectEqualStrings("", success_stderr.writer.buffered());

    try expectLatestToolResult(session.agent.getMessages(), .{
        .tool_call_id = "wasm-normal-success",
        .tool_name = "template.echo",
        .is_error = false,
        .content_contains = "\"message\":\"normal agent path\"",
        .expected_extension_id = "com.pi.template.echo",
        .expected_artifact_sha256 = manifest_result.valid.artifact_sha256,
    });
    try std.testing.expectEqual(@as(usize, 0), built_tools.locked_wasm_runtimes.?.entries[0].adapter.pendingCount());

    const session_file = try allocator.dupe(u8, session.session_manager.getSessionFile().?);
    defer allocator.free(session_file);
    const persisted = try readFile(allocator, session_file);
    defer allocator.free(persisted);
    try expectContains(persisted, "\"toolCallId\":\"wasm-normal-success\"");
    try expectContains(persisted, "\"toolName\":\"template.echo\"");
    try expectContains(persisted, "\"isError\":false");
    try expectContains(persisted, "\"extensionRuntime\"");
    try expectContains(persisted, "\"runtimeKind\":\"wasm\"");
    try expectContains(persisted, manifest_result.valid.artifact_sha256);

    var reopened = try session_mod.AgentSession.open(allocator, std.testing.io, .{
        .session_file = session_file,
        .cwd_override = project_dir,
        .system_prompt = "sys",
        .model = registration.getModel(),
        .tools = built_tools.items,
    });
    defer reopened.deinit();
    try expectLatestToolResult(reopened.agent.getMessages(), .{
        .tool_call_id = "wasm-normal-success",
        .tool_name = "template.echo",
        .is_error = false,
        .content_contains = "\"message\":\"normal agent path\"",
        .expected_extension_id = "com.pi.template.echo",
        .expected_artifact_sha256 = manifest_result.valid.artifact_sha256,
    });

    var invalid_stdout: std.Io.Writer.Allocating = .init(allocator);
    defer invalid_stdout.deinit();
    var invalid_stderr: std.Io.Writer.Allocating = .init(allocator);
    defer invalid_stderr.deinit();
    const invalid_exit = try print_mode.runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "call installed wasm with invalid input",
        .{ .mode = .text, .install_signal_handlers = false },
        &invalid_stdout.writer,
        &invalid_stderr.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), invalid_exit);
    try std.testing.expectEqualStrings("installed wasm invalid input observed\n", invalid_stdout.writer.buffered());
    try std.testing.expectEqualStrings("", invalid_stderr.writer.buffered());
    try expectLatestGenericToolError(session.agent.getMessages(), "wasm-normal-invalid", "template.echo", "InvalidToolArguments");
    try std.testing.expectEqual(@as(usize, 0), built_tools.locked_wasm_runtimes.?.entries[0].adapter.pendingCount());
}

test "VAL-TRUST digest-bound policy and provenance denials fail closed" {
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

    const package_root = try copyTemplateToTmp(allocator, &tmp, "project/digest-policy-plugin");
    defer allocator.free(package_root);
    try runTemplateBuild(allocator, package_root);

    var install_result = try runPackageCommand(allocator, &.{ "install", package_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer install_result.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), install_result.exit_code);

    const settings_path = try std.fs.path.join(allocator, &.{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const persisted_source = try installedPackageSource(allocator, settings_path);
    defer allocator.free(persisted_source);
    const lock_path = try std.fs.path.join(allocator, &.{ agent_dir, "extensions.lock.json" });
    defer allocator.free(lock_path);

    var initial_manifest = try wasm_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer initial_manifest.deinit(allocator);
    try std.testing.expect(initial_manifest == .valid);

    try expectRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "missing_policy", &.{
        "tool=template.echo",
        "scope=user",
        "source=",
        initial_manifest.valid.package_root_sha256,
        initial_manifest.valid.artifact_sha256,
    });

    const legacy_policy_key = try legacyArtifactOnlyPolicyKeyForTest(allocator, &initial_manifest.valid);
    defer allocator.free(legacy_policy_key);
    const package_root_only_key = try std.fmt.allocPrint(allocator, "wasm:package-root-only:user:{s}", .{initial_manifest.valid.package_root_sha256});
    defer allocator.free(package_root_only_key);
    const wildcard_key = try allocator.dupe(u8, "wasm:*");
    defer allocator.free(wildcard_key);
    try writeAuthorSettingsWithPolicies(
        allocator,
        settings_path,
        persisted_source,
        &.{ legacy_policy_key, package_root_only_key, wildcard_key },
        "template.echo",
    );
    try expectRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "missing_policy", &.{
        "requiredPolicy=",
        "scope=user",
        initial_manifest.valid.package_root_sha256,
        initial_manifest.valid.artifact_sha256,
    });

    const exact_user_policy_key = try exactWasmPolicyKeyForTest(allocator, &initial_manifest.valid, "user");
    defer allocator.free(exact_user_policy_key);
    try writeAuthorSettingsWithPolicies(allocator, settings_path, persisted_source, &.{exact_user_policy_key}, "template.echo");
    {
        var runtime_set = try startAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
        defer runtime_set.deinit();
        try std.testing.expectEqual(@as(usize, 1), runtime_set.entries.len);
        try std.testing.expectEqualStrings(exact_user_policy_key, runtime_set.entries[0].policy_lookup_key);
    }

    const lock_before_tamper = try readFile(allocator, lock_path);
    defer allocator.free(lock_before_tamper);
    const forged_package_root_digest = "0000000000000000000000000000000000000000000000000000000000000000";
    const tampered_lock = try std.mem.replaceOwned(u8, allocator, lock_before_tamper, initial_manifest.valid.package_root_sha256, forged_package_root_digest);
    defer allocator.free(tampered_lock);
    try tools_common.writeFileAbsolute(std.testing.io, lock_path, tampered_lock, true);
    try expectRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "package_root_digest_mismatch", &.{
        forged_package_root_digest,
        initial_manifest.valid.package_root_sha256,
        "actual=",
        "scope=user",
    });
    const lock_after_tamper_diagnostic = try readFile(allocator, lock_path);
    defer allocator.free(lock_after_tamper_diagnostic);
    try std.testing.expectEqualStrings(tampered_lock, lock_after_tamper_diagnostic);
    try tools_common.writeFileAbsolute(std.testing.io, lock_path, lock_before_tamper, true);

    const lock_before_artifact_drift = try readFile(allocator, lock_path);
    defer allocator.free(lock_before_artifact_drift);
    try appendFile(allocator, initial_manifest.valid.artifact_absolute_path, "\nARTIFACT-DRIFT");
    try expectRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "artifact_digest_mismatch", &.{
        initial_manifest.valid.artifact_sha256,
        "actual=",
        "scope=user",
    });
    const lock_after_artifact_drift = try readFile(allocator, lock_path);
    defer allocator.free(lock_after_artifact_drift);
    try std.testing.expectEqualStrings(lock_before_artifact_drift, lock_after_artifact_drift);

    try runTemplateBuild(allocator, package_root);
    try writeRootOnlyAuthorManifest(allocator, package_root);
    const artifact_before_root_update = try readFile(allocator, initial_manifest.valid.artifact_absolute_path);
    defer allocator.free(artifact_before_root_update);
    var root_only_update = try runPackageCommand(allocator, &.{ "update", package_root }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
        .self_update_command_override = &.{"/usr/bin/true"},
    });
    defer root_only_update.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), root_only_update.exit_code);

    var root_only_manifest = try wasm_manifest.validateManifestFile(allocator, std.testing.io, package_root);
    defer root_only_manifest.deinit(allocator);
    try std.testing.expect(root_only_manifest == .valid);
    try std.testing.expectEqualStrings(initial_manifest.valid.artifact_sha256, root_only_manifest.valid.artifact_sha256);
    try std.testing.expect(!std.mem.eql(u8, initial_manifest.valid.package_root_sha256, root_only_manifest.valid.package_root_sha256));
    const artifact_after_root_update = try readFile(allocator, root_only_manifest.valid.artifact_absolute_path);
    defer allocator.free(artifact_after_root_update);
    try std.testing.expectEqualStrings(artifact_before_root_update, artifact_after_root_update);

    try expectRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "policy_digest_mismatch", &.{
        root_only_manifest.valid.package_root_sha256,
        initial_manifest.valid.package_root_sha256,
        "requiredPolicy=",
        "attemptedPolicy=",
        "scope=user",
    });

    const exact_user_root_only_policy_key = try exactWasmPolicyKeyForTest(allocator, &root_only_manifest.valid, "user");
    defer allocator.free(exact_user_root_only_policy_key);
    try writeAuthorSettingsWithPolicies(allocator, settings_path, persisted_source, &.{exact_user_root_only_policy_key}, "template.echo");
    {
        var runtime_set = try startAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
        defer runtime_set.deinit();
        try std.testing.expectEqual(@as(usize, 1), runtime_set.entries.len);
        try std.testing.expectEqualStrings(exact_user_root_only_policy_key, runtime_set.entries[0].policy_lookup_key);
    }

    const lock_before_missing = try readFile(allocator, lock_path);
    defer allocator.free(lock_before_missing);
    try tools_common.writeFileAbsolute(std.testing.io, lock_path, "{ malformed", true);
    try expectRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "malformed_lockfile", &.{
        "Malformed extension provenance lockfile",
        "extensions.lock.json",
    });
    const lock_after_malformed = try readFile(allocator, lock_path);
    defer allocator.free(lock_after_malformed);
    try std.testing.expectEqualStrings("{ malformed", lock_after_malformed);
    try tools_common.writeFileAbsolute(std.testing.io, lock_path, lock_before_missing, true);

    try std.Io.Dir.deleteFileAbsolute(std.testing.io, lock_path);
    try expectRuntimeDeniedWithFields(allocator, home_dir, agent_dir, project_dir, "missing_lockfile", &.{
        "missing extension provenance lockfile",
        "extensions.lock.json",
    });
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.statFile(.cwd(), std.testing.io, lock_path, .{}));
    try tools_common.writeFileAbsolute(std.testing.io, lock_path, lock_before_missing, true);

    var project_install = try runPackageCommand(allocator, &.{ "install", package_root, "-l" }, .{
        .cwd = project_dir,
        .agent_dir = agent_dir,
    });
    defer project_install.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 0), project_install.exit_code);

    try writeAuthorSettingsWithPolicies(allocator, settings_path, persisted_source, &.{exact_user_root_only_policy_key}, "template.echo");
    try expectRuntimeDiagnosticWithFields(allocator, home_dir, agent_dir, project_dir, "missing_policy", &.{
        "scope=project",
        root_only_manifest.valid.package_root_sha256,
        root_only_manifest.valid.artifact_sha256,
    }, 1);
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

fn normalConstructionFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    const tools = context.tools orelse &.{};
    const response_text = responseTextForNormalConstructionPrompt(prompt) orelse return error.UnexpectedNormalConstructionPrompt;
    if (std.mem.eql(u8, prompt, "default construction") or std.mem.eql(u8, prompt, "json construction") or std.mem.eql(u8, prompt, "mixed construction")) {
        try expectProviderToolPresent(tools, "read");
        try expectProviderToolPresent(tools, "bash");
        try expectProviderToolPresent(tools, "write");
        try expectProviderToolPresent(tools, "edit");
        try expectProviderToolPresent(tools, "grep");
        try expectProviderToolPresent(tools, "find");
        try expectProviderToolPresent(tools, "ls");
        try expectProviderToolPresent(tools, "template.echo");
        if (std.mem.eql(u8, prompt, "mixed construction")) {
            try expectProviderToolPresent(tools, "native.echo");
        }
    } else if (std.mem.eql(u8, prompt, "selected builtins")) {
        try expectProviderToolNamesExactly(tools, &.{ "read", "grep" });
    } else if (std.mem.eql(u8, prompt, "selected wasm")) {
        try expectProviderToolNamesExactly(tools, &.{"template.echo"});
    } else if (std.mem.eql(u8, prompt, "no tools")) {
        try expectProviderToolNamesExactly(tools, &.{});
    } else if (std.mem.eql(u8, prompt, "no builtins")) {
        try expectProviderToolNamesExactly(tools, &.{"template.echo"});
    } else if (std.mem.eql(u8, prompt, "no tools explicit wasm")) {
        try expectProviderToolNamesExactly(tools, &.{"template.echo"});
    } else {
        return error.UnexpectedNormalConstructionPrompt;
    }

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText(response_text);
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

fn responseTextForNormalConstructionPrompt(prompt: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, prompt, "default construction")) return "default construction ok";
    if (std.mem.eql(u8, prompt, "selected builtins")) return "selected builtins ok";
    if (std.mem.eql(u8, prompt, "selected wasm")) return "selected wasm ok";
    if (std.mem.eql(u8, prompt, "no tools")) return "no tools ok";
    if (std.mem.eql(u8, prompt, "no builtins")) return "no builtins ok";
    if (std.mem.eql(u8, prompt, "no tools explicit wasm")) return "no tools explicit wasm ok";
    if (std.mem.eql(u8, prompt, "json construction")) return "json construction ok";
    if (std.mem.eql(u8, prompt, "mixed construction")) return "mixed construction ok";
    return null;
}

fn forcedWasmSuccessToolCallFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("call installed wasm", prompt);

    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"message\":\"normal agent path\"}", .{});
    defer args.deinit();
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = try ai.providers.faux.fauxToolCall(allocator, "template.echo", args.value, .{ .id = "wasm-normal-success" });
    return ai.providers.faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
}

fn verifyWasmSuccessResultFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try expectLatestToolResult(context.messages, .{
        .tool_call_id = "wasm-normal-success",
        .tool_name = "template.echo",
        .is_error = false,
        .content_contains = "\"message\":\"normal agent path\"",
        .expected_extension_id = "com.pi.template.echo",
        .expected_artifact_sha256 = null,
    });

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("installed wasm success observed");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

fn forcedNativeSuccessToolCallFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("call installed native", prompt);

    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"message\":\"normal native path\"}", .{});
    defer args.deinit();
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = try ai.providers.faux.fauxToolCall(allocator, "native.echo", args.value, .{ .id = "native-normal-success" });
    return ai.providers.faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
}

fn verifyNativeSuccessResultFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try expectLatestToolResult(context.messages, .{
        .tool_call_id = "native-normal-success",
        .tool_name = "native.echo",
        .is_error = false,
        .content_contains = "\"message\":\"normal native path\"",
        .expected_runtime_kind = "native",
        .expected_extension_id = "com.pi.native.template.echo",
        .expected_artifact_sha256 = null,
    });

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("installed native success observed");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

fn forcedWasmInvalidInputToolCallFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("call installed wasm with invalid input", prompt);

    var args = try std.json.parseFromSlice(std.json.Value, allocator, "[]", .{});
    defer args.deinit();
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = try ai.providers.faux.fauxToolCall(allocator, "template.echo", args.value, .{ .id = "wasm-normal-invalid" });
    return ai.providers.faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
}

fn verifyWasmInvalidResultFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try expectLatestGenericToolError(context.messages, "wasm-normal-invalid", "template.echo", "InvalidToolArguments");

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("installed wasm invalid input observed");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

fn forcedUpdatedWasmSuccessToolCallFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("call updated installed wasm", prompt);

    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"operation\":\"echo\",\"value\":\"edited runtime output\"}", .{});
    defer args.deinit();
    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = try ai.providers.faux.fauxToolCall(allocator, "fixture.echo", args.value, .{ .id = "wasm-updated-success" });
    return ai.providers.faux.fauxAssistantMessage(blocks, .{ .stop_reason = .tool_use });
}

fn verifyUpdatedWasmSuccessResultFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try expectLatestToolResult(context.messages, .{
        .tool_call_id = "wasm-updated-success",
        .tool_name = "fixture.echo",
        .is_error = false,
        .content_contains = "\"echo\":\"edited runtime output\"",
        .expected_extension_id = "com.pi.template.echo",
        .expected_artifact_sha256 = null,
    });

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("updated installed wasm success observed");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

fn postRemoveConstructionFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("post-remove construction", prompt);
    const tools = context.tools orelse &.{};
    try expectProviderToolPresent(tools, "read");
    try expectProviderToolPresent(tools, "bash");
    try expectProviderToolAbsent(tools, "template.echo");
    try expectProviderToolAbsent(tools, "fixture.echo");

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("post-remove construction ok");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

fn aggregatePostRemoveConstructionFactory(
    allocator: std.mem.Allocator,
    context: ai.Context,
    _: ?ai.types.StreamOptions,
    _: *usize,
    _: ai.Model,
) !ai.providers.faux.FauxAssistantMessage {
    try std.testing.expect(context.messages.len >= 1);
    const prompt = context.messages[context.messages.len - 1].user.content[0].text.text;
    try std.testing.expectEqualStrings("aggregate post-remove construction", prompt);
    const tools = context.tools orelse &.{};
    try expectProviderToolPresent(tools, "read");
    try expectProviderToolPresent(tools, "bash");
    try expectProviderToolAbsent(tools, "template.echo");
    try expectProviderToolAbsent(tools, "native.echo");

    const blocks = try allocator.alloc(ai.providers.faux.FauxContentBlock, 1);
    blocks[0] = ai.providers.faux.fauxText("aggregate post-remove construction ok");
    return ai.providers.faux.fauxAssistantMessage(blocks, .{});
}

const ExpectedToolResult = struct {
    tool_call_id: []const u8,
    tool_name: []const u8,
    is_error: bool,
    content_contains: []const u8,
    expected_runtime_kind: []const u8 = "wasm",
    expected_extension_id: []const u8,
    expected_artifact_sha256: ?[]const u8,
};

fn expectLatestToolResult(messages: []const ai.Message, expected: ExpectedToolResult) !void {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .tool_result => |tool_result| {
                try std.testing.expectEqualStrings(expected.tool_call_id, tool_result.tool_call_id);
                try std.testing.expectEqualStrings(expected.tool_name, tool_result.tool_name);
                try std.testing.expectEqual(expected.is_error, tool_result.is_error);
                try std.testing.expect(std.mem.indexOf(u8, tool_result.content[0].text.text, expected.content_contains) != null);
                const details = tool_result.details orelse return error.ExpectedWasmRuntimeDetails;
                const runtime = details.object.get("extensionRuntime") orelse return error.ExpectedWasmRuntimeDetails;
                try std.testing.expectEqualStrings(expected.expected_runtime_kind, runtime.object.get("runtimeKind").?.string);
                try std.testing.expectEqualStrings(expected.expected_extension_id, runtime.object.get("extensionId").?.string);
                try std.testing.expectEqualStrings(expected.tool_name, runtime.object.get("toolId").?.string);
                if (expected.expected_artifact_sha256) |artifact_sha256| {
                    try std.testing.expectEqualStrings(artifact_sha256, runtime.object.get("artifactSha256").?.string);
                }
                return;
            },
            else => {},
        }
    }
    return error.ExpectedToolResultMissing;
}

fn expectLatestGenericToolError(
    messages: []const ai.Message,
    tool_call_id: []const u8,
    tool_name: []const u8,
    content_contains: []const u8,
) !void {
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        switch (messages[index]) {
            .tool_result => |tool_result| {
                try std.testing.expectEqualStrings(tool_call_id, tool_result.tool_call_id);
                try std.testing.expectEqualStrings(tool_name, tool_result.tool_name);
                try std.testing.expect(tool_result.is_error);
                try std.testing.expect(std.mem.indexOf(u8, tool_result.content[0].text.text, content_contains) != null);
                return;
            },
            else => {},
        }
    }
    return error.ExpectedToolResultMissing;
}

fn runNormalTemplateInvocation(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    session_dir: []const u8,
    model: ai.Model,
    expected_artifact_sha256: []const u8,
) !void {
    try runNormalTemplateInvocationWithPrompt(allocator, home_dir, agent_dir, project_dir, session_dir, model, .{
        .prompt = "call installed wasm",
        .expected_stdout = "installed wasm success observed\n",
        .tool_name = "template.echo",
        .tool_call_id = "wasm-normal-success",
        .content_contains = "\"message\":\"normal agent path\"",
        .expected_artifact_sha256 = expected_artifact_sha256,
    });
}

fn runNormalUpdatedTemplateInvocation(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    session_dir: []const u8,
    model: ai.Model,
    expected_artifact_sha256: []const u8,
) !void {
    try runNormalTemplateInvocationWithPrompt(allocator, home_dir, agent_dir, project_dir, session_dir, model, .{
        .prompt = "call updated installed wasm",
        .expected_stdout = "updated installed wasm success observed\n",
        .tool_name = "fixture.echo",
        .tool_call_id = "wasm-updated-success",
        .content_contains = "\"echo\":\"edited runtime output\"",
        .expected_artifact_sha256 = expected_artifact_sha256,
    });
}

fn runNormalNativeInvocation(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    session_dir: []const u8,
    model: ai.Model,
    expected_artifact_sha256: []const u8,
) !void {
    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();

    var app_context = interactive_mode.AppContext.init(project_dir, std.testing.io);
    var built_tools = try interactive_mode.buildAgentToolsWithOptions(allocator, &app_context, .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{"native.echo"}),
        .include_installed_wasm_tools = true,
        .include_installed_native_tools = true,
        .runtime_config = &runtime_config,
        .resource_options = .{
            .cwd = project_dir,
            .agent_dir = runtime_config.agent_dir,
            .global = interactive_mode.settingsResources(runtime_config.global_settings),
            .project = interactive_mode.settingsResources(runtime_config.project_settings),
            .include_default_extensions = false,
            .include_default_skills = false,
            .include_default_prompts = false,
            .include_default_themes = false,
        },
    });
    defer built_tools.deinit();
    try std.testing.expect(built_tools.locked_native_runtimes != null);
    try std.testing.expectEqual(@as(usize, 1), built_tools.locked_native_runtimes.?.entries.len);
    try expectBuiltToolPresent(built_tools.items, "native.echo");
    try expectBuiltToolAbsent(built_tools.items, "template.echo");

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_dir,
        .system_prompt = "sys",
        .model = model,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    const exit_code = try print_mode.runPrintMode(
        allocator,
        std.testing.io,
        &session,
        "call installed native",
        .{ .mode = .text, .install_signal_handlers = false },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    if (exit_code != 0) {
        std.debug.print("native invocation stdout:\n{s}\nnative invocation stderr:\n{s}\n", .{ stdout_capture.writer.buffered(), stderr_capture.writer.buffered() });
    }
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("installed native success observed\n", stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
    try expectLatestToolResult(session.agent.getMessages(), .{
        .tool_call_id = "native-normal-success",
        .tool_name = "native.echo",
        .is_error = false,
        .content_contains = "\"message\":\"normal native path\"",
        .expected_runtime_kind = "native",
        .expected_extension_id = "com.pi.native.template.echo",
        .expected_artifact_sha256 = expected_artifact_sha256,
    });
    try std.testing.expect(!built_tools.locked_native_runtimes.?.entries[0].loaded.unloaded);
}

const NormalInvocationExpected = struct {
    prompt: []const u8,
    expected_stdout: []const u8,
    tool_name: []const u8,
    tool_call_id: []const u8,
    content_contains: []const u8,
    expected_artifact_sha256: []const u8,
};

fn runNormalTemplateInvocationWithPrompt(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    session_dir: []const u8,
    model: ai.Model,
    expected: NormalInvocationExpected,
) !void {
    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();

    var app_context = interactive_mode.AppContext.init(project_dir, std.testing.io);
    var built_tools = try interactive_mode.buildAgentToolsWithOptions(allocator, &app_context, .{
        .selected_tools = tool_selection_mod.ToolSelection.fromAllowlist(&.{expected.tool_name}),
        .runtime_config = &runtime_config,
        .resource_options = .{
            .cwd = project_dir,
            .agent_dir = runtime_config.agent_dir,
            .global = interactive_mode.settingsResources(runtime_config.global_settings),
            .project = interactive_mode.settingsResources(runtime_config.project_settings),
            .include_default_extensions = false,
            .include_default_skills = false,
            .include_default_prompts = false,
            .include_default_themes = false,
        },
    });
    defer built_tools.deinit();
    try std.testing.expect(built_tools.locked_wasm_runtimes != null);
    try std.testing.expectEqual(@as(usize, 1), built_tools.locked_wasm_runtimes.?.entries.len);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_dir,
        .system_prompt = "sys",
        .model = model,
        .session_dir = session_dir,
        .tools = built_tools.items,
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();
    const exit_code = try print_mode.runPrintMode(
        allocator,
        std.testing.io,
        &session,
        expected.prompt,
        .{ .mode = .text, .install_signal_handlers = false },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings(expected.expected_stdout, stdout_capture.writer.buffered());
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
    try expectLatestToolResult(session.agent.getMessages(), .{
        .tool_call_id = expected.tool_call_id,
        .tool_name = expected.tool_name,
        .is_error = false,
        .content_contains = expected.content_contains,
        .expected_extension_id = "com.pi.template.echo",
        .expected_artifact_sha256 = expected.expected_artifact_sha256,
    });
    try std.testing.expectEqual(@as(usize, 0), built_tools.locked_wasm_runtimes.?.entries[0].adapter.pendingCount());
}

fn runNormalConstructionCase(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    model: ai.Model,
    prompt: []const u8,
    tool_options: interactive_mode.ToolBuildOptions,
    output_mode: print_mode.OutputMode,
    expected_stdout: ?[]const u8,
) !void {
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

    var app_context = interactive_mode.AppContext.init(project_dir, std.testing.io);
    var build_options = tool_options;
    build_options.runtime_config = &runtime_config;
    build_options.resource_options = .{
        .cwd = project_dir,
        .agent_dir = runtime_config.agent_dir,
        .global = interactive_mode.settingsResources(runtime_config.global_settings),
        .project = interactive_mode.settingsResources(runtime_config.project_settings),
        .include_default_extensions = false,
        .include_default_skills = false,
        .include_default_prompts = false,
        .include_default_themes = false,
    };

    var built_tools = try interactive_mode.buildAgentToolsWithOptions(allocator, &app_context, build_options);
    defer built_tools.deinit();

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = project_dir,
        .system_prompt = "sys",
        .model = model,
        .tools = built_tools.items,
    });
    defer session.deinit();

    var stdout_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_capture.deinit();
    var stderr_capture: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_capture.deinit();

    const exit_code = try print_mode.runPrintMode(
        allocator,
        std.testing.io,
        &session,
        prompt,
        .{
            .mode = output_mode,
            .install_signal_handlers = false,
        },
        &stdout_capture.writer,
        &stderr_capture.writer,
    );
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("", stderr_capture.writer.buffered());
    if (expected_stdout) |value| {
        try std.testing.expectEqualStrings(value, stdout_capture.writer.buffered());
    } else {
        try expectContains(stdout_capture.writer.buffered(), "\"type\":\"agent_start\"");
        try expectContains(stdout_capture.writer.buffered(), "\"type\":\"agent_end\"");
    }
}

fn expectProviderToolPresent(tools: []const ai.types.Tool, name: []const u8) !void {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return;
    }
    return error.ExpectedProviderToolMissing;
}

fn expectProviderToolAbsent(tools: []const ai.types.Tool, name: []const u8) !void {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return error.ExpectedProviderToolAbsent;
    }
}

fn expectProviderToolNamesExactly(tools: []const ai.types.Tool, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, tools.len);
    for (expected) |name| try expectProviderToolPresent(tools, name);
    for (tools) |tool| {
        var found = false;
        for (expected) |name| {
            if (std.mem.eql(u8, tool.name, name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

fn expectBuiltToolPresent(tools: []const agent.AgentTool, name: []const u8) !void {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return;
    }
    return error.ExpectedBuiltToolMissing;
}

fn expectBuiltToolAbsent(tools: []const agent.AgentTool, name: []const u8) !void {
    for (tools) |tool| {
        if (std.mem.eql(u8, tool.name, name)) return error.ExpectedBuiltToolAbsent;
    }
}

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
    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
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

fn loadAuthorRuntimeConfig(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
) !config_mod.RuntimeConfig {
    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("HOME", home_dir);
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);
    try env_map.put("PI_OFFLINE", "1");
    return config_mod.loadRuntimeConfigWithOptions(
        allocator,
        std.testing.io,
        &env_map,
        project_dir,
        .{ .discover_models = false },
    );
}

fn startNativeAuthorRuntimeSet(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
) !extension_runtime.LockedNativeRuntimeSet {
    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();

    return extension_runtime.startLockedNativePackageRuntimes(allocator, std.testing.io, &runtime_config, .{
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

fn buildAggregateAuthorTools(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    selection: tool_selection_mod.ToolSelection,
) !interactive_mode.BuiltTools {
    var runtime_config = try loadAuthorRuntimeConfig(allocator, home_dir, agent_dir, project_dir);
    defer runtime_config.deinit();
    var app_context = interactive_mode.AppContext.init(project_dir, std.testing.io);
    return interactive_mode.buildAgentToolsWithOptions(allocator, &app_context, .{
        .selected_tools = selection,
        .include_installed_wasm_tools = true,
        .include_installed_native_tools = true,
        .runtime_config = &runtime_config,
        .resource_options = .{
            .cwd = project_dir,
            .agent_dir = runtime_config.agent_dir,
            .global = interactive_mode.settingsResources(runtime_config.global_settings),
            .project = interactive_mode.settingsResources(runtime_config.project_settings),
            .include_default_extensions = false,
            .include_default_skills = false,
            .include_default_prompts = false,
            .include_default_themes = false,
        },
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
    defer if (result.details) |details| tools_common.deinitJsonValue(allocator, details);
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

fn expectRuntimeDeniedWithFields(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    expected_kind: []const u8,
    expected_fields: []const []const u8,
) !void {
    try expectRuntimeDiagnosticWithFields(allocator, home_dir, agent_dir, project_dir, expected_kind, expected_fields, 0);
}

fn expectRuntimeDiagnosticWithFields(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    expected_kind: []const u8,
    expected_fields: []const []const u8,
    expected_entries: usize,
) !void {
    var runtime_set = try startAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
    defer runtime_set.deinit();
    try std.testing.expectEqual(expected_entries, runtime_set.entries.len);
    for (runtime_set.diagnostics) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.kind, expected_kind)) continue;
        for (expected_fields) |field| {
            if (diagnostic.path) |path| {
                if (std.mem.indexOf(u8, path, field) != null) continue;
            }
            try expectContains(diagnostic.message, field);
        }
        return;
    }
    return error.ExpectedRuntimeDiagnosticMissing;
}

fn expectMixedRuntimeDeniedWithFields(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
    wasm_kind: []const u8,
    wasm_fields: []const []const u8,
    native_kind: []const u8,
    native_fields: []const []const u8,
) !void {
    try expectRuntimeDiagnosticWithFields(allocator, home_dir, agent_dir, project_dir, wasm_kind, wasm_fields, 0);
    var native_set = try startNativeAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
    defer native_set.deinit();
    try std.testing.expectEqual(@as(usize, 0), native_set.entries.len);
    try expectDiagnosticFields(native_set.diagnostics, native_kind, native_fields);
}

fn expectMixedRuntimeProjectDenied(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    agent_dir: []const u8,
    project_dir: []const u8,
) !void {
    try expectRuntimeDiagnosticWithFields(allocator, home_dir, agent_dir, project_dir, "missing_policy", &.{"scope=project"}, 1);
    var native_set = try startNativeAuthorRuntimeSet(allocator, home_dir, agent_dir, project_dir);
    defer native_set.deinit();
    try std.testing.expectEqual(@as(usize, 1), native_set.entries.len);
    try expectDiagnosticFields(native_set.diagnostics, "missing_policy", &.{"scope=project"});
}

fn expectDiagnosticFields(
    diagnostics: []const resources_mod.Diagnostic,
    expected_kind: []const u8,
    expected_fields: []const []const u8,
) !void {
    for (diagnostics) |diagnostic| {
        if (!std.mem.eql(u8, diagnostic.kind, expected_kind)) continue;
        for (expected_fields) |field| {
            if (diagnostic.path) |path| {
                if (std.mem.indexOf(u8, path, field) != null) continue;
            }
            try expectContains(diagnostic.message, field);
        }
        return;
    }
    return error.ExpectedRuntimeDiagnosticMissing;
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

fn writeAuthorSettingsWithPolicies(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    source: []const u8,
    policy_keys: []const []const u8,
    tool_scope: []const u8,
) !void {
    const source_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = source }, .{});
    defer allocator.free(source_json);
    const tool_scope_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = tool_scope }, .{});
    defer allocator.free(tool_scope_json);

    var policies: std.Io.Writer.Allocating = .init(allocator);
    defer policies.deinit();
    for (policy_keys, 0..) |policy_key, index| {
        if (index > 0) try policies.writer.writeAll(",");
        try std.json.Stringify.value(policy_key, .{}, &policies.writer);
        try policies.writer.print(
            \\:{{"resourceLimits":{{"toolScopes":[{s}],"outputBytes":65536}}}}
        , .{tool_scope_json});
    }

    const settings = try std.fmt.allocPrint(allocator,
        \\{{"packages":[{{"source":{s}}}],"extensionPolicies":{{{s}}}}}
    , .{ source_json, policies.written() });
    defer allocator.free(settings);
    try tools_common.writeFileAbsolute(std.testing.io, settings_path, settings, true);
}

const AggregatePolicyEntry = struct {
    source: []const u8,
    policy_key: []const u8,
    tool_scope: []const u8,
};

fn writeAggregateAuthorSettings(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    entries: []const AggregatePolicyEntry,
) !void {
    var packages: std.Io.Writer.Allocating = .init(allocator);
    defer packages.deinit();
    var policies: std.Io.Writer.Allocating = .init(allocator);
    defer policies.deinit();

    for (entries, 0..) |entry, index| {
        if (index > 0) {
            try packages.writer.writeAll(",");
            try policies.writer.writeAll(",");
        }
        const source_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = entry.source }, .{});
        defer allocator.free(source_json);
        const policy_key_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = entry.policy_key }, .{});
        defer allocator.free(policy_key_json);
        const tool_scope_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = entry.tool_scope }, .{});
        defer allocator.free(tool_scope_json);

        try packages.writer.print("{{\"source\":{s}}}", .{source_json});
        try policies.writer.print(
            \\{s}:{{"approvedGrants":[],"resourceLimits":{{"toolScopes":[{s}],"outputBytes":65536}}}}
        , .{ policy_key_json, tool_scope_json });
    }

    const settings = try std.fmt.allocPrint(allocator,
        \\{{"packages":[{s}],"extensionPolicies":{{{s}}}}}
    , .{ packages.written(), policies.written() });
    defer allocator.free(settings);
    try tools_common.writeFileAbsolute(std.testing.io, settings_path, settings, true);
}

fn exactWasmPolicyKeyForTest(
    allocator: std.mem.Allocator,
    manifest: *const wasm_manifest.Manifest,
    scope: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "wasm:locked:{s}:{s}:{s}:{s}:{s}:{s}:{s}:{s}",
        .{
            scope,
            manifest.schema_version,
            manifest.id,
            manifest.version,
            manifest.package_root_sha256,
            manifest.artifact_sha256,
            manifest.manifest_path,
            manifest.artifact_absolute_path,
        },
    );
}

fn legacyArtifactOnlyPolicyKeyForTest(
    allocator: std.mem.Allocator,
    manifest: *const wasm_manifest.Manifest,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "wasm:{s}:{s}:{s}:{s}:{s}:{s}",
        .{
            manifest.schema_version,
            manifest.id,
            manifest.version,
            manifest.artifact_sha256,
            manifest.manifest_path,
            manifest.artifact_absolute_path,
        },
    );
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

fn extractApprovalTarget(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const marker = "approval target:";
    const marker_index = std.mem.indexOf(u8, text, marker) orelse return error.ExpectedApprovalTarget;
    const after_marker = std.mem.trim(u8, text[marker_index + marker.len ..], " \t");
    const newline_index = std.mem.indexOfScalar(u8, after_marker, '\n') orelse after_marker.len;
    return allocator.dupe(u8, std.mem.trim(u8, after_marker[0..newline_index], " \t\r\n"));
}

fn extractApprovalTargetWithPrefix(allocator: std.mem.Allocator, text: []const u8, prefix: []const u8) ![]u8 {
    const marker = "approval target:";
    var remainder = text;
    while (std.mem.indexOf(u8, remainder, marker)) |marker_index| {
        const after_marker = std.mem.trim(u8, remainder[marker_index + marker.len ..], " \t");
        const newline_index = std.mem.indexOfScalar(u8, after_marker, '\n') orelse after_marker.len;
        const candidate = std.mem.trim(u8, after_marker[0..newline_index], " \t\r\n");
        if (std.mem.startsWith(u8, candidate, prefix)) return allocator.dupe(u8, candidate);
        remainder = after_marker[newline_index..];
    }
    return error.ExpectedApprovalTarget;
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

fn copyNativeTemplateToTmp(allocator: std.mem.Allocator, tmp: anytype, package_relative_path: []const u8) ![]u8 {
    try tmp.dir.createDirPath(std.testing.io, package_relative_path);
    for (NATIVE_TEMPLATE_FILES) |relative_path| {
        if (std.fs.path.dirname(relative_path)) |dirname| {
            const target_dir = try std.fs.path.join(allocator, &.{ package_relative_path, dirname });
            defer allocator.free(target_dir);
            try tmp.dir.createDirPath(std.testing.io, target_dir);
        }
        const source_path = try std.fs.path.join(allocator, &.{ NATIVE_TEMPLATE_ROOT, relative_path });
        defer allocator.free(source_path);
        const bytes = try readFile(allocator, source_path);
        defer allocator.free(bytes);
        const target_path = try std.fs.path.join(allocator, &.{ package_relative_path, relative_path });
        defer allocator.free(target_path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = target_path, .data = bytes });
    }
    return absoluteTmpPath(allocator, &tmp.sub_path, package_relative_path);
}

fn writeNativeDynamicPackage(allocator: std.mem.Allocator, tmp: anytype, package_relative_path: []const u8) ![]u8 {
    try tmp.dir.createDirPath(std.testing.io, package_relative_path);
    const bin_relative_path = try std.fs.path.join(allocator, &.{ package_relative_path, "bin" });
    defer allocator.free(bin_relative_path);
    try tmp.dir.createDirPath(std.testing.io, bin_relative_path);
    const artifact_relative_path = try std.fs.path.join(allocator, &.{ package_relative_path, "bin/plugin.dylib" });
    defer allocator.free(artifact_relative_path);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = artifact_relative_path,
        .data = "native dynamic plugin placeholder",
    });
    const manifest_relative_path = try std.fs.path.join(allocator, &.{ package_relative_path, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_relative_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_relative_path, .data =
        \\{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.pi.native.dynamic",
        \\  "name": "Native Dynamic",
        \\  "version": "0.1.0",
        \\  "description": "Unsupported native dynamic package.",
        \\  "artifact": {
        \\    "kind": "native-dylib",
        \\    "path": "bin/plugin.dylib"
        \\  },
        \\  "tool": {
        \\    "id": "native.dynamic",
        \\    "description": "Unsupported native dynamic tool.",
        \\    "inputSchema": {},
        \\    "outputSchema": {}
        \\  },
        \\  "capabilities": []
        \\}
        \\
    });
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

fn runNativeTemplateBuild(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build", "-p", "." },
        .cwd = .{ .path = package_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) {
        std.debug.print("native zig build stdout:\n{s}\nnative zig build stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.NativeTemplateBuildFailed;
    }
}

fn runNativeTemplateValidate(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const result = try std.process.run(allocator, std.testing.io, .{
        .argv = &.{ "zig", "build", "-p", ".", "validate" },
        .cwd = .{ .path = package_root },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (exitCodeFromTerm(result.term) != 0) {
        std.debug.print("native zig build validate stdout:\n{s}\nnative zig build validate stderr:\n{s}\n", .{ result.stdout, result.stderr });
        return error.NativeTemplateValidationFailed;
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
        \\    "0.1.0",
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
        \\  "version": "0.1.0",
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

fn writeRootOnlyAuthorManifest(allocator: std.mem.Allocator, package_root: []const u8) !void {
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    try tools_common.writeFileAbsolute(std.testing.io, manifest_path,
        \\{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.pi.template.echo",
        \\  "name": "Pi Zig Echo Template",
        \\  "version": "0.1.0",
        \\  "description": "Root-only metadata change for digest-bound policy validation.",
        \\  "artifact": {
        \\    "kind": "wasm-component",
        \\    "path": "wasm/plugin.wasm"
        \\  },
        \\  "tool": {
        \\    "id": "template.echo",
        \\    "description": "Echoes a message field from the JSON input.",
        \\    "inputSchema": {
        \\      "type": "object",
        \\      "required": ["message"],
        \\      "properties": {
        \\        "message": { "type": "string" }
        \\      }
        \\    },
        \\    "outputSchema": {
        \\      "type": "object",
        \\      "required": ["message"],
        \\      "properties": {
        \\        "message": { "type": "string" }
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

fn writePackageRootDriftFile(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    relative_path: []const u8,
    contents: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ package_root, relative_path });
    defer allocator.free(path);
    try tools_common.writeFileAbsolute(std.testing.io, path, contents, true);
}

fn expectPackageTreeExcludesProductSurfaces(allocator: std.mem.Allocator, package_root: []const u8) !void {
    var dir = try std.Io.Dir.openDir(.cwd(), std.testing.io, package_root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    try expectDirectoryTreeExcludesProductSurfaces(allocator, package_root, &dir);
}

fn expectDirectoryTreeExcludesProductSurfaces(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    dir: *std.Io.Dir,
) !void {
    var iterator = dir.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ root_path, entry.name });
        defer allocator.free(child_path);
        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, ".zig-cache") or std.mem.eql(u8, entry.name, "zig-out")) continue;
                var child_dir = try std.Io.Dir.openDir(.cwd(), std.testing.io, child_path, .{ .iterate = true });
                defer child_dir.close(std.testing.io);
                try expectDirectoryTreeExcludesProductSurfaces(allocator, child_path, &child_dir);
            },
            .file => {
                if (std.mem.indexOf(u8, child_path, std.fs.path.sep_str ++ "sdk" ++ std.fs.path.sep_str) != null) continue;
                const ext = std.fs.path.extension(child_path);
                if (std.mem.eql(u8, ext, ".wasm") or std.mem.eql(u8, ext, ".dylib") or std.mem.eql(u8, ext, ".so") or std.mem.eql(u8, ext, ".dll")) continue;
                const bytes = try readFile(allocator, child_path);
                defer allocator.free(bytes);
                try expectNotContains(bytes, "Web Simulator");
                try expectNotContains(bytes, "Workflow");
                try expectNotContains(bytes, "Wiki");
                try expectNotContains(bytes, "QA");
                try expectNotContains(bytes, "Review");
                try expectNotContains(bytes, "marketplace");
                try expectNotContains(bytes, "signing");
                try expectNotContains(bytes, "Remote WASM");
                try expectNotContains(bytes, "remote WASM");
            },
            else => {},
        }
    }
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
