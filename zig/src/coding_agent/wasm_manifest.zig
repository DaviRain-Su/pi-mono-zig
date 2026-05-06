const std = @import("std");

pub const MANIFEST_FILE_NAME = "pi-extension.json";
pub const SCHEMA_VERSION = "pi-extension.v0";

pub const LifecyclePhase = enum {
    discover,
    validate,
    load,
    initialize,
    call,
    unload,

    pub fn jsonName(self: LifecyclePhase) []const u8 {
        return switch (self) {
            .discover => "discover",
            .validate => "validate",
            .load => "load",
            .initialize => "initialize",
            .call => "call",
            .unload => "unload",
        };
    }
};

pub const ArtifactKind = enum {
    wasm_component,

    pub fn jsonName(self: ArtifactKind) []const u8 {
        return switch (self) {
            .wasm_component => "wasm-component",
        };
    }
};

pub const Capability = enum {
    file_read,
    file_write,
    network,
    shell,
    env,
    model,
    session,
    ui_notify,

    pub fn jsonName(self: Capability) []const u8 {
        return switch (self) {
            .file_read => "file.read",
            .file_write => "file.write",
            .network => "network",
            .shell => "shell",
            .env => "env",
            .model => "model",
            .session => "session",
            .ui_notify => "ui.notify",
        };
    }

    pub fn enforcementBranch(self: Capability) CapabilityEnforcementBranch {
        return switch (self) {
            .file_read => .filesystem_read,
            .file_write => .filesystem_write,
            .network => .network_request,
            .shell => .shell_process,
            .env => .environment_variable,
            .model => .model_call,
            .session => .session_state,
            .ui_notify => .ui_notification,
        };
    }
};

pub const CANONICAL_CAPABILITIES = [_]Capability{
    .file_read,
    .file_write,
    .network,
    .shell,
    .env,
    .model,
    .session,
    .ui_notify,
};

pub const CapabilityEnforcementBranch = enum {
    filesystem_read,
    filesystem_write,
    network_request,
    shell_process,
    environment_variable,
    model_call,
    session_state,
    ui_notification,

    pub fn jsonName(self: CapabilityEnforcementBranch) []const u8 {
        return switch (self) {
            .filesystem_read => "filesystem.read",
            .filesystem_write => "filesystem.write",
            .network_request => "network.request",
            .shell_process => "shell.process",
            .environment_variable => "environment.variable",
            .model_call => "model.call",
            .session_state => "session.state",
            .ui_notification => "ui.notification",
        };
    }
};

pub const CapabilityDenialDiagnostic = struct {
    category: []const u8 = "denied_capability",
    capability: Capability,
    branch: CapabilityEnforcementBranch,
    phase: LifecyclePhase,
    mode: []const u8,

    pub fn capabilityId(self: CapabilityDenialDiagnostic) []const u8 {
        return self.capability.jsonName();
    }
};

pub fn denyFirstUnapprovedCapability(
    requested_capabilities: []const Capability,
    approved_capabilities: []const Capability,
    phase: LifecyclePhase,
    mode: []const u8,
) ?CapabilityDenialDiagnostic {
    for (requested_capabilities) |capability| {
        if (hasCapability(approved_capabilities, capability)) continue;
        return denyCapability(capability, phase, mode);
    }
    return null;
}

pub fn denyRuntimeCapability(
    capability: Capability,
    phase: LifecyclePhase,
    mode: []const u8,
) CapabilityDenialDiagnostic {
    return denyCapability(capability, phase, mode);
}

pub fn runtimeImportCapability(module_name: []const u8, field_name: []const u8) ?Capability {
    if (std.mem.eql(u8, module_name, "pi:filesystem") and std.mem.eql(u8, field_name, "read")) return .file_read;
    if (std.mem.eql(u8, module_name, "pi:filesystem") and std.mem.eql(u8, field_name, "write")) return .file_write;
    if (std.mem.eql(u8, module_name, "pi:network") and std.mem.eql(u8, field_name, "fetch")) return .network;
    if (std.mem.eql(u8, module_name, "pi:shell") and std.mem.eql(u8, field_name, "run")) return .shell;
    if (std.mem.eql(u8, module_name, "pi:environment") and std.mem.eql(u8, field_name, "get")) return .env;
    if (std.mem.eql(u8, module_name, "pi:model") and std.mem.eql(u8, field_name, "call")) return .model;
    if (std.mem.eql(u8, module_name, "pi:session") and std.mem.eql(u8, field_name, "get")) return .session;
    if (std.mem.eql(u8, module_name, "pi:ui") and std.mem.eql(u8, field_name, "notify")) return .ui_notify;
    return null;
}

pub fn denyRuntimeImport(
    module_name: []const u8,
    field_name: []const u8,
    phase: LifecyclePhase,
    mode: []const u8,
) ?CapabilityDenialDiagnostic {
    const capability = runtimeImportCapability(module_name, field_name) orelse return null;
    return denyRuntimeCapability(capability, phase, mode);
}

fn denyCapability(capability: Capability, phase: LifecyclePhase, mode: []const u8) CapabilityDenialDiagnostic {
    return .{
        .capability = capability,
        .branch = capability.enforcementBranch(),
        .phase = phase,
        .mode = mode,
    };
}

fn hasCapability(capabilities: []const Capability, needle: Capability) bool {
    for (capabilities) |capability| {
        if (capability == needle) return true;
    }
    return false;
}

pub const Diagnostic = struct {
    category: []const u8 = "validation_error",
    phase: LifecyclePhase,
    path: []u8,
    capability: ?Capability = null,
    message: []u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const Manifest = struct {
    schema_version: []u8,
    id: []u8,
    name: []u8,
    version: []u8,
    description: []u8,
    artifact_kind: ArtifactKind,
    artifact_path: []u8,
    artifact_absolute_path: []u8,
    tool_id: []u8,
    tool_description: []u8,
    requested_capabilities: []Capability,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.schema_version);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.artifact_path);
        allocator.free(self.artifact_absolute_path);
        allocator.free(self.tool_id);
        allocator.free(self.tool_description);
        allocator.free(self.requested_capabilities);
        self.* = undefined;
    }
};

pub const ValidationResult = union(enum) {
    valid: Manifest,
    invalid: []Diagnostic,

    pub fn deinit(self: *ValidationResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .valid => |*manifest| manifest.deinit(allocator),
            .invalid => |diagnostics| {
                for (diagnostics) |*diagnostic| diagnostic.deinit(allocator);
                allocator.free(diagnostics);
            },
        }
        self.* = undefined;
    }
};

pub fn validateManifestText(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    manifest_text: []const u8,
) !ValidationResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{}) catch {
        return invalidOne(allocator, .validate, "$", "malformed JSON");
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |object| object,
        else => return invalidOne(allocator, .validate, "$", "expected object"),
    };

    if (try requiredString(allocator, root, "$", "schemaVersion")) |diagnostic| return diagnostic;
    const schema_version = requiredStringValue(root, "schemaVersion");
    if (!std.mem.eql(u8, schema_version, SCHEMA_VERSION)) {
        const message = try std.fmt.allocPrint(
            allocator,
            "unsupported schema version \"{s}\"; expected " ++ SCHEMA_VERSION,
            .{schema_version},
        );
        defer allocator.free(message);
        return invalidOne(allocator, .validate, "$.schemaVersion", message);
    }
    if (try requiredString(allocator, root, "$", "id")) |diagnostic| return diagnostic;
    const extension_id = requiredStringValue(root, "id");
    if (try requiredString(allocator, root, "$", "name")) |diagnostic| return diagnostic;
    const extension_name = requiredStringValue(root, "name");
    if (try requiredString(allocator, root, "$", "version")) |diagnostic| return diagnostic;
    const extension_version = requiredStringValue(root, "version");
    if (try requiredString(allocator, root, "$", "description")) |diagnostic| return diagnostic;
    const extension_description = requiredStringValue(root, "description");

    if (try requiredObject(allocator, root, "$", "artifact")) |diagnostic| return diagnostic;
    const artifact_object = requiredObjectValue(root, "artifact");
    if (try requiredString(allocator, artifact_object, "$.artifact", "kind")) |diagnostic| return diagnostic;
    const artifact_kind_text = requiredStringValue(artifact_object, "kind");
    const artifact_kind = parseArtifactKind(artifact_kind_text) orelse {
        const message = try std.fmt.allocPrint(
            allocator,
            "unsupported artifact kind \"{s}\"; expected wasm-component",
            .{artifact_kind_text},
        );
        defer allocator.free(message);
        return invalidOne(allocator, .validate, "$.artifact.kind", message);
    };
    if (try requiredString(allocator, artifact_object, "$.artifact", "path")) |diagnostic| return diagnostic;
    const artifact_path = requiredStringValue(artifact_object, "path");

    if (root.get("tools") != null) {
        return invalidOne(allocator, .validate, "$.tools", "v0 manifests must declare exactly one tool in $.tool");
    }
    if (try requiredObject(allocator, root, "$", "tool")) |diagnostic| return diagnostic;
    const tool_object = requiredObjectValue(root, "tool");
    if (try requiredString(allocator, tool_object, "$.tool", "id")) |diagnostic| return diagnostic;
    const tool_id = requiredStringValue(tool_object, "id");
    if (try requiredString(allocator, tool_object, "$.tool", "description")) |diagnostic| return diagnostic;
    const tool_description = requiredStringValue(tool_object, "description");
    if (try requiredObject(allocator, tool_object, "$.tool", "inputSchema")) |diagnostic| return diagnostic;
    if (try requiredObject(allocator, tool_object, "$.tool", "outputSchema")) |diagnostic| return diagnostic;

    inline for (unsupported_surface_fields) |field| {
        if (root.get(field) != null) {
            const path = try std.fmt.allocPrint(allocator, "$.{s}", .{field});
            defer allocator.free(path);
            return invalidOne(allocator, .validate, path, "unsupported v0 surface; only $.tool is supported");
        }
    }

    var capabilities = std.ArrayList(Capability).empty;
    defer capabilities.deinit(allocator);
    if (root.get("capabilities")) |capabilities_value| {
        if (capabilities_value != .array) {
            return invalidOne(allocator, .validate, "$.capabilities", "expected array");
        }
        for (capabilities_value.array.items, 0..) |item, index| {
            const path = try std.fmt.allocPrint(allocator, "$.capabilities[{d}]", .{index});
            defer allocator.free(path);
            if (item != .string) {
                return invalidOne(allocator, .validate, path, "expected string");
            }
            const capability = parseCapability(item.string) orelse {
                const message = try std.fmt.allocPrint(allocator, "unknown capability \"{s}\"", .{item.string});
                defer allocator.free(message);
                return invalidOne(allocator, .validate, path, message);
            };
            const denial = denyRuntimeCapability(capability, .validate, "manifest-request");
            return invalidCapabilityDenial(allocator, path, denial);
        }
    }

    const artifact_absolute_path = switch (try validateArtifactPath(allocator, package_root, artifact_path)) {
        .valid => |path| path,
        .invalid => |diagnostic| return diagnostic,
    };
    errdefer allocator.free(artifact_absolute_path);

    const owned_schema_version = try allocator.dupe(u8, schema_version);
    errdefer allocator.free(owned_schema_version);
    const owned_extension_id = try allocator.dupe(u8, extension_id);
    errdefer allocator.free(owned_extension_id);
    const owned_extension_name = try allocator.dupe(u8, extension_name);
    errdefer allocator.free(owned_extension_name);
    const owned_extension_version = try allocator.dupe(u8, extension_version);
    errdefer allocator.free(owned_extension_version);
    const owned_extension_description = try allocator.dupe(u8, extension_description);
    errdefer allocator.free(owned_extension_description);
    const owned_artifact_path = try allocator.dupe(u8, artifact_path);
    errdefer allocator.free(owned_artifact_path);
    const owned_tool_id = try allocator.dupe(u8, tool_id);
    errdefer allocator.free(owned_tool_id);
    const owned_tool_description = try allocator.dupe(u8, tool_description);
    errdefer allocator.free(owned_tool_description);
    const owned_capabilities = try capabilities.toOwnedSlice(allocator);
    errdefer allocator.free(owned_capabilities);

    return .{
        .valid = .{
            .schema_version = owned_schema_version,
            .id = owned_extension_id,
            .name = owned_extension_name,
            .version = owned_extension_version,
            .description = owned_extension_description,
            .artifact_kind = artifact_kind,
            .artifact_path = owned_artifact_path,
            .artifact_absolute_path = artifact_absolute_path,
            .tool_id = owned_tool_id,
            .tool_description = owned_tool_description,
            .requested_capabilities = owned_capabilities,
        },
    };
}

pub fn validateManifestFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_root: []const u8,
) !ValidationResult {
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .limited(256 * 1024)) catch {
        const diagnostics = try allocator.alloc(Diagnostic, 1);
        diagnostics[0] = .{
            .phase = .discover,
            .path = try allocator.dupe(u8, "$"),
            .message = try allocator.dupe(u8, "discover: pi-extension.json was not found"),
        };
        return .{ .invalid = diagnostics };
    };
    defer allocator.free(bytes);
    return validateManifestText(allocator, package_root, bytes);
}

const unsupported_surface_fields = [_][]const u8{
    "commands",
    "widgets",
    "providers",
    "editorHooks",
    "extensions",
    "shortcuts",
    "themes",
    "prompts",
    "skills",
};

fn invalidOne(
    allocator: std.mem.Allocator,
    phase: LifecyclePhase,
    path: []const u8,
    message: []const u8,
) !ValidationResult {
    const diagnostics = try allocator.alloc(Diagnostic, 1);
    errdefer allocator.free(diagnostics);
    diagnostics[0] = .{
        .phase = phase,
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
    };
    return .{ .invalid = diagnostics };
}

fn invalidCapabilityDenial(
    allocator: std.mem.Allocator,
    path: []const u8,
    denial: CapabilityDenialDiagnostic,
) !ValidationResult {
    const message = try std.fmt.allocPrint(
        allocator,
        "{s}: capability \"{s}\" is not approved for {s}",
        .{ denial.category, denial.capability.jsonName(), denial.mode },
    );
    defer allocator.free(message);
    const diagnostics = try allocator.alloc(Diagnostic, 1);
    errdefer allocator.free(diagnostics);
    diagnostics[0] = .{
        .category = denial.category,
        .phase = denial.phase,
        .path = try allocator.dupe(u8, path),
        .capability = denial.capability,
        .message = try allocator.dupe(u8, message),
    };
    return .{ .invalid = diagnostics };
}

fn requiredString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    parent_path: []const u8,
    field: []const u8,
) !?ValidationResult {
    const value = object.get(field) orelse {
        const path = try joinJsonPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, .validate, path, "missing required field");
    };
    if (value != .string) {
        const path = try joinJsonPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, .validate, path, "expected string");
    }
    return null;
}

fn requiredObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    parent_path: []const u8,
    field: []const u8,
) !?ValidationResult {
    const value = object.get(field) orelse {
        const path = try joinJsonPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, .validate, path, "missing required field");
    };
    if (value != .object) {
        const path = try joinJsonPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, .validate, path, "expected object");
    }
    return null;
}

fn requiredStringValue(
    object: std.json.ObjectMap,
    field: []const u8,
) []const u8 {
    return object.get(field).?.string;
}

fn requiredObjectValue(
    object: std.json.ObjectMap,
    field: []const u8,
) std.json.ObjectMap {
    return object.get(field).?.object;
}

fn joinJsonPath(allocator: std.mem.Allocator, parent_path: []const u8, field: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
}

fn parseArtifactKind(value: []const u8) ?ArtifactKind {
    if (std.mem.eql(u8, value, ArtifactKind.wasm_component.jsonName())) return .wasm_component;
    return null;
}

fn parseCapability(value: []const u8) ?Capability {
    inline for (@typeInfo(Capability).@"enum".fields) |field| {
        const capability: Capability = @enumFromInt(field.value);
        if (std.mem.eql(u8, value, capability.jsonName())) return capability;
    }
    return null;
}

const ArtifactPathValidation = union(enum) {
    valid: []u8,
    invalid: ValidationResult,
};

fn validateArtifactPath(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    artifact_path: []const u8,
) !ArtifactPathValidation {
    if (artifact_path.len == 0) {
        return .{ .invalid = try invalidOne(allocator, .validate, "$.artifact.path", "artifact path must not be empty") };
    }
    if (std.fs.path.isAbsolute(artifact_path)) {
        return .{ .invalid = try invalidOne(allocator, .validate, "$.artifact.path", "artifact path must be package-relative") };
    }
    if (std.mem.indexOf(u8, artifact_path, "\\") != null) {
        return .{ .invalid = try invalidOne(allocator, .validate, "$.artifact.path", "artifact path must use '/' separators") };
    }
    if (!std.mem.endsWith(u8, artifact_path, ".wasm")) {
        return .{ .invalid = try invalidOne(allocator, .validate, "$.artifact.path", "artifact path must point to a .wasm file") };
    }

    var component_iterator = std.mem.splitScalar(u8, artifact_path, '/');
    while (component_iterator.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".")) {
            return .{ .invalid = try invalidOne(allocator, .validate, "$.artifact.path", "artifact path must be normalized") };
        }
        if (std.mem.eql(u8, component, "..")) {
            return .{ .invalid = try invalidOne(allocator, .validate, "$.artifact.path", "artifact path escapes package root") };
        }
    }

    const root_real = realpathAlloc(allocator, package_root) catch {
        return .{ .invalid = try invalidOne(allocator, .validate, "$", "package root was not found") };
    };
    defer allocator.free(root_real);

    const candidate_path = try std.fs.path.resolve(allocator, &.{ root_real, artifact_path });
    defer allocator.free(candidate_path);

    if (!pathWithin(root_real, candidate_path)) {
        return .{ .invalid = try invalidOne(allocator, .validate, "$.artifact.path", "artifact path escapes package root") };
    }

    const candidate_real = realpathAlloc(allocator, candidate_path) catch {
        return .{ .invalid = try invalidOne(allocator, .validate, "$.artifact.path", "artifact file was not found") };
    };
    errdefer allocator.free(candidate_real);

    if (!pathWithin(root_real, candidate_real)) {
        allocator.free(candidate_real);
        return .{ .invalid = try invalidOne(allocator, .validate, "$.artifact.path", "artifact path resolves outside package root") };
    }

    return .{ .valid = candidate_real };
}

fn pathWithin(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len <= root.len) return false;
    return candidate[root.len] == std.fs.path.sep;
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(z_path.ptr, &buffer) orelse return error.FileNotFound;
    return allocator.dupe(u8, std.mem.span(resolved));
}

const VALID_MANIFEST =
    \\{
    \\  "schemaVersion": "pi-extension.v0",
    \\  "id": "com.example.valid",
    \\  "name": "Valid Example",
    \\  "version": "0.1.0",
    \\  "description": "A valid one-tool Wasm extension.",
    \\  "artifact": {
    \\    "kind": "wasm-component",
    \\    "path": "wasm/example-tool.wasm"
    \\  },
    \\  "tool": {
    \\    "id": "example.tool",
    \\    "description": "Runs an example operation.",
    \\    "inputSchema": {},
    \\    "outputSchema": {}
    \\  },
    \\  "capabilities": []
    \\}
;

fn makeAbsoluteTestPath(
    allocator: std.mem.Allocator,
    tmp: anytype,
    relative_path: []const u8,
) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        relative_path,
    });
}

fn makeValidPackage(allocator: std.mem.Allocator, tmp: anytype) ![]u8 {
    try tmp.dir.createDir(std.testing.io, "package", .default_dir);
    try tmp.dir.createDir(std.testing.io, "package/wasm", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "package/wasm/example-tool.wasm", .data = "\x00asm" });
    return makeAbsoluteTestPath(allocator, tmp, "package");
}

fn expectInvalid(result: *ValidationResult, expected_path: []const u8, expected_message: []const u8) !void {
    try std.testing.expect(result.* == .invalid);
    const diagnostics = result.invalid;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings(expected_path, diagnostics[0].path);
    try std.testing.expectEqualStrings(expected_message, diagnostics[0].message);
}

fn expectDeniedCapability(
    result: *ValidationResult,
    expected_path: []const u8,
    expected_capability: Capability,
    expected_phase: LifecyclePhase,
) !void {
    try std.testing.expect(result.* == .invalid);
    const diagnostics = result.invalid;
    try std.testing.expectEqual(@as(usize, 1), diagnostics.len);
    try std.testing.expectEqualStrings("denied_capability", diagnostics[0].category);
    try std.testing.expectEqual(expected_phase, diagnostics[0].phase);
    try std.testing.expectEqualStrings(expected_path, diagnostics[0].path);
    try std.testing.expectEqual(expected_capability, diagnostics[0].capability.?);
    try std.testing.expect(std.mem.indexOf(u8, diagnostics[0].message, expected_capability.jsonName()) != null);
}

test "wasm manifest valid one-tool pi-extension validates successfully" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    var result = try validateManifestText(allocator, package_root, VALID_MANIFEST);
    defer result.deinit(allocator);

    try std.testing.expect(result == .valid);
    try std.testing.expectEqualStrings("com.example.valid", result.valid.id);
    try std.testing.expectEqualStrings("example.tool", result.valid.tool_id);
    try std.testing.expectEqual(@as(usize, 0), result.valid.requested_capabilities.len);
    try std.testing.expect(std.fs.path.isAbsolute(result.valid.artifact_absolute_path));
}

test "wasm manifest missing required fields produce deterministic diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    var missing_top = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","name":"Missing","version":"0.1.0","description":"Missing id","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer missing_top.deinit(allocator);
    try expectInvalid(&missing_top, "$.id", "missing required field");

    var missing_tool = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Missing tool field","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer missing_tool.deinit(allocator);
    try expectInvalid(&missing_tool, "$.tool.description", "missing required field");
}

test "wasm manifest malformed JSON and wrong types produce deterministic diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    var malformed = try validateManifestText(allocator, package_root, "{");
    defer malformed.deinit(allocator);
    try expectInvalid(&malformed, "$", "malformed JSON");

    var wrong_type = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":42,"name":"Example","version":"0.1.0","description":"Wrong type","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer wrong_type.deinit(allocator);
    try expectInvalid(&wrong_type, "$.id", "expected string");
}

test "wasm manifest omitted capabilities are default-deny and unknown capabilities fail" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    var omitted = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"No capabilities","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}}}
    );
    defer omitted.deinit(allocator);
    try std.testing.expect(omitted == .valid);
    try std.testing.expectEqual(@as(usize, 0), omitted.valid.requested_capabilities.len);

    var unknown = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Unknown cap","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":["database"]}
    );
    defer unknown.deinit(allocator);
    try expectInvalid(&unknown, "$.capabilities[0]", "unknown capability \"database\"");
}

test "wasm manifest denies requested capabilities before artifact validation" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "package", .default_dir);
    const package_root = try makeAbsoluteTestPath(allocator, tmp, "package");
    defer allocator.free(package_root);

    for (CANONICAL_CAPABILITIES) |capability| {
        const manifest_text = try std.fmt.allocPrint(allocator,
            \\{{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Requested capability","artifact":{{"kind":"wasm-component","path":"wasm/missing.wasm"}},"tool":{{"id":"example.tool","description":"Tool","inputSchema":{{}},"outputSchema":{{}}}},"capabilities":["{s}"]}}
        , .{capability.jsonName()});
        defer allocator.free(manifest_text);

        var result = try validateManifestText(allocator, package_root, manifest_text);
        defer result.deinit(allocator);
        try expectDeniedCapability(&result, "$.capabilities[0]", capability, .validate);
        try std.testing.expect(std.mem.indexOf(u8, result.invalid[0].message, "artifact file was not found") == null);
    }
}

test "wasm manifest rejects zero multiple and non-tool declarations" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    var zero_tools = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"No tool","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"capabilities":[]}
    );
    defer zero_tools.deinit(allocator);
    try expectInvalid(&zero_tools, "$.tool", "missing required field");

    var multi_tools = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Multiple tools","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tools":[{"id":"one"},{"id":"two"}],"capabilities":[]}
    );
    defer multi_tools.deinit(allocator);
    try expectInvalid(&multi_tools, "$.tools", "v0 manifests must declare exactly one tool in $.tool");

    var command_surface = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Command surface","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"commands":[]}
    );
    defer command_surface.deinit(allocator);
    try expectInvalid(&command_surface, "$.commands", "unsupported v0 surface; only $.tool is supported");
}

test "wasm manifest validates artifact kind and constrained paths before load success" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    var wrong_kind = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Wrong kind","artifact":{"kind":"native-library","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer wrong_kind.deinit(allocator);
    try expectInvalid(&wrong_kind, "$.artifact.kind", "unsupported artifact kind \"native-library\"; expected wasm-component");

    var absolute_path = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Absolute path","artifact":{"kind":"wasm-component","path":"/tmp/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer absolute_path.deinit(allocator);
    try expectInvalid(&absolute_path, "$.artifact.path", "artifact path must be package-relative");

    var escaping_path = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Escaping path","artifact":{"kind":"wasm-component","path":"../outside.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer escaping_path.deinit(allocator);
    try expectInvalid(&escaping_path, "$.artifact.path", "artifact path escapes package root");

    var missing_artifact = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Missing artifact","artifact":{"kind":"wasm-component","path":"wasm/missing.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer missing_artifact.deinit(allocator);
    try expectInvalid(&missing_artifact, "$.artifact.path", "artifact file was not found");
}

test "wasm manifest rejects symlink-resolved artifact escapes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "outside.wasm", .data = "\x00asm" });
    const outside_path = try makeAbsoluteTestPath(allocator, tmp, "outside.wasm");
    defer allocator.free(outside_path);
    const symlink_path = try makeAbsoluteTestPath(allocator, tmp, "package/wasm/escape.wasm");
    defer allocator.free(symlink_path);
    try std.Io.Dir.symLinkAbsolute(std.testing.io, outside_path, symlink_path, .{});

    var result = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Symlink escape","artifact":{"kind":"wasm-component","path":"wasm/escape.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer result.deinit(allocator);
    try expectInvalid(&result, "$.artifact.path", "artifact path resolves outside package root");
}

test "pi-extension lifecycle failures are user-visible diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeAbsoluteTestPath(allocator, tmp, "");
    defer allocator.free(package_root);

    var result = try validateManifestFile(allocator, std.testing.io, package_root);
    defer result.deinit(allocator);

    try std.testing.expect(result == .invalid);
    try std.testing.expectEqual(.discover, result.invalid[0].phase);
    try std.testing.expectEqualStrings("$", result.invalid[0].path);
    try std.testing.expectEqualStrings("discover: pi-extension.json was not found", result.invalid[0].message);
}

test "pi-extension manifest rejects unsupported schema versions deterministically" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    var result = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v1","id":"com.example","name":"Example","version":"0.1.0","description":"Unsupported schema","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[]}
    );
    defer result.deinit(allocator);
    try expectInvalid(&result, "$.schemaVersion", "unsupported schema version \"pi-extension.v1\"; expected pi-extension.v0");
}

test "wasm capability canonical ids map to explicit enforcement branches" {
    const expected = [_]struct {
        capability: Capability,
        id: []const u8,
        branch: CapabilityEnforcementBranch,
    }{
        .{ .capability = .file_read, .id = "file.read", .branch = .filesystem_read },
        .{ .capability = .file_write, .id = "file.write", .branch = .filesystem_write },
        .{ .capability = .network, .id = "network", .branch = .network_request },
        .{ .capability = .shell, .id = "shell", .branch = .shell_process },
        .{ .capability = .env, .id = "env", .branch = .environment_variable },
        .{ .capability = .model, .id = "model", .branch = .model_call },
        .{ .capability = .session, .id = "session", .branch = .session_state },
        .{ .capability = .ui_notify, .id = "ui.notify", .branch = .ui_notification },
    };

    try std.testing.expectEqual(CANONICAL_CAPABILITIES.len, expected.len);
    try std.testing.expectEqual(@typeInfo(Capability).@"enum".fields.len, expected.len);
    for (expected) |entry| {
        try std.testing.expectEqualStrings(entry.id, entry.capability.jsonName());
        try std.testing.expectEqual(entry.capability, parseCapability(entry.id).?);
        try std.testing.expectEqual(entry.branch, entry.capability.enforcementBranch());
    }
    try std.testing.expectEqual(@as(?Capability, null), parseCapability("filesystem"));
}

test "wasm capability requested but unapproved declarations are denied deterministically" {
    for (CANONICAL_CAPABILITIES) |capability| {
        const diagnostic = denyFirstUnapprovedCapability(&.{capability}, &.{}, .initialize, "manifest-request").?;
        try std.testing.expectEqualStrings("denied_capability", diagnostic.category);
        try std.testing.expectEqual(capability, diagnostic.capability);
        try std.testing.expectEqual(capability.enforcementBranch(), diagnostic.branch);
        try std.testing.expectEqual(.initialize, diagnostic.phase);
        try std.testing.expectEqualStrings("manifest-request", diagnostic.mode);
    }

    try std.testing.expectEqual(
        @as(?CapabilityDenialDiagnostic, null),
        denyFirstUnapprovedCapability(&.{ .shell, .network }, &.{ .shell, .network }, .initialize, "manifest-request"),
    );
    try std.testing.expectEqual(
        Capability.shell,
        denyFirstUnapprovedCapability(&.{.shell}, &.{.network}, .initialize, "manifest-request").?.capability,
    );
}

test "wasm capability runtime denials use same ids and category as manifest requests" {
    for (CANONICAL_CAPABILITIES) |capability| {
        const diagnostic = denyRuntimeCapability(capability, .call, "runtime/import");
        try std.testing.expectEqualStrings("denied_capability", diagnostic.category);
        try std.testing.expectEqualStrings(capability.jsonName(), diagnostic.capability.jsonName());
        try std.testing.expectEqual(capability.enforcementBranch(), diagnostic.branch);
        try std.testing.expectEqual(.call, diagnostic.phase);
        try std.testing.expectEqualStrings("runtime/import", diagnostic.mode);
    }
}

test "wasm capability runtime import mappings share canonical denial vocabulary" {
    const expected = [_]struct {
        module_name: []const u8,
        field_name: []const u8,
        capability: Capability,
    }{
        .{ .module_name = "pi:filesystem", .field_name = "read", .capability = .file_read },
        .{ .module_name = "pi:filesystem", .field_name = "write", .capability = .file_write },
        .{ .module_name = "pi:network", .field_name = "fetch", .capability = .network },
        .{ .module_name = "pi:shell", .field_name = "run", .capability = .shell },
        .{ .module_name = "pi:environment", .field_name = "get", .capability = .env },
        .{ .module_name = "pi:model", .field_name = "call", .capability = .model },
        .{ .module_name = "pi:session", .field_name = "get", .capability = .session },
        .{ .module_name = "pi:ui", .field_name = "notify", .capability = .ui_notify },
    };

    for (expected) |entry| {
        const diagnostic = denyRuntimeImport(entry.module_name, entry.field_name, .load, "runtime/import").?;
        try std.testing.expectEqualStrings("denied_capability", diagnostic.category);
        try std.testing.expectEqual(entry.capability, diagnostic.capability);
        try std.testing.expectEqualStrings(entry.capability.jsonName(), diagnostic.capabilityId());
        try std.testing.expectEqual(entry.capability.enforcementBranch(), diagnostic.branch);
        try std.testing.expectEqual(.load, diagnostic.phase);
        try std.testing.expectEqualStrings("runtime/import", diagnostic.mode);
    }
    try std.testing.expectEqual(@as(?CapabilityDenialDiagnostic, null), denyRuntimeImport("pi:unknown", "call", .load, "runtime/import"));
}
