const std = @import("std");
const wasm_manifest = @import("wasm/wasm_manifest.zig");

pub const Grant = wasm_manifest.Capability;
pub const Branch = wasm_manifest.CapabilityEnforcementBranch;
pub const Phase = wasm_manifest.LifecyclePhase;
pub const CANONICAL_GRANTS = wasm_manifest.CANONICAL_CAPABILITIES;

pub const Principal = struct {
    runtime_kind: []const u8,
    extension_id: []const u8,
    package_root: ?[]const u8 = null,
    invocation_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

pub const ResourceLimits = struct {
    max_children: ?u64 = null,
    depth: ?u64 = null,
    turns: ?u64 = null,
    timeout_ms: ?u64 = null,
    output_bytes: ?u64 = null,
    output_lines: ?u64 = null,
    tool_scopes: []const []const u8 = &.{},

    pub fn validate(self: ResourceLimits) !void {
        _ = self.max_children;
        _ = self.depth;
        _ = self.turns;
        _ = self.timeout_ms;
        _ = self.output_bytes;
        _ = self.output_lines;
        for (self.tool_scopes) |scope| {
            if (scope.len == 0) return error.InvalidResourceLimit;
        }
    }
};

pub const Policy = struct {
    approved_grants: []const Grant = &.{},
    resource_limits: ResourceLimits = .{},
};

pub const Operation = enum {
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

    pub fn jsonName(self: Operation) []const u8 {
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

    pub fn requiredGrant(self: Operation) Grant {
        return switch (self) {
            .file_read => .file_read,
            .file_write => .file_write,
            .network_request => .network_request,
            .shell_run => .shell_run,
            .env_read => .env_read,
            .model_call => .model_call,
            .session_read => .session_read,
            .session_write => .session_write,
            .ui_notify => .ui_notify,
            .tool_use => .tool_use,
            .agent_spawn => .agent_spawn,
            .agent_delegate => .agent_delegate,
        };
    }

    pub fn branch(self: Operation) Branch {
        return self.requiredGrant().enforcementBranch();
    }
};

pub const OperationTarget = struct {
    id: ?[]const u8 = null,
};

pub const UsageDelta = struct {
    turns: u64 = 0,
    output_bytes: u64 = 0,
    output_lines: u64 = 0,
    children_started: u64 = 0,
};

pub const Accounting = struct {
    allowed_operations: u64 = 0,
    turns: u64 = 0,
    output_bytes: u64 = 0,
    output_lines: u64 = 0,
    children_started: u64 = 0,

    pub fn applyAllowed(self: *Accounting, delta: UsageDelta) void {
        self.allowed_operations += 1;
        self.turns += delta.turns;
        self.output_bytes += delta.output_bytes;
        self.output_lines += delta.output_lines;
        self.children_started += delta.children_started;
    }
};

pub const AllowDecision = struct {
    capability: Grant,
    branch: Branch,
    phase: Phase,
    mode: []const u8,
    principal: Principal,
    operation: Operation,
    target: OperationTarget,
    usage_delta: UsageDelta,
};

pub const DenyDecision = struct {
    category: []const u8 = "denied_capability",
    capability: Grant,
    branch: Branch,
    phase: Phase,
    mode: []const u8,
    principal: Principal,
    operation: Operation,
    target: OperationTarget,
    reason: []const u8,
};

pub const Decision = union(enum) {
    allow: AllowDecision,
    deny: DenyDecision,
};

pub fn parseGrantId(value: []const u8) ?Grant {
    inline for (@typeInfo(Grant).@"enum".fields) |field| {
        const grant: Grant = @enumFromInt(field.value);
        if (std.mem.eql(u8, value, grant.jsonName())) return grant;
    }
    return null;
}

pub fn operationForRuntimeImport(module_name: []const u8, field_name: []const u8) ?Operation {
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

pub fn decide(
    principal: Principal,
    policy: Policy,
    operation: Operation,
    target: OperationTarget,
    phase: Phase,
    mode: []const u8,
    delta: UsageDelta,
    accounting: *Accounting,
) Decision {
    const grant = operation.requiredGrant();
    if (!hasGrant(policy.approved_grants, grant)) {
        return deny(principal, operation, target, phase, mode, "grant is not approved");
    }

    if (operation == .tool_use and policy.resource_limits.tool_scopes.len > 0) {
        const target_id = target.id orelse return deny(principal, operation, target, phase, mode, "tool target is required when toolScopes are constrained");
        if (!containsString(policy.resource_limits.tool_scopes, target_id)) {
            return deny(principal, operation, target, phase, mode, "tool target is outside toolScopes");
        }
    }

    accounting.applyAllowed(delta);
    return .{ .allow = .{
        .capability = grant,
        .branch = operation.branch(),
        .phase = phase,
        .mode = mode,
        .principal = principal,
        .operation = operation,
        .target = target,
        .usage_delta = delta,
    } };
}

fn deny(
    principal: Principal,
    operation: Operation,
    target: OperationTarget,
    phase: Phase,
    mode: []const u8,
    reason: []const u8,
) Decision {
    return .{ .deny = .{
        .capability = operation.requiredGrant(),
        .branch = operation.branch(),
        .phase = phase,
        .mode = mode,
        .principal = principal,
        .operation = operation,
        .target = target,
        .reason = reason,
    } };
}

fn hasGrant(grants: []const Grant, needle: Grant) bool {
    for (grants) |grant| {
        if (grant == needle) return true;
    }
    return false;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

const all_operations = [_]Operation{
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

const test_principal: Principal = .{
    .runtime_kind = "native",
    .extension_id = "com.pi.enforcement-fixture",
    .package_root = "native://enforcement-fixture",
    .invocation_id = "invocation-1",
    .session_id = "session-1",
};

test "enforcement canonical grants are security permissions only" {
    const expected = [_]struct {
        grant: Grant,
        id: []const u8,
        operation: Operation,
        branch: Branch,
    }{
        .{ .grant = .file_read, .id = "file.read", .operation = .file_read, .branch = .filesystem_read },
        .{ .grant = .file_write, .id = "file.write", .operation = .file_write, .branch = .filesystem_write },
        .{ .grant = .network_request, .id = "network.request", .operation = .network_request, .branch = .network_request },
        .{ .grant = .shell_run, .id = "shell.run", .operation = .shell_run, .branch = .shell_process },
        .{ .grant = .env_read, .id = "env.read", .operation = .env_read, .branch = .environment_variable },
        .{ .grant = .model_call, .id = "model.call", .operation = .model_call, .branch = .model_call },
        .{ .grant = .session_read, .id = "session.read", .operation = .session_read, .branch = .session_read },
        .{ .grant = .session_write, .id = "session.write", .operation = .session_write, .branch = .session_write },
        .{ .grant = .ui_notify, .id = "ui.notify", .operation = .ui_notify, .branch = .ui_notification },
        .{ .grant = .tool_use, .id = "tool.use", .operation = .tool_use, .branch = .tool_execution },
        .{ .grant = .agent_spawn, .id = "agent.spawn", .operation = .agent_spawn, .branch = .agent_spawn },
        .{ .grant = .agent_delegate, .id = "agent.delegate", .operation = .agent_delegate, .branch = .agent_delegate },
    };

    try std.testing.expectEqual(expected.len, CANONICAL_GRANTS.len);
    try std.testing.expectEqual(expected.len, @typeInfo(Grant).@"enum".fields.len);
    try std.testing.expectEqual(expected.len, @typeInfo(Operation).@"enum".fields.len);
    for (expected) |entry| {
        try std.testing.expectEqual(entry.grant, parseGrantId(entry.id).?);
        try std.testing.expectEqualStrings(entry.id, entry.grant.jsonName());
        try std.testing.expectEqual(entry.grant, entry.operation.requiredGrant());
        try std.testing.expectEqual(entry.branch, entry.operation.branch());
        try std.testing.expectEqual(entry.branch, entry.grant.enforcementBranch());
    }
    try std.testing.expectEqual(@as(?Grant, null), parseGrantId("tool"));
    try std.testing.expectEqual(@as(?Grant, null), parseGrantId("workflow.run"));
    try std.testing.expectEqual(@as(?Grant, null), parseGrantId("database.query"));
}

test "enforcement runtime imports map to exactly one operation branch" {
    const expected = [_]struct {
        module_name: []const u8,
        field_name: []const u8,
        operation: Operation,
    }{
        .{ .module_name = "pi:filesystem", .field_name = "read", .operation = .file_read },
        .{ .module_name = "pi:filesystem", .field_name = "write", .operation = .file_write },
        .{ .module_name = "pi:network", .field_name = "fetch", .operation = .network_request },
        .{ .module_name = "pi:shell", .field_name = "run", .operation = .shell_run },
        .{ .module_name = "pi:environment", .field_name = "get", .operation = .env_read },
        .{ .module_name = "pi:model", .field_name = "call", .operation = .model_call },
        .{ .module_name = "pi:session", .field_name = "get", .operation = .session_read },
        .{ .module_name = "pi:session", .field_name = "set", .operation = .session_write },
        .{ .module_name = "pi:ui", .field_name = "notify", .operation = .ui_notify },
        .{ .module_name = "pi:tool", .field_name = "use", .operation = .tool_use },
        .{ .module_name = "pi:agent", .field_name = "spawn", .operation = .agent_spawn },
        .{ .module_name = "pi:agent", .field_name = "delegate", .operation = .agent_delegate },
    };

    for (expected) |entry| {
        const operation = operationForRuntimeImport(entry.module_name, entry.field_name).?;
        try std.testing.expectEqual(entry.operation, operation);
        try std.testing.expectEqual(entry.operation.requiredGrant(), wasm_manifest.runtimeImportCapability(entry.module_name, entry.field_name).?);
        try std.testing.expectEqual(entry.operation.requiredGrant().enforcementBranch(), operation.branch());
    }
    try std.testing.expectEqual(@as(?Operation, null), operationForRuntimeImport("pi:agent", "unknown"));
    try std.testing.expectEqual(@as(?Operation, null), operationForRuntimeImport("pi:unknown", "read"));
}

test "enforcement decisions deny unapproved grants before accounting" {
    var accounting = Accounting{};
    for (all_operations) |operation| {
        const before = accounting;
        const decision = decide(
            test_principal,
            .{ .approved_grants = &.{}, .resource_limits = .{ .turns = 1, .tool_scopes = &.{"safe.tool"} } },
            operation,
            .{ .id = "safe.tool" },
            .initialize,
            "runtime/import",
            .{ .turns = 1, .output_bytes = 10, .children_started = 1 },
            &accounting,
        );
        try std.testing.expect(decision == .deny);
        try std.testing.expectEqualStrings("denied_capability", decision.deny.category);
        try std.testing.expectEqual(operation.requiredGrant(), decision.deny.capability);
        try std.testing.expectEqual(operation.branch(), decision.deny.branch);
        try std.testing.expectEqual(.initialize, decision.deny.phase);
        try std.testing.expectEqualStrings("runtime/import", decision.deny.mode);
        try std.testing.expectEqual(operation, decision.deny.operation);
        try std.testing.expectEqual(before, accounting);
    }
}

test "enforcement approved grant allows only its matching operation branch and records accounting" {
    for (all_operations) |approved_operation| {
        var accounting = Accounting{};
        for (all_operations) |requested_operation| {
            const before = accounting;
            const decision = decide(
                test_principal,
                .{ .approved_grants = &.{approved_operation.requiredGrant()} },
                requested_operation,
                .{ .id = "safe.tool" },
                .call,
                "policy/decision",
                .{ .turns = 2, .output_bytes = 7, .output_lines = 1 },
                &accounting,
            );
            if (requested_operation == approved_operation) {
                try std.testing.expect(decision == .allow);
                try std.testing.expectEqual(approved_operation.requiredGrant(), decision.allow.capability);
                try std.testing.expectEqual(approved_operation.branch(), decision.allow.branch);
                try std.testing.expectEqual(@as(u64, before.allowed_operations + 1), accounting.allowed_operations);
                try std.testing.expectEqual(@as(u64, before.turns + 2), accounting.turns);
                try std.testing.expectEqual(@as(u64, before.output_bytes + 7), accounting.output_bytes);
                try std.testing.expectEqual(@as(u64, before.output_lines + 1), accounting.output_lines);
            } else {
                try std.testing.expect(decision == .deny);
                try std.testing.expectEqual(requested_operation.requiredGrant(), decision.deny.capability);
                try std.testing.expectEqual(before, accounting);
            }
        }
    }
}

test "enforcement resource limits constrain without granting and tool scopes narrow allowed tool use" {
    try (ResourceLimits{ .tool_scopes = &.{"safe.tool"} }).validate();
    try std.testing.expectError(error.InvalidResourceLimit, (ResourceLimits{ .tool_scopes = &.{""} }).validate());

    var denied_accounting = Accounting{};
    const no_grant = decide(
        test_principal,
        .{ .approved_grants = &.{}, .resource_limits = .{ .tool_scopes = &.{"safe.tool"} } },
        .tool_use,
        .{ .id = "safe.tool" },
        .call,
        "policy/decision",
        .{ .turns = 1 },
        &denied_accounting,
    );
    try std.testing.expect(no_grant == .deny);
    try std.testing.expectEqual(Grant.tool_use, no_grant.deny.capability);
    try std.testing.expectEqual(@as(u64, 0), denied_accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 0), denied_accounting.turns);

    var scoped_accounting = Accounting{};
    const out_of_scope = decide(
        test_principal,
        .{ .approved_grants = &.{.tool_use}, .resource_limits = .{ .tool_scopes = &.{"safe.tool"} } },
        .tool_use,
        .{ .id = "other.tool" },
        .call,
        "policy/decision",
        .{ .turns = 1 },
        &scoped_accounting,
    );
    try std.testing.expect(out_of_scope == .deny);
    try std.testing.expectEqualStrings("tool target is outside toolScopes", out_of_scope.deny.reason);
    try std.testing.expectEqual(@as(u64, 0), scoped_accounting.allowed_operations);

    const in_scope = decide(
        test_principal,
        .{ .approved_grants = &.{.tool_use}, .resource_limits = .{ .tool_scopes = &.{"safe.tool"} } },
        .tool_use,
        .{ .id = "safe.tool" },
        .call,
        "policy/decision",
        .{ .turns = 1 },
        &scoped_accounting,
    );
    try std.testing.expect(in_scope == .allow);
    try std.testing.expectEqual(@as(u64, 1), scoped_accounting.allowed_operations);
    try std.testing.expectEqual(@as(u64, 1), scoped_accounting.turns);
}
