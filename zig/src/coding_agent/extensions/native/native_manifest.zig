const std = @import("std");
const wasm_manifest = @import("../wasm/wasm_manifest.zig");

pub const SCHEMA_VERSION = "pi-extension.v1";
pub const ARTIFACT_KIND = "native-dynamic";
const MAX_SAFE_INTEGER: u64 = 9007199254740991;

const builtin = @import("builtin");

pub const Diagnostic = struct {
    path: []u8,
    message: []u8,

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const ResourceLimits = struct {
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    turns: ?u64 = null,
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
    manifest_sha256: []u8,
    schema_version: []u8,
    id: []u8,
    name: []u8,
    version: []u8,
    description: []u8,
    descriptor: []u8,
    selected_artifact_path: []u8,
    selected_artifact_absolute_path: []u8,
    selected_artifact_os: []u8,
    selected_artifact_arch: []u8,
    selected_artifact_sha256: []u8,
    package_root_sha256: []u8,
    tool_name: []u8,
    requested_capabilities: []wasm_manifest.Capability,
    resource_limits: ResourceLimits,

    pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
        allocator.free(self.package_root);
        allocator.free(self.manifest_path);
        allocator.free(self.manifest_sha256);
        allocator.free(self.schema_version);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.description);
        allocator.free(self.descriptor);
        allocator.free(self.selected_artifact_path);
        allocator.free(self.selected_artifact_absolute_path);
        allocator.free(self.selected_artifact_os);
        allocator.free(self.selected_artifact_arch);
        allocator.free(self.selected_artifact_sha256);
        allocator.free(self.package_root_sha256);
        allocator.free(self.tool_name);
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

pub fn isNativeDynamicManifestText(allocator: std.mem.Allocator, manifest_text: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const root = parsed.value.object;
    const runtime = root.get("runtime") orelse return false;
    if (runtime != .object) return false;
    const kind = stringField(runtime.object, "kind") orelse return false;
    if (!std.mem.eql(u8, kind, "native")) return false;
    if (root.get("artifacts") != null or root.get("nativeArtifacts") != null) return true;
    const entrypoint = runtime.object.get("entrypoint") orelse return false;
    if (entrypoint != .object) return false;
    const descriptor = stringField(entrypoint.object, "descriptor") orelse return false;
    return std.mem.startsWith(u8, descriptor, "native://dynamic/");
}

pub fn validateManifestFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    package_root: []const u8,
) !ValidationResult {
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root, wasm_manifest.MANIFEST_FILE_NAME });
    defer allocator.free(manifest_path);
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, manifest_path, allocator, .limited(256 * 1024)) catch {
        return invalidOne(allocator, "$", "pi-extension.json was not found");
    };
    defer allocator.free(bytes);
    return validateManifestText(allocator, package_root, bytes);
}

pub fn validateManifestText(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    manifest_text: []const u8,
) !ValidationResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, manifest_text, .{}) catch {
        return invalidOne(allocator, "$", "malformed JSON");
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return invalidOne(allocator, "$", "expected object"),
    };

    if (try requiredString(allocator, root, "$", "schemaVersion")) |diagnostic| return diagnostic;
    const schema_version = stringField(root, "schemaVersion").?;
    if (!std.mem.eql(u8, schema_version, SCHEMA_VERSION)) {
        const message = try std.fmt.allocPrint(allocator, "unsupported schema version \"{s}\"; expected " ++ SCHEMA_VERSION, .{schema_version});
        defer allocator.free(message);
        return invalidOne(allocator, "$.schemaVersion", message);
    }
    if (try unsupportedSurfaceDiagnostic(allocator, parsed.value, "$")) |diagnostic| return diagnostic;
    if (try requiredString(allocator, root, "$", "id")) |diagnostic| return diagnostic;
    if (try requiredString(allocator, root, "$", "name")) |diagnostic| return diagnostic;
    if (try requiredString(allocator, root, "$", "version")) |diagnostic| return diagnostic;
    const description = switch (root.get("description") orelse std.json.Value{ .string = "" }) {
        .string => |text| text,
        else => return invalidOne(allocator, "$.description", "expected string"),
    };

    if (try requiredObject(allocator, root, "$", "runtime")) |diagnostic| return diagnostic;
    const runtime = objectField(root, "runtime").?;
    if (try requiredString(allocator, runtime, "$.runtime", "kind")) |diagnostic| return diagnostic;
    const kind = stringField(runtime, "kind").?;
    if (!std.mem.eql(u8, kind, "native")) {
        return invalidOne(allocator, "$.runtime.kind", "native dynamic manifests must use runtime kind \"native\"");
    }
    if (try requiredObject(allocator, runtime, "$.runtime", "entrypoint")) |diagnostic| return diagnostic;
    const entrypoint = objectField(runtime, "entrypoint").?;
    if (try requiredString(allocator, entrypoint, "$.runtime.entrypoint", "descriptor")) |diagnostic| return diagnostic;
    const descriptor = stringField(entrypoint, "descriptor").?;
    if (!std.mem.startsWith(u8, descriptor, "native://dynamic/")) {
        return invalidOne(allocator, "$.runtime.entrypoint.descriptor", "native dynamic descriptor must start with native://dynamic/");
    }
    inline for (unsupported_entrypoint_fields) |field| {
        if (entrypoint.get(field) != null) {
            const path = try std.fmt.allocPrint(allocator, "$.runtime.entrypoint.{s}", .{field});
            defer allocator.free(path);
            return invalidOne(allocator, path, "native dynamic manifests select local libraries through $.artifacts only");
        }
    }

    var resource_limits = switch (try validateResourceLimits(allocator, runtime.get("limits"))) {
        .valid => |limits| limits,
        .invalid => |diagnostic| return diagnostic,
    };
    errdefer resource_limits.deinit(allocator);
    if (root.get("resourceLimits") != null) {
        return invalidOne(allocator, "$.resourceLimits", "native v1 manifests must use $.runtime.limits");
    }

    var selected_artifact = switch (try selectArtifact(allocator, package_root, root)) {
        .valid => |artifact| artifact,
        .invalid => |diagnostic| {
            resource_limits.deinit(allocator);
            return diagnostic;
        },
    };
    errdefer selected_artifact.deinit(allocator);

    const tool_name = switch (try validateTools(allocator, root)) {
        .valid => |name| name,
        .invalid => |diagnostic| {
            selected_artifact.deinit(allocator);
            resource_limits.deinit(allocator);
            return diagnostic;
        },
    };
    errdefer allocator.free(tool_name);
    const capabilities = switch (try validateCapabilities(allocator, root)) {
        .valid => |items| items,
        .invalid => |diagnostic| {
            allocator.free(tool_name);
            selected_artifact.deinit(allocator);
            resource_limits.deinit(allocator);
            return diagnostic;
        },
    };
    errdefer allocator.free(capabilities);

    const package_root_real = try realpathAlloc(allocator, package_root);
    errdefer allocator.free(package_root_real);
    const manifest_path = try std.fs.path.join(allocator, &.{ package_root_real, wasm_manifest.MANIFEST_FILE_NAME });
    errdefer allocator.free(manifest_path);
    const manifest_sha256 = try sha256HexAlloc(allocator, manifest_text);
    errdefer allocator.free(manifest_sha256);
    const package_root_sha256 = try wasm_manifest.computePackageRootSha256(allocator, package_root_real);
    errdefer allocator.free(package_root_sha256);
    const artifact_sha256 = try wasm_manifest.computeArtifactSha256(allocator, selected_artifact.absolute_path);
    errdefer allocator.free(artifact_sha256);

    return .{ .valid = .{
        .package_root = package_root_real,
        .manifest_path = manifest_path,
        .manifest_sha256 = manifest_sha256,
        .schema_version = try allocator.dupe(u8, schema_version),
        .id = try allocator.dupe(u8, stringField(root, "id").?),
        .name = try allocator.dupe(u8, stringField(root, "name").?),
        .version = try allocator.dupe(u8, stringField(root, "version").?),
        .description = try allocator.dupe(u8, description),
        .descriptor = try allocator.dupe(u8, descriptor),
        .selected_artifact_path = selected_artifact.path,
        .selected_artifact_absolute_path = selected_artifact.absolute_path,
        .selected_artifact_os = selected_artifact.os,
        .selected_artifact_arch = selected_artifact.arch,
        .selected_artifact_sha256 = artifact_sha256,
        .package_root_sha256 = package_root_sha256,
        .tool_name = tool_name,
        .requested_capabilities = capabilities,
        .resource_limits = resource_limits,
    } };
}

const SelectedArtifact = struct {
    path: []u8,
    absolute_path: []u8,
    os: []u8,
    arch: []u8,

    fn deinit(self: *SelectedArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.absolute_path);
        allocator.free(self.os);
        allocator.free(self.arch);
        self.* = undefined;
    }
};

const ArtifactSelection = union(enum) {
    valid: SelectedArtifact,
    invalid: ValidationResult,
};

fn selectArtifact(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    root: std.json.ObjectMap,
) !ArtifactSelection {
    const artifacts_value = root.get("artifacts") orelse root.get("nativeArtifacts") orelse
        return .{ .invalid = try invalidOne(allocator, "$.artifacts", "missing required field") };
    if (artifacts_value != .array) {
        return .{ .invalid = try invalidOne(allocator, "$.artifacts", "expected array") };
    }
    if (artifacts_value.array.items.len == 0) {
        return .{ .invalid = try invalidOne(allocator, "$.artifacts", "must contain at least one artifact") };
    }

    const host_os = hostOs();
    const host_arch = hostArch();
    var selected: ?SelectedArtifact = null;
    errdefer if (selected) |*artifact| artifact.deinit(allocator);
    var selectors = std.ArrayList([]u8).empty;
    defer {
        for (selectors.items) |selector| allocator.free(selector);
        selectors.deinit(allocator);
    }

    for (artifacts_value.array.items, 0..) |item, index| {
        if (item != .object) {
            const path = try std.fmt.allocPrint(allocator, "$.artifacts[{d}]", .{index});
            defer allocator.free(path);
            return .{ .invalid = try invalidOne(allocator, path, "expected object") };
        }
        const base_path = try std.fmt.allocPrint(allocator, "$.artifacts[{d}]", .{index});
        defer allocator.free(base_path);
        if (try requiredString(allocator, item.object, base_path, "kind")) |diagnostic| return .{ .invalid = diagnostic };
        if (!std.mem.eql(u8, stringField(item.object, "kind").?, ARTIFACT_KIND)) {
            const path = try std.fmt.allocPrint(allocator, "{s}.kind", .{base_path});
            defer allocator.free(path);
            return .{ .invalid = try invalidOne(allocator, path, "unsupported artifact kind; expected native-dynamic") };
        }
        if (try requiredString(allocator, item.object, base_path, "os")) |diagnostic| return .{ .invalid = diagnostic };
        if (try requiredString(allocator, item.object, base_path, "arch")) |diagnostic| return .{ .invalid = diagnostic };
        if (try requiredString(allocator, item.object, base_path, "path")) |diagnostic| return .{ .invalid = diagnostic };

        const os = canonicalOs(stringField(item.object, "os").?) orelse {
            const path = try std.fmt.allocPrint(allocator, "{s}.os", .{base_path});
            defer allocator.free(path);
            return .{ .invalid = try invalidOne(allocator, path, "unsupported OS selector") };
        };
        const arch = canonicalArch(stringField(item.object, "arch").?) orelse {
            const path = try std.fmt.allocPrint(allocator, "{s}.arch", .{base_path});
            defer allocator.free(path);
            return .{ .invalid = try invalidOne(allocator, path, "unsupported architecture selector") };
        };
        const selector = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ os, arch });
        errdefer allocator.free(selector);
        for (selectors.items) |existing| {
            if (std.mem.eql(u8, existing, selector)) {
                const path = try std.fmt.allocPrint(allocator, "{s}.arch", .{base_path});
                defer allocator.free(path);
                allocator.free(selector);
                if (selected) |*artifact| {
                    artifact.deinit(allocator);
                    selected = null;
                }
                return .{ .invalid = try invalidOne(allocator, path, "duplicate OS/arch artifact selector") };
            }
        }
        try selectors.append(allocator, selector);

        if (std.mem.eql(u8, os, host_os) and std.mem.eql(u8, arch, host_arch)) {
            var artifact = switch (try validateArtifactPath(allocator, package_root, stringField(item.object, "path").?, base_path)) {
                .valid => |valid| valid,
                .invalid => |diagnostic| return .{ .invalid = diagnostic },
            };
            errdefer artifact.deinit(allocator);
            allocator.free(artifact.os);
            allocator.free(artifact.arch);
            artifact.os = try allocator.dupe(u8, os);
            artifact.arch = try allocator.dupe(u8, arch);
            selected = artifact;
        }
    }

    if (selected) |artifact| return .{ .valid = artifact };

    const available = try joinSelectors(allocator, selectors.items);
    defer allocator.free(available);
    const message = try std.fmt.allocPrint(allocator, "no artifact for host {s}/{s}; available selectors: {s}", .{ host_os, host_arch, available });
    defer allocator.free(message);
    return .{ .invalid = try invalidOne(allocator, "$.artifacts", message) };
}

const ArtifactPathResult = union(enum) {
    valid: SelectedArtifact,
    invalid: ValidationResult,
};

fn validateArtifactPath(
    allocator: std.mem.Allocator,
    package_root: []const u8,
    artifact_path: []const u8,
    base_path: []const u8,
) !ArtifactPathResult {
    const json_path = try std.fmt.allocPrint(allocator, "{s}.path", .{base_path});
    defer allocator.free(json_path);
    if (artifact_path.len == 0) return .{ .invalid = try invalidOne(allocator, json_path, "artifact path must not be empty") };
    if (std.fs.path.isAbsolute(artifact_path)) return .{ .invalid = try invalidOne(allocator, json_path, "artifact path must be package-relative") };
    if (std.mem.indexOf(u8, artifact_path, "\\") != null) return .{ .invalid = try invalidOne(allocator, json_path, "artifact path must use '/' separators") };
    if (!std.mem.endsWith(u8, artifact_path, nativeLibrarySuffix())) {
        const message = try std.fmt.allocPrint(allocator, "artifact path must point to a {s} dynamic library", .{nativeLibrarySuffix()});
        defer allocator.free(message);
        return .{ .invalid = try invalidOne(allocator, json_path, message) };
    }
    var components = std.mem.splitScalar(u8, artifact_path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return .{ .invalid = try invalidOne(allocator, json_path, "artifact path must be normalized and stay within the package root") };
        }
    }

    const root_real = realpathAlloc(allocator, package_root) catch {
        return .{ .invalid = try invalidOne(allocator, "$", "package root was not found") };
    };
    defer allocator.free(root_real);
    const candidate_path = try std.fs.path.resolve(allocator, &.{ root_real, artifact_path });
    defer allocator.free(candidate_path);
    if (!pathWithin(root_real, candidate_path)) {
        return .{ .invalid = try invalidOne(allocator, json_path, "artifact path escapes package root") };
    }
    const candidate_real = realpathAlloc(allocator, candidate_path) catch {
        return .{ .invalid = try invalidOne(allocator, json_path, "artifact file was not found") };
    };
    errdefer allocator.free(candidate_real);
    if (!pathWithin(root_real, candidate_real)) {
        allocator.free(candidate_real);
        return .{ .invalid = try invalidOne(allocator, json_path, "artifact path resolves outside package root") };
    }
    const stat = std.Io.Dir.statFile(.cwd(), std.Io.Threaded.global_single_threaded.io(), candidate_real, .{}) catch {
        allocator.free(candidate_real);
        return .{ .invalid = try invalidOne(allocator, json_path, "artifact file was not found") };
    };
    if (stat.kind != .file) {
        allocator.free(candidate_real);
        return .{ .invalid = try invalidOne(allocator, json_path, "artifact path must point to a file") };
    }
    return .{ .valid = .{
        .path = try allocator.dupe(u8, artifact_path),
        .absolute_path = candidate_real,
        .os = try allocator.alloc(u8, 0),
        .arch = try allocator.alloc(u8, 0),
    } };
}

const ToolValidation = union(enum) {
    valid: []u8,
    invalid: ValidationResult,
};

fn validateTools(allocator: std.mem.Allocator, root: std.json.ObjectMap) !ToolValidation {
    const tools = root.get("tools") orelse return .{ .invalid = try invalidOne(allocator, "$.tools", "missing required field") };
    if (tools != .array) return .{ .invalid = try invalidOne(allocator, "$.tools", "expected array") };
    if (tools.array.items.len != 1) return .{ .invalid = try invalidOne(allocator, "$.tools", "native dynamic manifests must declare exactly one tool") };
    const tool = tools.array.items[0];
    if (tool != .object) return .{ .invalid = try invalidOne(allocator, "$.tools[0]", "expected object") };
    if (try requiredString(allocator, tool.object, "$.tools[0]", "name")) |diagnostic| return .{ .invalid = diagnostic };
    if (tool.object.get("inputSchema")) |schema| {
        if (schema != .object) return .{ .invalid = try invalidOne(allocator, "$.tools[0].inputSchema", "expected object") };
    } else return .{ .invalid = try invalidOne(allocator, "$.tools[0].inputSchema", "missing required field") };
    if (tool.object.get("outputSchema")) |schema| {
        if (schema != .object) return .{ .invalid = try invalidOne(allocator, "$.tools[0].outputSchema", "expected object") };
    }
    return .{ .valid = try allocator.dupe(u8, stringField(tool.object, "name").?) };
}

const CapabilityValidation = union(enum) {
    valid: []wasm_manifest.Capability,
    invalid: ValidationResult,
};

fn validateCapabilities(allocator: std.mem.Allocator, root: std.json.ObjectMap) !CapabilityValidation {
    const capabilities = root.get("capabilities") orelse return .{ .invalid = try invalidOne(allocator, "$.capabilities", "missing required field") };
    if (capabilities != .object) return .{ .invalid = try invalidOne(allocator, "$.capabilities", "expected object") };
    if (try validateCapabilityArray(allocator, capabilities.object, "exports")) |diagnostic| return .{ .invalid = diagnostic };
    if (try validateCapabilityArray(allocator, capabilities.object, "imports")) |diagnostic| return .{ .invalid = diagnostic };
    const permissions = root.get("permissions") orelse return .{ .valid = try allocator.alloc(wasm_manifest.Capability, 0) };
    if (permissions != .array) return .{ .invalid = try invalidOne(allocator, "$.permissions", "expected array") };
    var requested = std.ArrayList(wasm_manifest.Capability).empty;
    errdefer requested.deinit(allocator);
    for (permissions.array.items, 0..) |item, index| {
        if (item != .object) {
            const path = try std.fmt.allocPrint(allocator, "$.permissions[{d}]", .{index});
            defer allocator.free(path);
            return .{ .invalid = try invalidOne(allocator, path, "expected object") };
        }
        const grant = stringField(item.object, "id") orelse stringField(item.object, "grant") orelse continue;
        const capability = wasm_manifest.parseCapability(grant) orelse {
            const path = try std.fmt.allocPrint(allocator, "$.permissions[{d}].id", .{index});
            defer allocator.free(path);
            return .{ .invalid = try invalidOne(allocator, path, "unknown capability") };
        };
        try requested.append(allocator, capability);
    }
    return .{ .valid = try requested.toOwnedSlice(allocator) };
}

fn validateCapabilityArray(allocator: std.mem.Allocator, capabilities: std.json.ObjectMap, field: []const u8) !?ValidationResult {
    const value = capabilities.get(field) orelse return null;
    const field_path = try std.fmt.allocPrint(allocator, "$.capabilities.{s}", .{field});
    defer allocator.free(field_path);
    if (value != .array) return try invalidOne(allocator, field_path, "expected array");
    for (value.array.items, 0..) |item, index| {
        const item_path = try std.fmt.allocPrint(allocator, "$.capabilities.{s}[{d}]", .{ field, index });
        defer allocator.free(item_path);
        if (item != .object) return try invalidOne(allocator, item_path, "expected object");
        const id_path = try std.fmt.allocPrint(allocator, "{s}.id", .{item_path});
        defer allocator.free(id_path);
        const id = stringField(item.object, "id") orelse return try invalidOne(allocator, id_path, "missing required field");
        if (id.len == 0) return try invalidOne(allocator, id_path, "must not be empty");
        if (item.object.get("kind")) |kind| {
            const kind_path = try std.fmt.allocPrint(allocator, "{s}.kind", .{item_path});
            defer allocator.free(kind_path);
            if (kind != .string or !isSupportedCapabilityKind(kind.string)) return try invalidOne(allocator, kind_path, "unsupported capability kind");
        }
    }
    return null;
}

const ResourceLimitValidation = union(enum) {
    valid: ResourceLimits,
    invalid: ValidationResult,
};

fn validateResourceLimits(
    allocator: std.mem.Allocator,
    maybe_value: ?std.json.Value,
) !ResourceLimitValidation {
    const value = maybe_value orelse return .{ .valid = try ResourceLimits.initEmpty(allocator) };
    if (value != .object) return .{ .invalid = try invalidOne(allocator, "$.runtime.limits", "expected object") };
    var iterator = value.object.iterator();
    while (iterator.next()) |entry| {
        if (!isResourceLimitField(entry.key_ptr.*)) {
            const path = try std.fmt.allocPrint(allocator, "$.runtime.limits.{s}", .{entry.key_ptr.*});
            defer allocator.free(path);
            return .{ .invalid = try invalidOne(allocator, path, "unsupported resource limit") };
        }
    }
    const timeout_ms = switch (try optionalLimitInteger(allocator, value.object, "timeoutMs")) {
        .valid => |limit| limit,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    const output_bytes = switch (try optionalLimitInteger(allocator, value.object, "outputBytes")) {
        .valid => |limit| limit,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    const output_lines = switch (try optionalLimitInteger(allocator, value.object, "outputLines")) {
        .valid => |limit| limit,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    const turns = switch (try optionalLimitInteger(allocator, value.object, "turns")) {
        .valid => |limit| limit,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    const tool_scopes = switch (try readToolScopes(allocator, value.object)) {
        .valid => |scopes| scopes,
        .invalid => |diagnostic| return .{ .invalid = diagnostic },
    };
    return .{ .valid = .{
        .timeout_ms = timeout_ms,
        .output_bytes = output_bytes,
        .output_lines = output_lines,
        .turns = turns,
        .tool_scopes = tool_scopes,
    } };
}

const OptionalLimitValidation = union(enum) {
    valid: ?u64,
    invalid: ValidationResult,
};

fn optionalLimitInteger(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    field: []const u8,
) !OptionalLimitValidation {
    const value = object.get(field) orelse return .{ .valid = null };
    if (value != .integer or value.integer < 0 or @as(u64, @intCast(value.integer)) > MAX_SAFE_INTEGER) {
        const path = try std.fmt.allocPrint(allocator, "$.runtime.limits.{s}", .{field});
        defer allocator.free(path);
        return .{ .invalid = try invalidOne(allocator, path, "expected non-negative integer") };
    }
    return .{ .valid = @intCast(value.integer) };
}

const ToolScopesValidation = union(enum) {
    valid: [][]u8,
    invalid: ValidationResult,
};

fn readToolScopes(allocator: std.mem.Allocator, object: std.json.ObjectMap) !ToolScopesValidation {
    const value = object.get("toolScopes") orelse return .{ .valid = try allocator.alloc([]u8, 0) };
    if (value != .array) return .{ .invalid = try invalidOne(allocator, "$.runtime.limits.toolScopes", "expected array") };
    var scopes = std.ArrayList([]u8).empty;
    errdefer {
        for (scopes.items) |scope| allocator.free(scope);
        scopes.deinit(allocator);
    }
    for (value.array.items, 0..) |item, index| {
        const path = try std.fmt.allocPrint(allocator, "$.runtime.limits.toolScopes[{d}]", .{index});
        defer allocator.free(path);
        if (item != .string) return .{ .invalid = try invalidOne(allocator, path, "expected string") };
        if (item.string.len == 0) return .{ .invalid = try invalidOne(allocator, path, "must not be empty") };
        try scopes.append(allocator, try allocator.dupe(u8, item.string));
    }
    return .{ .valid = try scopes.toOwnedSlice(allocator) };
}

fn requiredString(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    parent_path: []const u8,
    field: []const u8,
) !?ValidationResult {
    const value = object.get(field) orelse {
        const path = try joinPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, path, "missing required field");
    };
    if (value != .string) {
        const path = try joinPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, path, "expected string");
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
        const path = try joinPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, path, "missing required field");
    };
    if (value != .object) {
        const path = try joinPath(allocator, parent_path, field);
        defer allocator.free(path);
        return try invalidOne(allocator, path, "expected object");
    }
    return null;
}

fn invalidOne(allocator: std.mem.Allocator, path: []const u8, message: []const u8) !ValidationResult {
    const diagnostics = try allocator.alloc(Diagnostic, 1);
    errdefer allocator.free(diagnostics);
    diagnostics[0] = .{
        .path = try allocator.dupe(u8, path),
        .message = try allocator.dupe(u8, message),
    };
    return .{ .invalid = diagnostics };
}

fn stringField(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn objectField(object: std.json.ObjectMap, field: []const u8) ?std.json.ObjectMap {
    const value = object.get(field) orelse return null;
    if (value != .object) return null;
    return value.object;
}

fn joinPath(allocator: std.mem.Allocator, parent_path: []const u8, field: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ parent_path, field });
}

fn canonicalOs(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "macos") or std.mem.eql(u8, value, "darwin") or std.mem.eql(u8, value, "mac")) return "macos";
    if (std.mem.eql(u8, value, "linux")) return "linux";
    if (std.mem.eql(u8, value, "windows") or std.mem.eql(u8, value, "win32")) return "windows";
    return null;
}

fn canonicalArch(value: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, value, "aarch64") or std.mem.eql(u8, value, "arm64")) return "aarch64";
    if (std.mem.eql(u8, value, "x86_64") or std.mem.eql(u8, value, "x64") or std.mem.eql(u8, value, "amd64")) return "x86_64";
    return null;
}

fn hostOs() []const u8 {
    return canonicalOs(@tagName(builtin.os.tag)).?;
}

fn hostArch() []const u8 {
    return canonicalArch(@tagName(builtin.cpu.arch)).?;
}

fn nativeLibrarySuffix() []const u8 {
    return switch (builtin.os.tag) {
        .macos => ".dylib",
        .windows => ".dll",
        else => ".so",
    };
}

fn pathWithin(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len <= root.len) return false;
    return candidate[root.len] == std.fs.path.sep;
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (builtin.os.tag == .windows) {
        return std.fs.path.resolve(allocator, &.{path}) catch return error.FileNotFound;
    }
    const z_path = try allocator.dupeZ(u8, path);
    defer allocator.free(z_path);
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const resolved = std.c.realpath(z_path.ptr, &buffer) orelse return error.FileNotFound;
    return allocator.dupe(u8, std.mem.span(resolved));
}

fn sha256HexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var hex = std.fmt.bytesToHex(digest, .lower);
    return allocator.dupe(u8, hex[0..]);
}

fn joinSelectors(allocator: std.mem.Allocator, selectors: []const []u8) ![]u8 {
    if (selectors.len == 0) return allocator.dupe(u8, "<none>");
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    for (selectors, 0..) |selector, index| {
        if (index > 0) try writer.writer.writeAll(",");
        try writer.writer.writeAll(selector);
    }
    return allocator.dupe(u8, writer.written());
}

fn isSupportedCapabilityKind(value: []const u8) bool {
    inline for (.{ "tool", "command", "resource", "provider", "hook" }) |kind| {
        if (std.mem.eql(u8, value, kind)) return true;
    }
    return false;
}

fn isResourceLimitField(field: []const u8) bool {
    inline for (.{ "timeoutMs", "outputBytes", "outputLines", "turns", "toolScopes" }) |allowed| {
        if (std.mem.eql(u8, field, allowed)) return true;
    }
    return false;
}

const unsupported_entrypoint_fields = [_][]const u8{
    "library_path",
    "dynamic_library_path",
    "remote_url",
};

const unsupported_product_fields = [_][]const u8{
    "signature",
    "signing",
    "publisher",
    "marketplace",
    "registry",
    "registryUrl",
    "remoteUrl",
    "remote",
    "remoteWasmUrl",
    "approvalUi",
    "workflow",
    "workflowPreset",
    "wiki",
    "qa",
    "review",
    "webSimulator",
    "slashCommand",
    "slashCommands",
};

fn unsupportedSurfaceDiagnostic(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    path: []const u8,
) !?ValidationResult {
    switch (value) {
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                const field_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, entry.key_ptr.* });
                defer allocator.free(field_path);
                inline for (unsupported_product_fields) |field| {
                    if (std.mem.eql(u8, entry.key_ptr.*, field)) {
                        return try invalidOne(allocator, field_path, "unsupported native package trust/product surface");
                    }
                }
                if (try unsupportedSurfaceDiagnostic(allocator, entry.value_ptr.*, field_path)) |diagnostic| return diagnostic;
            }
        },
        .array => |array| {
            for (array.items, 0..) |entry, index| {
                const item_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
                defer allocator.free(item_path);
                if (try unsupportedSurfaceDiagnostic(allocator, entry, item_path)) |diagnostic| return diagnostic;
            }
        },
        else => {},
    }
    return null;
}

fn makeValidNativeManifest(allocator: std.mem.Allocator, package_root: []const u8, os: []const u8, arch: []const u8, path: []const u8) ![]u8 {
    _ = package_root;
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": "pi-extension.v1",
        \\  "id": "com.example.native",
        \\  "name": "Native Example",
        \\  "version": "0.1.0",
        \\  "description": "Native dynamic example.",
        \\  "runtime": {{
        \\    "kind": "native",
        \\    "entrypoint": {{ "descriptor": "native://dynamic/com.example.native" }},
        \\    "limits": {{ "timeoutMs": 1000, "outputBytes": 4096, "toolScopes": ["native.echo"] }}
        \\  }},
        \\  "artifacts": [
        \\    {{ "kind": "native-dynamic", "os": "{s}", "arch": "{s}", "path": "{s}" }}
        \\  ],
        \\  "tools": [
        \\    {{ "name": "native.echo", "description": "Echo.", "inputSchema": {{}}, "outputSchema": {{}} }}
        \\  ],
        \\  "capabilities": {{ "exports": [{{ "id": "native.echo", "kind": "tool", "version": "0.1.0" }}], "imports": [] }},
        \\  "permissions": []
        \\}}
    , .{ os, arch, path });
}

fn makePackageRoot(allocator: std.mem.Allocator, tmp: anytype) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &.{ cwd, ".zig-cache", "tmp", &tmp.sub_path, "package" });
}

test "native dynamic manifest accepts host artifact selector and normalizes aliases" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "package/native");
    const artifact_name = try std.fmt.allocPrint(allocator, "native/plugin{s}", .{nativeLibrarySuffix()});
    defer allocator.free(artifact_name);
    const artifact_sub_path = try std.fs.path.join(allocator, &.{ "package", artifact_name });
    defer allocator.free(artifact_sub_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = artifact_sub_path, .data = "native-bytes" });
    const package_root = try makePackageRoot(allocator, tmp);
    defer allocator.free(package_root);
    const manifest = try makeValidNativeManifest(allocator, package_root, if (std.mem.eql(u8, hostOs(), "macos")) "darwin" else hostOs(), if (std.mem.eql(u8, hostArch(), "aarch64")) "arm64" else hostArch(), artifact_name);
    defer allocator.free(manifest);

    var result = try validateManifestText(allocator, package_root, manifest);
    defer result.deinit(allocator);
    try std.testing.expect(result == .valid);
    try std.testing.expectEqualStrings("native-dynamic", ARTIFACT_KIND);
    try std.testing.expectEqualStrings(hostOs(), result.valid.selected_artifact_os);
    try std.testing.expectEqualStrings(hostArch(), result.valid.selected_artifact_arch);
    try std.testing.expectEqualStrings("native.echo", result.valid.tool_name);
}

test "native dynamic manifest rejects malformed artifacts and unsupported selectors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "package/native");
    const artifact_name = try std.fmt.allocPrint(allocator, "native/plugin{s}", .{nativeLibrarySuffix()});
    defer allocator.free(artifact_name);
    const artifact_sub_path = try std.fs.path.join(allocator, &.{ "package", artifact_name });
    defer allocator.free(artifact_sub_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = artifact_sub_path, .data = "native-bytes" });
    const package_root = try makePackageRoot(allocator, tmp);
    defer allocator.free(package_root);

    const cases = [_]struct {
        text: []const u8,
        path: []const u8,
        message: []const u8,
    }{
        .{
            .text = "{\"schemaVersion\":\"pi-extension.v2\",\"id\":\"com.example.native\",\"name\":\"Native\",\"version\":\"0.1.0\",\"runtime\":{\"kind\":\"native\",\"entrypoint\":{\"descriptor\":\"native://dynamic/com.example.native\"}},\"artifacts\":[],\"tools\":[],\"capabilities\":{}}",
            .path = "$.schemaVersion",
            .message = "unsupported schema version",
        },
        .{
            .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"com.example.native\",\"name\":\"Native\",\"version\":\"0.1.0\",\"runtime\":{\"kind\":\"native\",\"entrypoint\":{\"descriptor\":\"native://dynamic/com.example.native\"}},\"artifacts\":[],\"tools\":[],\"capabilities\":{}}",
            .path = "$.artifacts",
            .message = "must contain at least one artifact",
        },
        .{
            .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"com.example.native\",\"name\":\"Native\",\"version\":\"0.1.0\",\"runtime\":{\"kind\":\"native\",\"entrypoint\":{\"descriptor\":\"native://dynamic/com.example.native\"}},\"artifacts\":[{\"kind\":\"native-dynamic\",\"os\":\"plan9\",\"arch\":\"x64\",\"path\":\"native/plugin.dylib\"}],\"tools\":[],\"capabilities\":{}}",
            .path = "$.artifacts[0].os",
            .message = "unsupported OS selector",
        },
        .{
            .text = "{\"schemaVersion\":\"pi-extension.v1\",\"id\":\"com.example.native\",\"name\":\"Native\",\"version\":\"0.1.0\",\"runtime\":{\"kind\":\"native\",\"entrypoint\":{\"descriptor\":\"native://dynamic/com.example.native\"}},\"artifacts\":[{\"kind\":\"native-dynamic\",\"os\":\"macos\",\"arch\":\"x64\",\"path\":\"../plugin.dylib\"}],\"tools\":[],\"capabilities\":{}}",
            .path = "$.artifacts",
            .message = "no artifact for host",
        },
    };
    for (cases) |case| {
        var result = try validateManifestText(allocator, package_root, case.text);
        defer result.deinit(allocator);
        try std.testing.expect(result == .invalid);
        try std.testing.expectEqualStrings(case.path, result.invalid[0].path);
        try std.testing.expect(std.mem.indexOf(u8, result.invalid[0].message, case.message) != null);
    }

    const escaping = try std.fmt.allocPrint(allocator,
        \\{{"schemaVersion":"pi-extension.v1","id":"com.example.native","name":"Native","version":"0.1.0","runtime":{{"kind":"native","entrypoint":{{"descriptor":"native://dynamic/com.example.native"}}}},"artifacts":[{{"kind":"native-dynamic","os":"{s}","arch":"{s}","path":"../plugin{s}"}}],"tools":[],"capabilities":{{}}}}
    , .{ hostOs(), hostArch(), nativeLibrarySuffix() });
    defer allocator.free(escaping);
    var escaping_result = try validateManifestText(allocator, package_root, escaping);
    defer escaping_result.deinit(allocator);
    try std.testing.expect(escaping_result == .invalid);
    try std.testing.expectEqualStrings("$.artifacts[0].path", escaping_result.invalid[0].path);
    try std.testing.expect(std.mem.indexOf(u8, escaping_result.invalid[0].message, "stay within the package root") != null);

    const duplicate = try std.fmt.allocPrint(allocator,
        \\{{"schemaVersion":"pi-extension.v1","id":"com.example.native","name":"Native","version":"0.1.0","runtime":{{"kind":"native","entrypoint":{{"descriptor":"native://dynamic/com.example.native"}}}},"artifacts":[{{"kind":"native-dynamic","os":"{s}","arch":"{s}","path":"{s}"}},{{"kind":"native-dynamic","os":"{s}","arch":"{s}","path":"{s}"}}],"tools":[],"capabilities":{{}}}}
    , .{ hostOs(), hostArch(), artifact_name, hostOs(), hostArch(), artifact_name });
    defer allocator.free(duplicate);
    var duplicate_result = try validateManifestText(allocator, package_root, duplicate);
    defer duplicate_result.deinit(allocator);
    try std.testing.expect(duplicate_result == .invalid);
    try std.testing.expect(std.mem.indexOf(u8, duplicate_result.invalid[0].message, "duplicate OS/arch artifact selector") != null);
}

test "native dynamic manifest rejects invalid resource limits and capability shapes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "package/native");
    const artifact_name = try std.fmt.allocPrint(allocator, "native/plugin{s}", .{nativeLibrarySuffix()});
    defer allocator.free(artifact_name);
    const artifact_sub_path = try std.fs.path.join(allocator, &.{ "package", artifact_name });
    defer allocator.free(artifact_sub_path);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = artifact_sub_path, .data = "native-bytes" });
    const package_root = try makePackageRoot(allocator, tmp);
    defer allocator.free(package_root);

    const invalid_limit = try std.fmt.allocPrint(allocator,
        \\{{"schemaVersion":"pi-extension.v1","id":"com.example.native","name":"Native","version":"0.1.0","runtime":{{"kind":"native","entrypoint":{{"descriptor":"native://dynamic/com.example.native"}},"limits":{{"timeoutMs":-1}}}},"artifacts":[{{"kind":"native-dynamic","os":"{s}","arch":"{s}","path":"{s}"}}],"tools":[{{"name":"native.echo","inputSchema":{{}}}}],"capabilities":{{"exports":[],"imports":[]}}}}
    , .{ hostOs(), hostArch(), artifact_name });
    defer allocator.free(invalid_limit);
    var limit_result = try validateManifestText(allocator, package_root, invalid_limit);
    defer limit_result.deinit(allocator);
    try std.testing.expect(limit_result == .invalid);
    try std.testing.expectEqualStrings("$.runtime.limits.timeoutMs", limit_result.invalid[0].path);

    const invalid_capability = try std.fmt.allocPrint(allocator,
        \\{{"schemaVersion":"pi-extension.v1","id":"com.example.native","name":"Native","version":"0.1.0","runtime":{{"kind":"native","entrypoint":{{"descriptor":"native://dynamic/com.example.native"}}}},"artifacts":[{{"kind":"native-dynamic","os":"{s}","arch":"{s}","path":"{s}"}}],"tools":[{{"name":"native.echo","inputSchema":{{}}}}],"capabilities":[]}}
    , .{ hostOs(), hostArch(), artifact_name });
    defer allocator.free(invalid_capability);
    var capability_result = try validateManifestText(allocator, package_root, invalid_capability);
    defer capability_result.deinit(allocator);
    try std.testing.expect(capability_result == .invalid);
    try std.testing.expectEqualStrings("$.capabilities", capability_result.invalid[0].path);
}
