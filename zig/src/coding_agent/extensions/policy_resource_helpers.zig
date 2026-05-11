const std = @import("std");
const config_mod = @import("../config/config.zig");
const enforcement = @import("enforcement.zig");
const native_manifest = @import("native/native_manifest.zig");
const native_runtime = @import("native_runtime.zig");
const wasm_manifest = @import("wasm/wasm_manifest.zig");

pub fn approvedCapabilitiesFromExtensionPolicy(
    allocator: std.mem.Allocator,
    policy: config_mod.ExtensionPolicy,
) ![]wasm_manifest.Capability {
    const approved_grants = policy.approved_grants orelse return allocator.alloc(wasm_manifest.Capability, 0);
    var capabilities = std.ArrayList(wasm_manifest.Capability).empty;
    errdefer capabilities.deinit(allocator);
    for (approved_grants) |grant| {
        if (wasm_manifest.parseCapability(grant)) |capability| {
            try capabilities.append(allocator, capability);
        }
    }
    return capabilities.toOwnedSlice(allocator);
}

pub fn enforcementResourceLimitsFromExtensionPolicy(
    limits: ?config_mod.ExtensionResourceLimits,
) enforcement.ResourceLimits {
    const resource_limits = limits orelse return .{};
    return .{
        .max_children = resource_limits.max_children,
        .depth = resource_limits.depth,
        .turns = resource_limits.turns,
        .timeout_ms = resource_limits.timeout_ms,
        .output_bytes = resource_limits.output_bytes,
        .output_lines = resource_limits.output_lines,
        .tool_scopes = resource_limits.tool_scopes orelse &.{},
    };
}

pub fn nativeResourceLimitsFromExtensionPolicy(
    policy_limits: ?config_mod.ExtensionResourceLimits,
    descriptor_limits: native_runtime.NativeResourceLimits,
) native_runtime.NativeResourceLimits {
    const limits = policy_limits orelse return descriptor_limits;
    return .{
        .max_children = narrowOptionalLimit(limits.max_children, descriptor_limits.max_children),
        .depth = narrowOptionalLimit(limits.depth, descriptor_limits.depth),
        .turns = narrowOptionalLimit(limits.turns, descriptor_limits.turns),
        .timeout_ms = narrowOptionalLimit(limits.timeout_ms, descriptor_limits.timeout_ms),
        .output_bytes = narrowOptionalLimit(limits.output_bytes, descriptor_limits.output_bytes),
        .output_lines = narrowOptionalLimit(limits.output_lines, descriptor_limits.output_lines),
        .tool_scopes = limits.tool_scopes orelse descriptor_limits.tool_scopes,
    };
}

fn narrowOptionalLimit(policy_limit: ?u64, descriptor_limit: ?u64) ?u64 {
    if (policy_limit) |policy_value| {
        if (descriptor_limit) |descriptor_value| return @min(policy_value, descriptor_value);
        return policy_value;
    }
    return descriptor_limit;
}

pub fn nativeManifestResourceLimitsToEnforcement(
    allocator: std.mem.Allocator,
    limits: native_manifest.ResourceLimits,
) !enforcement.ResourceLimits {
    const tool_scopes = try cloneStringListAsConst(allocator, limits.tool_scopes);
    errdefer freeConstStringList(allocator, tool_scopes);
    return .{
        .timeout_ms = limits.timeout_ms,
        .output_bytes = limits.output_bytes,
        .output_lines = limits.output_lines,
        .tool_scopes = tool_scopes,
    };
}

fn cloneStringListAsConst(allocator: std.mem.Allocator, values: []const []u8) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(cloned);
    for (values, 0..) |value, index| {
        cloned[index] = try allocator.dupe(u8, value);
        errdefer allocator.free(cloned[index]);
    }
    return cloned;
}

pub fn narrowEnforcementResourceLimits(base: *enforcement.ResourceLimits, policy: enforcement.ResourceLimits) void {
    base.max_children = narrowOptionalLimit(policy.max_children, base.max_children);
    base.depth = narrowOptionalLimit(policy.depth, base.depth);
    base.turns = narrowOptionalLimit(policy.turns, base.turns);
    base.timeout_ms = narrowOptionalLimit(policy.timeout_ms, base.timeout_ms);
    base.output_bytes = narrowOptionalLimit(policy.output_bytes, base.output_bytes);
    base.output_lines = narrowOptionalLimit(policy.output_lines, base.output_lines);
}

pub fn cloneEnforcementResourceLimits(
    allocator: std.mem.Allocator,
    limits: enforcement.ResourceLimits,
) !enforcement.ResourceLimits {
    const tool_scopes = try cloneConstStringList(allocator, limits.tool_scopes);
    errdefer freeConstStringList(allocator, tool_scopes);
    return .{
        .max_children = limits.max_children,
        .depth = limits.depth,
        .turns = limits.turns,
        .timeout_ms = limits.timeout_ms,
        .output_bytes = limits.output_bytes,
        .output_lines = limits.output_lines,
        .tool_scopes = tool_scopes,
    };
}

pub fn deinitEnforcementResourceLimits(allocator: std.mem.Allocator, limits: *enforcement.ResourceLimits) void {
    freeConstStringList(allocator, limits.tool_scopes);
    limits.* = .{};
}

fn cloneConstStringList(
    allocator: std.mem.Allocator,
    values: []const []const u8,
) ![]const []const u8 {
    const cloned = try allocator.alloc([]const u8, values.len);
    errdefer allocator.free(cloned);
    for (values, 0..) |value, index| {
        cloned[index] = try allocator.dupe(u8, value);
        errdefer allocator.free(cloned[index]);
    }
    return cloned;
}

const freeConstStringList = @import("../slice_utils.zig").freeStringSlice;
