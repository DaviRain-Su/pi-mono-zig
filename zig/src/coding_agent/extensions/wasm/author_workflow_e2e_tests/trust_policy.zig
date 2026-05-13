const common = @import("common.zig");
const std = common.std;
const agent = common.agent;
const ai = common.ai;
const tools_common = common.tools_common;
const wasm_manifest = common.wasm_manifest;
const runPackageCommand = common.runPackageCommand;
const startAuthorRuntimeSet = common.startAuthorRuntimeSet;
const expectRuntimeDeniedWithFields = common.expectRuntimeDeniedWithFields;
const expectRuntimeDiagnosticWithFields = common.expectRuntimeDiagnosticWithFields;
const writeAuthorSettingsWithPolicies = common.writeAuthorSettingsWithPolicies;
const exactWasmPolicyKeyForTest = common.exactWasmPolicyKeyForTest;
const legacyArtifactOnlyPolicyKeyForTest = common.legacyArtifactOnlyPolicyKeyForTest;
const installedPackageSource = common.installedPackageSource;
const copyTemplateToTmp = common.copyTemplateToTmp;
const runTemplateBuild = common.runTemplateBuild;
const writeRootOnlyAuthorManifest = common.writeRootOnlyAuthorManifest;
const appendFile = common.appendFile;
const readFile = common.readFile;
const absoluteTmpPath = common.absoluteTmpPath;

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
