const std = @import("std");
const extension_manifest = @import("extension_manifest.zig");
const extension_runtime = @import("extension_runtime.zig");
const native_runtime = @import("native_runtime.zig");
const capability = @import("capability.zig");

/// Load a native extension from a parsed manifest and return a RuntimeAdapter.
/// The caller must eventually call RuntimeAdapter.deinit(), which will free
/// all owned descriptor memory and shut down the native runtime.
pub fn loadNativeFromManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    manifest: extension_manifest.NormalizedManifest,
    approved_capabilities: []const capability.Capability,
    policy_lookup_key: ?[]const u8,
) !extension_runtime.RuntimeAdapter {
    var descriptor = try buildNativeDescriptor(allocator, manifest);
    errdefer freeOwnedDescriptor(allocator, &descriptor);

    const runtime = try native_runtime.NativeRuntime.start(allocator, io, .{
        .descriptor = &descriptor,
        .approved_capabilities = approved_capabilities,
        .policy_lookup_key = policy_lookup_key,
    });
    runtime.owned_descriptor = &descriptor;
    runtime.owned_descriptor_allocator = allocator;

    return .{
        .ptr = @ptrCast(runtime),
        .vtable = &extension_runtime.native_vtable,
        .kind = .native,
    };
}

fn buildNativeDescriptor(
    allocator: std.mem.Allocator,
    manifest: extension_manifest.NormalizedManifest,
) !native_runtime.NativeDescriptor {
    const id = try allocator.dupe(u8, manifest.id);
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, manifest.name);
    errdefer allocator.free(name);
    const version = try allocator.dupe(u8, manifest.version);
    errdefer allocator.free(version);
    const description = try allocator.dupe(u8, manifest.description);
    errdefer allocator.free(description);

    const tools = try parseNativeTools(allocator, manifest.tools, manifest.package_root);
    errdefer {
        for (tools) |*tool| freeToolDefinition(allocator, tool);
        allocator.free(tools);
    }

    const hooks = try parseNativeHooks(allocator, manifest.hooks);
    errdefer {
        for (hooks) |*hook| freeHookDefinition(allocator, hook);
        allocator.free(hooks);
    }

    const caps = try parseNativeCapabilities(allocator, manifest.capabilities);
    errdefer allocator.free(caps);

    const limits = try parseNativeResourceLimits(allocator, manifest.runtime_limits);

    var dynamic_library_path: ?[]const u8 = null;
    var start_fn: native_runtime.NativeStartFn = native_runtime.defaultNativeStart;
    if (manifest.runtime_entrypoint == .object) {
        if (manifest.runtime_entrypoint.object.get("dynamic_library_path")) |dl| {
            if (dl == .string and dl.string.len > 0) {
                const abs_path = try std.fs.path.resolve(allocator, &.{ manifest.package_root, dl.string });
                errdefer allocator.free(abs_path);
                dynamic_library_path = abs_path;

                const handle = std.c.dlopen(try allocator.dupeZ(u8, abs_path), .{ .NOW = true });
                if (handle) |h| {
                    const sym = std.c.dlsym(h, "pi_extension_start");
                    if (sym) |s| {
                        start_fn = @ptrCast(@alignCast(s));
                    }
                }
            }
        }
    }

    return .{
        .id = id,
        .name = name,
        .version = version,
        .description = description,
        .tools = tools,
        .hooks = hooks,
        .requested_capabilities = caps,
        .resource_limits = limits,
        .dynamic_library_path = dynamic_library_path,
        .start = start_fn,
    };
}

fn parseNativeTools(
    allocator: std.mem.Allocator,
    tools_json: std.json.Value,
    package_root: []const u8,
) ![]native_runtime.NativeToolDefinition {
    if (tools_json != .array) return &[_]native_runtime.NativeToolDefinition{};
    const items = tools_json.array.items;
    if (items.len == 0) return &[_]native_runtime.NativeToolDefinition{};

    const tools = try allocator.alloc(native_runtime.NativeToolDefinition, items.len);
    errdefer allocator.free(tools);
    var initialized: usize = 0;
    errdefer {
        for (tools[0..initialized]) |*tool| freeToolDefinition(allocator, tool);
    }

    for (items, 0..) |item, i| {
        if (item != .object) continue;
        const obj = item.object;
        const tool_name = jsonString(obj, "name") orelse continue;
        const tool_desc = jsonString(obj, "description") orelse "";
        const tool_label = jsonString(obj, "label") orelse tool_name;
        const input_schema = jsonStringifyField(allocator, obj, "inputSchema") orelse
            jsonStringifyField(allocator, obj, "parameters") orelse "{}";
        errdefer allocator.free(input_schema);
        const output_schema = jsonStringifyField(allocator, obj, "outputSchema") orelse null;

        const extension_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ package_root, tool_name });
        errdefer allocator.free(extension_path);

        tools[i] = .{
            .name = try allocator.dupe(u8, tool_name),
            .label = try allocator.dupe(u8, tool_label),
            .description = try allocator.dupe(u8, tool_desc),
            .input_schema_json = input_schema,
            .output_schema_json = output_schema,
            .extension_path = extension_path,
        };
        initialized = i + 1;
    }

    return tools;
}

fn parseNativeHooks(
    allocator: std.mem.Allocator,
    hooks_json: std.json.Value,
) ![]native_runtime.NativeHookDefinition {
    if (hooks_json != .array) return &[_]native_runtime.NativeHookDefinition{};
    const items = hooks_json.array.items;
    if (items.len == 0) return &[_]native_runtime.NativeHookDefinition{};

    const hooks = try allocator.alloc(native_runtime.NativeHookDefinition, items.len);
    errdefer allocator.free(hooks);
    var initialized: usize = 0;
    errdefer {
        for (hooks[0..initialized]) |*hook| freeHookDefinition(allocator, hook);
    }

    for (items, 0..) |item, i| {
        if (item != .object) continue;
        const obj = item.object;
        const event_name = jsonString(obj, "event") orelse jsonString(obj, "eventName") orelse continue;
        const extension_path = jsonString(obj, "extensionPath") orelse event_name;
        hooks[i] = .{
            .event_name = try allocator.dupe(u8, event_name),
            .extension_path = try allocator.dupe(u8, extension_path),
            .priority = jsonInt(obj, "priority") orelse 0,
        };
        initialized = i + 1;
    }

    return hooks;
}

fn parseNativeCapabilities(
    allocator: std.mem.Allocator,
    caps_json: std.json.Value,
) ![]capability.Capability {
    if (caps_json != .array) return &[_]capability.Capability{};
    const items = caps_json.array.items;
    if (items.len == 0) return &[_]capability.Capability{};

    const caps = try allocator.alloc(capability.Capability, items.len);
    errdefer allocator.free(caps);
    var count: usize = 0;

    for (items) |item| {
        if (item != .string) continue;
        const cap = capability.parseCapability(item.string) orelse continue;
        caps[count] = cap;
        count += 1;
    }

    if (count == 0) {
        allocator.free(caps);
        return &[_]capability.Capability{};
    }

    return allocator.realloc(caps, count) catch {
        // On failure, just return the full slice with valid entries at front
        return caps[0..count];
    };
}

fn parseNativeResourceLimits(
    allocator: std.mem.Allocator,
    limits_json: std.json.Value,
) !native_runtime.NativeResourceLimits {
    _ = allocator;
    var limits = native_runtime.NativeResourceLimits{};
    if (limits_json != .object) return limits;
    const obj = limits_json.object;
    if (obj.get("maxChildren")) |v| limits.max_children = jsonU64(v);
    if (obj.get("depth")) |v| limits.depth = jsonU64(v);
    if (obj.get("turns")) |v| limits.turns = jsonU64(v);
    if (obj.get("timeoutMs")) |v| limits.timeout_ms = jsonU64(v);
    if (obj.get("outputBytes")) |v| limits.output_bytes = jsonU64(v);
    if (obj.get("outputLines")) |v| limits.output_lines = jsonU64(v);
    return limits;
}

pub fn freeOwnedDescriptor(allocator: std.mem.Allocator, descriptor: *native_runtime.NativeDescriptor) void {
    native_runtime.freeOwnedNativeDescriptor(allocator, descriptor);
}

fn freeToolDefinition(allocator: std.mem.Allocator, tool: *native_runtime.NativeToolDefinition) void {
    allocator.free(tool.name);
    allocator.free(tool.label);
    allocator.free(tool.description);
    allocator.free(tool.input_schema_json);
    if (tool.output_schema_json) |s| allocator.free(s);
    allocator.free(tool.extension_path);
}

fn freeHookDefinition(allocator: std.mem.Allocator, hook: *native_runtime.NativeHookDefinition) void {
    allocator.free(hook.event_name);
    allocator.free(hook.extension_path);
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = obj.get(key) orelse return null;
    return switch (value) {
        .integer => |i| i,
        else => null,
    };
}

fn jsonU64(value: std.json.Value) ?u64 {
    return switch (value) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        .float => |f| if (f >= 0) @intFromFloat(f) else null,
        else => null,
    };
}

fn jsonStringifyField(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ?[]u8 {
    const value = obj.get(key) orelse return null;
    return std.json.Stringify.valueAlloc(allocator, value, .{}) catch null;
}
