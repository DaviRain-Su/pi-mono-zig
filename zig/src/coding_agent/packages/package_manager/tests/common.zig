pub const std = @import("std");
pub const common = @import("../../../tools/common.zig");
pub const config_selector = @import("../../config_selector.zig");
pub const extension_manifest = @import("../../../extensions/extension_manifest.zig");
pub const extension_runtime = @import("../../../extensions/extension_runtime.zig");
pub const native_manifest = @import("../../../extensions/native/native_manifest.zig");
pub const package_manager = @import("../../package_manager.zig");
pub const package_settings_store = @import("../../package_settings_store.zig");
pub const package_sources = @import("../../package_sources.zig");
pub const policy_key_mod = @import("../../../extensions/policy_key.zig");
pub const provenance_lockfile = @import("../../provenance_lockfile.zig");
pub const resources_mod = @import("../../../resources/resources.zig");
pub const self_update = @import("../../self_update.zig");
pub const wasm_manifest = @import("../../../extensions/wasm/wasm_manifest.zig");

pub const ConfigSelectorState = config_selector.ConfigSelectorState;
pub const ExecuteOptions = package_manager.ExecuteOptions;
pub const ExecuteResult = package_manager.ExecuteResult;
pub const executePackageCommand = package_manager.executePackageCommand;
pub const gitInstallPath = package_sources.gitInstallPath;
pub const loadSelectorState = config_selector.loadSelectorState;
pub const loadSettingsObject = package_settings_store.loadSettingsObject;
pub const normalizePackageSourceForSettings = package_sources.normalizePackageSourceForSettings;
pub const package_name = self_update.package_name;
pub const parsePackageCommand = package_manager.parsePackageCommand;
pub const saveSelectorState = config_selector.saveSelectorState;

// ---------------------------------------------------------------------
// Tests: deterministic local fixture coverage for VAL-M12-PKG-001..009.
// ---------------------------------------------------------------------

pub fn makeAbsoluteTmpPath(allocator: std.mem.Allocator, tmp: anytype, relative: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const rel = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        relative,
    });
    defer allocator.free(rel);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, rel });
}

pub fn readSettings(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(1024 * 1024));
}

pub fn readOptionalTestFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

pub fn lockfilePathForTest(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    agent_dir: []const u8,
    is_project: bool,
) ![]u8 {
    if (is_project) return std.fs.path.join(allocator, &[_][]const u8{ cwd, ".pi", "extensions.lock.json" });
    return std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "extensions.lock.json" });
}

pub fn readFirstPackageSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const settings = try readSettings(allocator, path);
    defer allocator.free(settings);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, settings, .{});
    defer parsed.deinit();
    const packages = parsed.value.object.get("packages").?.array;
    const first = packages.items[0];
    return switch (first) {
        .string => |source| try allocator.dupe(u8, source),
        .object => |object| try allocator.dupe(u8, object.get("source").?.string),
        else => error.InvalidPackageSource,
    };
}

pub fn runCommand(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    options: ExecuteOptions,
    stdout_buffer: *std.ArrayList(u8),
    stderr_buffer: *std.ArrayList(u8),
) !ExecuteResult {
    var stdout_writer = std.Io.Writer.Allocating.fromArrayList(allocator, stdout_buffer);
    var stderr_writer = std.Io.Writer.Allocating.fromArrayList(allocator, stderr_buffer);
    defer {
        stdout_buffer.* = stdout_writer.toArrayList();
        stderr_buffer.* = stderr_writer.toArrayList();
    }

    var parsed = try parsePackageCommand(allocator, args);
    defer parsed.deinit(allocator);
    return executePackageCommand(allocator, std.testing.io, parsed, options, &stdout_writer.writer, &stderr_writer.writer);
}

pub fn fakeNetworkOptions(cwd: []const u8, agent_dir: []const u8) ExecuteOptions {
    return .{
        .cwd = cwd,
        .agent_dir = agent_dir,
        .npm_command_override = &.{"/usr/bin/true"},
        .git_command_override = &.{"/usr/bin/true"},
        .self_update_command_override = &.{"/usr/bin/true"},
    };
}

pub fn makeSelfUpdateRecorderScript(
    allocator: std.mem.Allocator,
    log_path: []const u8,
    fail_install: bool,
) ![]u8 {
    if (fail_install) {
        return std.fmt.allocPrint(
            allocator,
            "printf '%s %s\\n' \"$0\" \"$*\" >> \"{s}\"; if [ \"$0\" = install ]; then exit 7; fi",
            .{log_path},
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "printf '%s %s\\n' \"$0\" \"$*\" >> \"{s}\"",
        .{log_path},
    );
}

pub fn readSelfUpdateLog(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, path, allocator, .limited(1024 * 1024));
}

pub fn writeWasmPackageFixture(
    tmp: anytype,
    package_relative_path: []const u8,
    capability: []const u8,
    write_artifact: bool,
) !void {
    const wasm_dir = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ package_relative_path, "wasm" });
    defer std.testing.allocator.free(wasm_dir);
    try tmp.dir.createDirPath(std.testing.io, wasm_dir);
    if (write_artifact) {
        const artifact_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ package_relative_path, "wasm/example-tool.wasm" });
        defer std.testing.allocator.free(artifact_path);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = artifact_path, .data = "\x00asm" });
    }
    const manifest_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{ package_relative_path, wasm_manifest.MANIFEST_FILE_NAME });
    defer std.testing.allocator.free(manifest_path);
    const manifest = try std.fmt.allocPrint(std.testing.allocator,
        \\{{
        \\  "schemaVersion": "pi-extension.v0",
        \\  "id": "com.example.policy",
        \\  "name": "Policy Example",
        \\  "version": "0.1.0",
        \\  "description": "Policy fixture.",
        \\  "artifact": {{ "kind": "wasm-component", "path": "wasm/example-tool.wasm" }},
        \\  "tool": {{
        \\    "id": "example.policy",
        \\    "description": "Policy tool.",
        \\    "inputSchema": {{}},
        \\    "outputSchema": {{}}
        \\  }},
        \\  "capabilities": ["{s}"]
        \\}}
    , .{capability});
    defer std.testing.allocator.free(manifest);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = manifest });
}

pub fn writePolicySettings(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    policy_key: []const u8,
    approved_grant: []const u8,
    include_resource_limits: bool,
) !void {
    const grants_json = try std.fmt.allocPrint(allocator, "\"{s}\"", .{approved_grant});
    defer allocator.free(grants_json);
    try writePolicySettingsGrantList(allocator, settings_path, policy_key, grants_json, include_resource_limits);
}

pub fn writePolicySettingsGrantList(
    allocator: std.mem.Allocator,
    settings_path: []const u8,
    policy_key: []const u8,
    approved_grants_json: []const u8,
    include_resource_limits: bool,
) !void {
    const quoted_key = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .string = policy_key }, .{});
    defer allocator.free(quoted_key);
    const resource_limits = if (include_resource_limits) ", \"resourceLimits\": { \"timeoutMs\": 1000 }" else "";
    const settings = try std.fmt.allocPrint(allocator,
        \\{{
        \\  "extensionPolicies": {{
        \\    {s}: {{ "approvedGrants": [{s}]{s} }}
        \\  }}
        \\}}
    , .{ quoted_key, approved_grants_json, resource_limits });
    defer allocator.free(settings);
    try common.writeFileAbsolute(std.testing.io, settings_path, settings, true);
}
