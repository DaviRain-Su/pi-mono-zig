const std = @import("std");

pub const MANIFEST_FILE_NAME = "pi-extension.json";
pub const SCHEMA_VERSION = "pi-extension.v0";
const MAX_SAFE_INTEGER: u64 = 9007199254740991;

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
    network_request,
    shell_run,
    env_read,
    model_call,
    session_read,
    session_write,
    ui_notify,
    tool_use,
    agent_spawn,
    agent_delegate,

    pub fn jsonName(self: Capability) []const u8 {
        return switch (self) {
            .file_read => "file.read",
            .file_write => "file.write",
            .network_request => "network.request",
            .shell_run => "shell.run",
            .env_read => "env.read",
            .model_call => "model.call",
            .session_read => "session.read",
            .session_write => "session.write",
            .ui_notify => "ui.notify",
            .tool_use => "tool.use",
            .agent_spawn => "agent.spawn",
            .agent_delegate => "agent.delegate",
        };
    }

    pub fn enforcementBranch(self: Capability) CapabilityEnforcementBranch {
        return switch (self) {
            .file_read => .filesystem_read,
            .file_write => .filesystem_write,
            .network_request => .network_request,
            .shell_run => .shell_process,
            .env_read => .environment_variable,
            .model_call => .model_call,
            .session_read => .session_read,
            .session_write => .session_write,
            .ui_notify => .ui_notification,
            .tool_use => .tool_execution,
            .agent_spawn => .agent_spawn,
            .agent_delegate => .agent_delegate,
        };
    }
};

pub const CANONICAL_CAPABILITIES = [_]Capability{
    .file_read,
    .file_write,
    .network_request,
    .shell_run,
    .env_read,
    .model_call,
    .session_read,
    .session_write,
    .ui_notify,
    .tool_use,
    .agent_spawn,
    .agent_delegate,
};

pub const CapabilityEnforcementBranch = enum {
    filesystem_read,
    filesystem_write,
    network_request,
    shell_process,
    environment_variable,
    model_call,
    session_read,
    session_write,
    ui_notification,
    tool_execution,
    agent_spawn,
    agent_delegate,

    pub fn jsonName(self: CapabilityEnforcementBranch) []const u8 {
        return switch (self) {
            .filesystem_read => "filesystem.read",
            .filesystem_write => "filesystem.write",
            .network_request => "network.request",
            .shell_process => "shell.process",
            .environment_variable => "environment.variable",
            .model_call => "model.call",
            .session_read => "session.read",
            .session_write => "session.write",
            .ui_notification => "ui.notification",
            .tool_execution => "tool.execution",
            .agent_spawn => "agent.spawn",
            .agent_delegate => "agent.delegate",
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
    if (std.mem.eql(u8, module_name, "pi:network") and std.mem.eql(u8, field_name, "fetch")) return .network_request;
    if (std.mem.eql(u8, module_name, "pi:shell") and std.mem.eql(u8, field_name, "run")) return .shell_run;
    if (std.mem.eql(u8, module_name, "pi:environment") and std.mem.eql(u8, field_name, "get")) return .env_read;
    if (std.mem.eql(u8, module_name, "pi:model") and std.mem.eql(u8, field_name, "call")) return .model_call;
    if (std.mem.eql(u8, module_name, "pi:session") and std.mem.eql(u8, field_name, "get")) return .session_read;
    if (std.mem.eql(u8, module_name, "pi:session") and std.mem.eql(u8, field_name, "set")) return .session_write;
    if (std.mem.eql(u8, module_name, "pi:ui") and std.mem.eql(u8, field_name, "notify")) return .ui_notify;
    if (std.mem.eql(u8, module_name, "pi:tool") and std.mem.eql(u8, field_name, "use")) return .tool_use;
    if (std.mem.eql(u8, module_name, "pi:agent") and std.mem.eql(u8, field_name, "spawn")) return .agent_spawn;
    if (std.mem.eql(u8, module_name, "pi:agent") and std.mem.eql(u8, field_name, "delegate")) return .agent_delegate;
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
    operation: ?Capability = null,
    branch: ?CapabilityEnforcementBranch = null,
    mode: ?[]u8 = null,
    reason: ?[]u8 = null,
    principal: ?DiagnosticPrincipal = null,
    source: ?DiagnosticSource = null,
    message: []u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.mode) |mode| allocator.free(mode);
        if (self.reason) |reason| allocator.free(reason);
        if (self.principal) |*principal| principal.deinit(allocator);
        if (self.source) |*source| source.deinit(allocator);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const DiagnosticPrincipal = struct {
    runtime_kind: []u8,
    extension_id: []u8,
    policy_lookup_key: []u8,
    tool_id: []u8,

    fn deinit(self: *DiagnosticPrincipal, allocator: std.mem.Allocator) void {
        allocator.free(self.runtime_kind);
        allocator.free(self.extension_id);
        allocator.free(self.policy_lookup_key);
        allocator.free(self.tool_id);
        self.* = undefined;
    }
};

pub const DiagnosticSource = struct {
    manifest_path: []u8,
    package_root: []u8,
    artifact_path: []u8,

    fn deinit(self: *DiagnosticSource, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_path);
        allocator.free(self.package_root);
        allocator.free(self.artifact_path);
        self.* = undefined;
    }
};

pub const ResourceLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: [][]u8,

    pub fn initEmpty(allocator: std.mem.Allocator) !ResourceLimits {
        return .{ .tool_scopes = try allocator.alloc([]u8, 0) };
    }

    pub fn deinit(self: *ResourceLimits, allocator: std.mem.Allocator) void {
        for (self.tool_scopes) |scope| allocator.free(scope);
        allocator.free(self.tool_scopes);
        self.* = undefined;
    }
};

pub const Manifest = struct {
    package_root: []u8,
    manifest_path: []u8,
    schema_version: []u8,
    id: []u8,
    name: []u8,
    version: []u8,
    description: []u8,
    artifact_kind: ArtifactKind,
    artifact_path: []u8,
    artifact_absolute_path: []u8,
    artifact_sha256: []u8,
    tool_id: []u8,
    tool_description: []u8,
    input_schema_json: []u8,
    output_schema_json: []u8,
    requested_capabilities: []Capability,
    resource_limits: ResourceLimits,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.package_root);
        allocator.free(self.manifest_path);
        allocator.free(self.schema_version);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.artifact_path);
        allocator.free(self.artifact_absolute_path);
        allocator.free(self.artifact_sha256);
        allocator.free(self.tool_id);
        allocator.free(self.tool_description);
        allocator.free(self.input_schema_json);
        allocator.free(self.output_schema_json);
        allocator.free(self.requested_capabilities);
        self.resource_limits.deinit(allocator);
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

pub const ValidationOptions = struct {
    approved_capabilities: []const Capability = &.{},
};

const ManifestBuildFields = struct {
    package_root: []const u8,
    schema_version: []const u8,
    extension_id: []const u8,
    extension_name: []const u8,
    extension_version: []const u8,
    extension_description: []const u8,
    artifact_kind: ArtifactKind,
    artifact_path: []const u8,
    artifact_absolute_path: []u8,
    tool_id: []const u8,
    tool_description: []const u8,
    input_schema: std.json.ObjectMap,
    output_schema: std.json.ObjectMap,
    capabilities: *std.ArrayList(Capability),
    resource_limits: ResourceLimits,
};

pub fn validateManifestText(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    manifest_text: []const u8,
) !ValidationResult {
    return validateManifestTextWithOptions(allocator, package_root, manifest_text, .{});
}

pub fn validateManifestTextWithOptions(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    manifest_text: []const u8,
    options: ValidationOptions,
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
    const input_schema = requiredObjectValue(tool_object, "inputSchema");
    if (try requiredObject(allocator, tool_object, "$.tool", "outputSchema")) |diagnostic| return diagnostic;
    const output_schema = requiredObjectValue(tool_object, "outputSchema");

    const diagnostic_manifest_path = try std.fs.path.join(allocator, &.{ package_root, MANIFEST_FILE_NAME });
    defer allocator.free(diagnostic_manifest_path);
    const diagnostic_policy_lookup_key = try manifestPolicyLookupKey(
        allocator,
        schema_version,
        extension_id,
        extension_version,
        package_root,
        diagnostic_manifest_path,
        artifact_path,
    );
    defer allocator.free(diagnostic_policy_lookup_key);
    const capability_context = CapabilityDenialContext{
        .extension_id = extension_id,
        .policy_lookup_key = diagnostic_policy_lookup_key,
        .tool_id = tool_id,
        .manifest_path = diagnostic_manifest_path,
        .package_root = package_root,
        .artifact_path = artifact_path,
    };

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
            if (denyFirstUnapprovedCapability(&.{capability}, options.approved_capabilities, .validate, "manifest-request")) |denial| {
                return invalidCapabilityDenial(allocator, path, denial, capability_context);
            }
            try capabilities.append(allocator, capability);
        }
    }

    var resource_limits = switch (try validateResourceLimits(allocator, root)) {
        .valid => |limits| limits,
        .invalid => |diagnostic| return diagnostic,
    };
    errdefer resource_limits.deinit(allocator);

    const artifact_absolute_path = switch (try validateArtifactPath(allocator, package_root, artifact_path)) {
        .valid => |path| path,
        .invalid => |diagnostic| return diagnostic,
    };
    errdefer allocator.free(artifact_absolute_path);

    return buildValidManifestResult(allocator, .{
        .package_root = package_root,
        .schema_version = schema_version,
        .extension_id = extension_id,
        .extension_name = extension_name,
        .extension_version = extension_version,
        .extension_description = extension_description,
        .artifact_kind = artifact_kind,
        .artifact_path = artifact_path,
        .artifact_absolute_path = artifact_absolute_path,
        .tool_id = tool_id,
        .tool_description = tool_description,
        .input_schema = input_schema,
        .output_schema = output_schema,
        .capabilities = &capabilities,
        .resource_limits = resource_limits,
    });
}

fn buildValidManifestResult(
    allocator: std.mem.Allocator,
    fields: ManifestBuildFields,
) !ValidationResult {
    const owned_package_root = try realpathAlloc(allocator, fields.package_root);
    errdefer allocator.free(owned_package_root);
    const owned_manifest_path = try std.fs.path.join(allocator, &.{ fields.package_root, MANIFEST_FILE_NAME });
    errdefer allocator.free(owned_manifest_path);
    const owned_artifact_sha256 = try allocator.dupe(u8, "");
    errdefer allocator.free(owned_artifact_sha256);
    const owned_schema_version = try allocator.dupe(u8, fields.schema_version);
    errdefer allocator.free(owned_schema_version);
    const owned_extension_id = try allocator.dupe(u8, fields.extension_id);
    errdefer allocator.free(owned_extension_id);
    const owned_extension_name = try allocator.dupe(u8, fields.extension_name);
    errdefer allocator.free(owned_extension_name);
    const owned_extension_version = try allocator.dupe(u8, fields.extension_version);
    errdefer allocator.free(owned_extension_version);
    const owned_extension_description = try allocator.dupe(u8, fields.extension_description);
    errdefer allocator.free(owned_extension_description);
    const owned_artifact_path = try allocator.dupe(u8, fields.artifact_path);
    errdefer allocator.free(owned_artifact_path);
    const owned_tool_id = try allocator.dupe(u8, fields.tool_id);
    errdefer allocator.free(owned_tool_id);
    const owned_tool_description = try allocator.dupe(u8, fields.tool_description);
    errdefer allocator.free(owned_tool_description);
    const owned_input_schema_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = fields.input_schema }, .{});
    errdefer allocator.free(owned_input_schema_json);
    const owned_output_schema_json = try std.json.Stringify.valueAlloc(allocator, std.json.Value{ .object = fields.output_schema }, .{});
    errdefer allocator.free(owned_output_schema_json);
    const owned_capabilities = try fields.capabilities.toOwnedSlice(allocator);
    errdefer allocator.free(owned_capabilities);

    return .{
        .valid = .{
            .package_root = owned_package_root,
            .manifest_path = owned_manifest_path,
            .schema_version = owned_schema_version,
            .id = owned_extension_id,
            .name = owned_extension_name,
            .version = owned_extension_version,
            .description = owned_extension_description,
            .artifact_kind = fields.artifact_kind,
            .artifact_path = owned_artifact_path,
            .artifact_absolute_path = fields.artifact_absolute_path,
            .artifact_sha256 = owned_artifact_sha256,
            .tool_id = owned_tool_id,
            .tool_description = owned_tool_description,
            .input_schema_json = owned_input_schema_json,
            .output_schema_json = owned_output_schema_json,
            .requested_capabilities = owned_capabilities,
            .resource_limits = fields.resource_limits,
        },
    };
}

pub fn validateManifestFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_root: []const u8,
) !ValidationResult {
    return validateManifestFileWithOptions(allocator, io, package_root, .{});
}

pub fn validateManifestFileWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_root: []const u8,
    options: ValidationOptions,
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
    var result = try validateManifestTextWithOptions(allocator, package_root, bytes, options);
    errdefer result.deinit(allocator);
    if (result == .valid) {
        const artifact_bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, result.valid.artifact_absolute_path, allocator, .limited(64 * 1024 * 1024));
        defer allocator.free(artifact_bytes);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(artifact_bytes, &digest, .{});
        const artifact_sha256 = try bytesToHexAlloc(allocator, &digest);
        allocator.free(result.valid.artifact_sha256);
        result.valid.artifact_sha256 = artifact_sha256;
    }
    return result;
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
    context: CapabilityDenialContext,
) !ValidationResult {
    const message = try std.fmt.allocPrint(
        allocator,
        "{s}: capability \"{s}\" is not approved for {s}",
        .{ denial.category, denial.capability.jsonName(), denial.mode },
    );
    defer allocator.free(message);
    const diagnostics = try allocator.alloc(Diagnostic, 1);
    errdefer allocator.free(diagnostics);
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const owned_mode = try allocator.dupe(u8, denial.mode);
    errdefer allocator.free(owned_mode);
    const owned_reason = try allocator.dupe(u8, "grant is not approved");
    errdefer allocator.free(owned_reason);
    const owned_message = try allocator.dupe(u8, message);
    errdefer allocator.free(owned_message);
    var principal = try context.principal(allocator);
    errdefer principal.deinit(allocator);
    var source = try context.source(allocator);
    errdefer source.deinit(allocator);
    diagnostics[0] = .{
        .category = denial.category,
        .phase = denial.phase,
        .path = owned_path,
        .capability = denial.capability,
        .operation = denial.capability,
        .branch = denial.branch,
        .mode = owned_mode,
        .reason = owned_reason,
        .principal = principal,
        .source = source,
        .message = owned_message,
    };
    return .{ .invalid = diagnostics };
}

const CapabilityDenialContext = struct {
    extension_id: []const u8,
    policy_lookup_key: []const u8,
    tool_id: []const u8,
    manifest_path: []const u8,
    package_root: []const u8,
    artifact_path: []const u8,

    fn principal(self: CapabilityDenialContext, allocator: std.mem.Allocator) !DiagnosticPrincipal {
        const runtime_kind = try allocator.dupe(u8, "wasm");
        errdefer allocator.free(runtime_kind);
        const extension_id = try allocator.dupe(u8, self.extension_id);
        errdefer allocator.free(extension_id);
        const policy_lookup_key = try allocator.dupe(u8, self.policy_lookup_key);
        errdefer allocator.free(policy_lookup_key);
        const tool_id = try allocator.dupe(u8, self.tool_id);
        errdefer allocator.free(tool_id);
        return .{
            .runtime_kind = runtime_kind,
            .extension_id = extension_id,
            .policy_lookup_key = policy_lookup_key,
            .tool_id = tool_id,
        };
    }

    fn source(self: CapabilityDenialContext, allocator: std.mem.Allocator) !DiagnosticSource {
        const manifest_path = try allocator.dupe(u8, self.manifest_path);
        errdefer allocator.free(manifest_path);
        const package_root = try allocator.dupe(u8, self.package_root);
        errdefer allocator.free(package_root);
        const artifact_path = try allocator.dupe(u8, self.artifact_path);
        errdefer allocator.free(artifact_path);
        return .{
            .manifest_path = manifest_path,
            .package_root = package_root,
            .artifact_path = artifact_path,
        };
    }
};

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

fn manifestPolicyLookupKey(
    allocator: std.mem.Allocator,
    schema_version: []const u8,
    id: []const u8,
    version: []const u8,
    package_root: []const u8,
    manifest_path: []const u8,
    artifact_path: []const u8,
) ![]u8 {
    const normalized_package_root = try policyPathAlloc(allocator, package_root);
    defer allocator.free(normalized_package_root);
    const normalized_manifest_path = try policyPathAlloc(allocator, manifest_path);
    defer allocator.free(normalized_manifest_path);
    const normalized_artifact_path = try policyPathAlloc(allocator, artifact_path);
    defer allocator.free(normalized_artifact_path);
    return std.fmt.allocPrint(
        allocator,
        "wasm:manifest:{s}:{s}:{s}:{s}:{s}:{s}",
        .{ schema_version, id, version, normalized_package_root, normalized_manifest_path, normalized_artifact_path },
    );
}

fn policyPathAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, value);
    for (normalized) |*char| {
        if (char.* == '\\') char.* = '/';
    }
    return normalized;
}

fn parseArtifactKind(value: []const u8) ?ArtifactKind {
    if (std.mem.eql(u8, value, ArtifactKind.wasm_component.jsonName())) return .wasm_component;
    return null;
}

pub fn parseCapability(value: []const u8) ?Capability {
    inline for (@typeInfo(Capability).@"enum".fields) |field| {
        const capability: Capability = @enumFromInt(field.value);
        if (std.mem.eql(u8, value, capability.jsonName())) return capability;
    }
    return null;
}

const ResourceLimitsValidation = union(enum) {
    valid: ResourceLimits,
    invalid: ValidationResult,
};

const OptionalLimitValidation = union(enum) {
    valid: ?u64,
    invalid: ValidationResult,
};

const ToolScopesValidation = union(enum) {
    valid: [][]u8,
    invalid: ValidationResult,
};

fn validateResourceLimits(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
) !ResourceLimitsValidation {
    const value = root.get("resourceLimits") orelse return .{ .valid = try ResourceLimits.initEmpty(allocator) };
    if (value != .object) {
        return .{ .invalid = try invalidOne(allocator, .validate, "$.resourceLimits", "expected object") };
    }

    const limits = value.object;
    var iterator = limits.iterator();
    while (iterator.next()) |entry| {
        if (!isResourceLimitField(entry.key_ptr.*)) {
            const path = try std.fmt.allocPrint(allocator, "$.resourceLimits.{s}", .{entry.key_ptr.*});
            defer allocator.free(path);
            return .{ .invalid = try invalidOne(allocator, .validate, path, "unsupported resource limit") };
        }
    }

    const max_children = switch (try optionalResourceLimitInteger(allocator, limits, "maxChildren")) {
        .valid => |limit| limit,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    const depth = switch (try optionalResourceLimitInteger(allocator, limits, "depth")) {
        .valid => |limit| limit,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    const turns = switch (try optionalResourceLimitInteger(allocator, limits, "turns")) {
        .valid => |limit| limit,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    const timeout_ms = switch (try optionalResourceLimitInteger(allocator, limits, "timeoutMs")) {
        .valid => |limit| limit,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    const output_bytes = switch (try optionalResourceLimitInteger(allocator, limits, "outputBytes")) {
        .valid => |limit| limit,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    const output_lines = switch (try optionalResourceLimitInteger(allocator, limits, "outputLines")) {
        .valid => |limit| limit,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    const tool_scopes = switch (try readToolScopes(allocator, limits)) {
        .valid => |scopes| scopes,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };

    return .{ .valid = .{
        .max_children = max_children,
        .depth = depth,
        .turns = turns,
        .timeout_ms = timeout_ms,
        .output_bytes = output_bytes,
        .output_lines = output_lines,
        .tool_scopes = tool_scopes,
    } };
}

fn isResourceLimitField(field: []const u8) bool {
    return std.mem.eql(u8, field, "maxChildren") or
        std.mem.eql(u8, field, "depth") or
        std.mem.eql(u8, field, "turns") or
        std.mem.eql(u8, field, "timeoutMs") or
        std.mem.eql(u8, field, "outputBytes") or
        std.mem.eql(u8, field, "outputLines") or
        std.mem.eql(u8, field, "toolScopes");
}

fn optionalResourceLimitInteger(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field: []const u8,
) !OptionalLimitValidation {
    const value = object.get(field) orelse return .{ .valid = null };
    if (value != .integer or value.integer < 0 or @as(u64, @intCast(value.integer)) > MAX_SAFE_INTEGER) {
        const path = try std.fmt.allocPrint(allocator, "$.resourceLimits.{s}", .{field});
        defer allocator.free(path);
        return .{ .invalid = try invalidOne(allocator, .validate, path, "expected non-negative integer") };
    }
    return .{ .valid = @intCast(value.integer) };
}

fn readToolScopes(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
) !ToolScopesValidation {
    const value = object.get("toolScopes") orelse return .{ .valid = try allocator.alloc([]u8, 0) };
    if (value != .array) {
        return .{ .invalid = try invalidOne(allocator, .validate, "$.resourceLimits.toolScopes", "expected array") };
    }

    for (value.array.items, 0..) |item, index| {
        const path = try std.fmt.allocPrint(allocator, "$.resourceLimits.toolScopes[{d}]", .{index});
        defer allocator.free(path);
        if (item != .string) {
            return .{ .invalid = try invalidOne(allocator, .validate, path, "expected string") };
        }
        if (item.string.len == 0) {
            return .{ .invalid = try invalidOne(allocator, .validate, path, "must not be empty") };
        }
    }

    var scopes = std.ArrayList([]u8).empty;
    errdefer {
        for (scopes.items) |scope| allocator.free(scope);
        scopes.deinit(allocator);
    }
    for (value.array.items) |item| {
        try scopes.append(allocator, try allocator.dupe(u8, item.string));
    }
    return .{ .valid = try scopes.toOwnedSlice(allocator) };
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

fn bytesToHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        output[index * 2] = std.fmt.digitToChar(@intCast(byte >> 4), .lower);
        output[index * 2 + 1] = std.fmt.digitToChar(@intCast(byte & 0x0f), .lower);
    }
    return output;
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
    try std.testing.expectEqual(expected_capability, diagnostics[0].operation.?);
    try std.testing.expectEqual(expected_capability.enforcementBranch(), diagnostics[0].branch.?);
    try std.testing.expectEqualStrings("manifest-request", diagnostics[0].mode.?);
    try std.testing.expectEqualStrings("grant is not approved", diagnostics[0].reason.?);
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
    try std.testing.expectEqual(@as(usize, 0), result.valid.resource_limits.tool_scopes.len);
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

    const legacy_broad_grants = [_][]const u8{ "network", "shell", "env", "model", "session" };
    for (legacy_broad_grants) |grant| {
        const manifest_text = try std.fmt.allocPrint(allocator,
            \\{{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Legacy broad grant","artifact":{{"kind":"wasm-component","path":"wasm/example-tool.wasm"}},"tool":{{"id":"example.tool","description":"Tool","inputSchema":{{}},"outputSchema":{{}}}},"capabilities":["{s}"]}}
        , .{grant});
        defer allocator.free(manifest_text);

        var result = try validateManifestText(allocator, package_root, manifest_text);
        defer result.deinit(allocator);
        const expected = try std.fmt.allocPrint(allocator, "unknown capability \"{s}\"", .{grant});
        defer allocator.free(expected);
        try expectInvalid(&result, "$.capabilities[0]", expected);
    }
}

test "wasm manifest resource limits constrain without granting capabilities" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    var constrained = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Resource limits","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[],"resourceLimits":{"maxChildren":0,"depth":1,"turns":3,"timeoutMs":1000,"outputBytes":4096,"outputLines":80,"toolScopes":["example.tool","builtin.truncateHead"]}}
    );
    defer constrained.deinit(allocator);

    try std.testing.expect(constrained == .valid);
    try std.testing.expectEqual(@as(usize, 0), constrained.valid.requested_capabilities.len);
    try std.testing.expectEqual(@as(u64, 0), constrained.valid.resource_limits.max_children.?);
    try std.testing.expectEqual(@as(u64, 1), constrained.valid.resource_limits.depth.?);
    try std.testing.expectEqual(@as(u64, 3), constrained.valid.resource_limits.turns.?);
    try std.testing.expectEqual(@as(u64, 1000), constrained.valid.resource_limits.timeout_ms.?);
    try std.testing.expectEqual(@as(u64, 4096), constrained.valid.resource_limits.output_bytes.?);
    try std.testing.expectEqual(@as(u64, 80), constrained.valid.resource_limits.output_lines.?);
    try std.testing.expectEqual(@as(usize, 2), constrained.valid.resource_limits.tool_scopes.len);
    try std.testing.expectEqualStrings("example.tool", constrained.valid.resource_limits.tool_scopes[0]);
    try std.testing.expectEqualStrings("builtin.truncateHead", constrained.valid.resource_limits.tool_scopes[1]);

    var denied_with_limits = try validateManifestText(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Requested capability with limits","artifact":{"kind":"wasm-component","path":"wasm/missing.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":["file.read"],"resourceLimits":{"timeoutMs":1000,"toolScopes":["example.tool"]}}
    );
    defer denied_with_limits.deinit(allocator);
    try expectDeniedCapability(&denied_with_limits, "$.capabilities[0]", .file_read, .validate);
    try std.testing.expect(std.mem.indexOf(u8, denied_with_limits.invalid[0].message, "artifact file was not found") == null);
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const expected_policy_key = try manifestPolicyLookupKey(
        allocator,
        SCHEMA_VERSION,
        "com.example",
        "0.1.0",
        package_root,
        manifest_path,
        "wasm/missing.wasm",
    );
    defer allocator.free(expected_policy_key);
    try std.testing.expect(denied_with_limits.invalid[0].principal != null);
    try std.testing.expect(denied_with_limits.invalid[0].source != null);
    try std.testing.expectEqualStrings("wasm", denied_with_limits.invalid[0].principal.?.runtime_kind);
    try std.testing.expectEqualStrings("com.example", denied_with_limits.invalid[0].principal.?.extension_id);
    try std.testing.expectEqualStrings(expected_policy_key, denied_with_limits.invalid[0].principal.?.policy_lookup_key);
    try std.testing.expectEqualStrings("example.tool", denied_with_limits.invalid[0].principal.?.tool_id);
    try std.testing.expectEqualStrings(manifest_path, denied_with_limits.invalid[0].source.?.manifest_path);
    try std.testing.expectEqualStrings(package_root, denied_with_limits.invalid[0].source.?.package_root);
    try std.testing.expectEqualStrings("wasm/missing.wasm", denied_with_limits.invalid[0].source.?.artifact_path);
}

test "wasm manifest invalid resource limits fail with deterministic diagnostics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    const cases = [_]struct {
        manifest_text: []const u8,
        expected_path: []const u8,
        expected_message: []const u8,
    }{
        .{
            .manifest_text =
            \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Resource limit wrong type","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[],"resourceLimits":[]}
            ,
            .expected_path = "$.resourceLimits",
            .expected_message = "expected object",
        },
        .{
            .manifest_text =
            \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Resource limit unknown","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[],"resourceLimits":{"network":1}}
            ,
            .expected_path = "$.resourceLimits.network",
            .expected_message = "unsupported resource limit",
        },
        .{
            .manifest_text =
            \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Resource limit negative","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[],"resourceLimits":{"timeoutMs":-1}}
            ,
            .expected_path = "$.resourceLimits.timeoutMs",
            .expected_message = "expected non-negative integer",
        },
        .{
            .manifest_text =
            \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Resource limit fractional","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[],"resourceLimits":{"turns":1.5}}
            ,
            .expected_path = "$.resourceLimits.turns",
            .expected_message = "expected non-negative integer",
        },
        .{
            .manifest_text =
            \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Resource limit unsafe integer","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[],"resourceLimits":{"timeoutMs":9007199254740992}}
            ,
            .expected_path = "$.resourceLimits.timeoutMs",
            .expected_message = "expected non-negative integer",
        },
        .{
            .manifest_text =
            \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Resource limit tool scopes type","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[],"resourceLimits":{"toolScopes":"example.tool"}}
            ,
            .expected_path = "$.resourceLimits.toolScopes",
            .expected_message = "expected array",
        },
        .{
            .manifest_text =
            \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Resource limit tool scopes empty","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":[],"resourceLimits":{"toolScopes":["example.tool",""]}}
            ,
            .expected_path = "$.resourceLimits.toolScopes[1]",
            .expected_message = "must not be empty",
        },
    };

    for (cases) |case| {
        var result = try validateManifestText(allocator, package_root, case.manifest_text);
        defer result.deinit(allocator);
        try expectInvalid(&result, case.expected_path, case.expected_message);
    }
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

test "wasm manifest exact approved grants permit requested capabilities" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const package_root = try makeValidPackage(allocator, tmp);
    defer allocator.free(package_root);

    var approved = try validateManifestTextWithOptions(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Approved capability","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":["file.read"]}
    , .{ .approved_capabilities = &.{.file_read} });
    defer approved.deinit(allocator);
    try std.testing.expect(approved == .valid);
    try std.testing.expectEqual(@as(usize, 1), approved.valid.requested_capabilities.len);
    try std.testing.expectEqual(Capability.file_read, approved.valid.requested_capabilities[0]);

    var sibling = try validateManifestTextWithOptions(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Sibling grant","artifact":{"kind":"wasm-component","path":"wasm/example-tool.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":["file.read"]}
    , .{ .approved_capabilities = &.{.file_write} });
    defer sibling.deinit(allocator);
    try expectDeniedCapability(&sibling, "$.capabilities[0]", .file_read, .validate);

    var missing_artifact_after_approval = try validateManifestTextWithOptions(allocator, package_root,
        \\{"schemaVersion":"pi-extension.v0","id":"com.example","name":"Example","version":"0.1.0","description":"Approved capability missing artifact","artifact":{"kind":"wasm-component","path":"wasm/missing.wasm"},"tool":{"id":"example.tool","description":"Tool","inputSchema":{},"outputSchema":{}},"capabilities":["file.read"]}
    , .{ .approved_capabilities = &.{.file_read} });
    defer missing_artifact_after_approval.deinit(allocator);
    try expectInvalid(&missing_artifact_after_approval, "$.artifact.path", "artifact file was not found");
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
        .{ .capability = .network_request, .id = "network.request", .branch = .network_request },
        .{ .capability = .shell_run, .id = "shell.run", .branch = .shell_process },
        .{ .capability = .env_read, .id = "env.read", .branch = .environment_variable },
        .{ .capability = .model_call, .id = "model.call", .branch = .model_call },
        .{ .capability = .session_read, .id = "session.read", .branch = .session_read },
        .{ .capability = .session_write, .id = "session.write", .branch = .session_write },
        .{ .capability = .ui_notify, .id = "ui.notify", .branch = .ui_notification },
        .{ .capability = .tool_use, .id = "tool.use", .branch = .tool_execution },
        .{ .capability = .agent_spawn, .id = "agent.spawn", .branch = .agent_spawn },
        .{ .capability = .agent_delegate, .id = "agent.delegate", .branch = .agent_delegate },
    };

    try std.testing.expectEqual(CANONICAL_CAPABILITIES.len, expected.len);
    try std.testing.expectEqual(@typeInfo(Capability).@"enum".fields.len, expected.len);
    for (expected) |entry| {
        try std.testing.expectEqualStrings(entry.id, entry.capability.jsonName());
        try std.testing.expectEqual(entry.capability, parseCapability(entry.id).?);
        try std.testing.expectEqual(entry.branch, entry.capability.enforcementBranch());
    }
    try std.testing.expectEqual(@as(?Capability, null), parseCapability("filesystem"));
    try std.testing.expectEqual(@as(?Capability, null), parseCapability("session"));
    try std.testing.expectEqual(@as(?Capability, null), parseCapability("cap-wiki"));
}

test "wasm capability canonical ids match TypeScript parity fixture" {
    const fixture_path = "../packages/coding-agent/test/fixtures/extension-security-grants.json";
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, fixture_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .array);
    const fixture_capabilities = parsed.value.array.items;
    try std.testing.expectEqual(CANONICAL_CAPABILITIES.len, fixture_capabilities.len);

    for (CANONICAL_CAPABILITIES, fixture_capabilities) |capability, fixture_capability| {
        try std.testing.expect(fixture_capability == .string);
        try std.testing.expectEqualStrings(capability.jsonName(), fixture_capability.string);
    }
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
        denyFirstUnapprovedCapability(&.{ .shell_run, .network_request }, &.{ .shell_run, .network_request }, .initialize, "manifest-request"),
    );
    try std.testing.expectEqual(
        Capability.shell_run,
        denyFirstUnapprovedCapability(&.{.shell_run}, &.{.network_request}, .initialize, "manifest-request").?.capability,
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
        .{ .module_name = "pi:network", .field_name = "fetch", .capability = .network_request },
        .{ .module_name = "pi:shell", .field_name = "run", .capability = .shell_run },
        .{ .module_name = "pi:environment", .field_name = "get", .capability = .env_read },
        .{ .module_name = "pi:model", .field_name = "call", .capability = .model_call },
        .{ .module_name = "pi:session", .field_name = "get", .capability = .session_read },
        .{ .module_name = "pi:session", .field_name = "set", .capability = .session_write },
        .{ .module_name = "pi:ui", .field_name = "notify", .capability = .ui_notify },
        .{ .module_name = "pi:tool", .field_name = "use", .capability = .tool_use },
        .{ .module_name = "pi:agent", .field_name = "spawn", .capability = .agent_spawn },
        .{ .module_name = "pi:agent", .field_name = "delegate", .capability = .agent_delegate },
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
