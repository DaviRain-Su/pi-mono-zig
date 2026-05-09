const std = @import("std");

/// Lifecycle phases for extension loading and operation.
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

/// Capability identifiers for extension sandbox enforcement.
/// These are default-deny; requested capabilities remain denied until
/// an explicit approval record grants that exact capability.
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

pub fn parseCapability(value: []const u8) ?Capability {
    if (std.mem.eql(u8, value, "file.read")) return .file_read;
    if (std.mem.eql(u8, value, "file.write")) return .file_write;
    if (std.mem.eql(u8, value, "network.request")) return .network_request;
    if (std.mem.eql(u8, value, "shell.run")) return .shell_run;
    if (std.mem.eql(u8, value, "env.read")) return .env_read;
    if (std.mem.eql(u8, value, "model.call")) return .model_call;
    if (std.mem.eql(u8, value, "session.read")) return .session_read;
    if (std.mem.eql(u8, value, "session.write")) return .session_write;
    if (std.mem.eql(u8, value, "ui.notify")) return .ui_notify;
    if (std.mem.eql(u8, value, "tool.use")) return .tool_use;
    if (std.mem.eql(u8, value, "agent.spawn")) return .agent_spawn;
    if (std.mem.eql(u8, value, "agent.delegate")) return .agent_delegate;
    return null;
}

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
