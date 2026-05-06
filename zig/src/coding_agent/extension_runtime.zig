const std = @import("std");
const extension_host = @import("extension_host.zig");
const extension_registry = @import("extension_registry.zig");

pub const DiagnosticCategory = extension_host.DiagnosticCategory;
pub const ExtensionUiRequest = extension_host.ExtensionUiRequest;
pub const HOST_MARKER_ENV = extension_host.HOST_MARKER_ENV;
pub const InitializeFrame = extension_host.InitializeFrame;
pub const ProcessJsonlOptions = extension_host.HostProcessOptions;
pub const Registry = extension_registry.Registry;
pub const RegistryCallback = *const fn (context: ?*anyopaque, registry: *const Registry) anyerror!void;

pub const RuntimeKind = enum {
    process_jsonl,
    wasm,
    native,
    remote,

    pub fn jsonName(self: RuntimeKind) []const u8 {
        return switch (self) {
            .process_jsonl => "process_jsonl",
            .wasm => "wasm",
            .native => "native",
            .remote => "remote",
        };
    }
};

pub const UnsupportedRuntimeOptions = struct {
    label: ?[]const u8 = null,
};

pub const RuntimeOptions = union(RuntimeKind) {
    process_jsonl: ProcessJsonlOptions,
    wasm: UnsupportedRuntimeOptions,
    native: UnsupportedRuntimeOptions,
    remote: UnsupportedRuntimeOptions,
};

pub const RuntimeAdapter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    kind: RuntimeKind,

    pub const VTable = struct {
        wait_for_ready: *const fn (*anyopaque, u64) anyerror!void,
        pending_count: *const fn (*anyopaque) usize,
        diagnostic_count: *const fn (*anyopaque) usize,
        diagnostic_category_count: *const fn (*anyopaque, DiagnosticCategory) usize,
        has_shutdown_complete: *const fn (*anyopaque) bool,
        registry_frames_applied: *const fn (*anyopaque) usize,
        has_registered_command: *const fn (*anyopaque, []const u8) bool,
        snapshot_registry_json: *const fn (*anyopaque, std.mem.Allocator) anyerror![]u8,
        with_registry: *const fn (*anyopaque, ?*anyopaque, RegistryCallback) anyerror!void,
        apply_cli_flag_values: *const fn (*anyopaque, []const extension_registry.ParsedCliFlag) anyerror!void,
        take_ui_requests: *const fn (*anyopaque, std.mem.Allocator) anyerror![]ExtensionUiRequest,
        send_extension_ui_response: *const fn (*anyopaque, []const u8, []const u8) anyerror!void,
        send_extension_event_frame: *const fn (*anyopaque, []const u8) void,
        shutdown: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn waitForReady(self: RuntimeAdapter, timeout_ms: u64) !void {
        try self.vtable.wait_for_ready(self.ptr, timeout_ms);
    }

    pub fn pendingCount(self: RuntimeAdapter) usize {
        return self.vtable.pending_count(self.ptr);
    }

    pub fn diagnosticCount(self: RuntimeAdapter) usize {
        return self.vtable.diagnostic_count(self.ptr);
    }

    pub fn diagnosticCategoryCount(self: RuntimeAdapter, category: DiagnosticCategory) usize {
        return self.vtable.diagnostic_category_count(self.ptr, category);
    }

    pub fn hasShutdownComplete(self: RuntimeAdapter) bool {
        return self.vtable.has_shutdown_complete(self.ptr);
    }

    pub fn registryFramesApplied(self: RuntimeAdapter) usize {
        return self.vtable.registry_frames_applied(self.ptr);
    }

    pub fn hasRegisteredCommand(self: RuntimeAdapter, name: []const u8) bool {
        return self.vtable.has_registered_command(self.ptr, name);
    }

    pub fn snapshotRegistryJson(self: RuntimeAdapter, allocator: std.mem.Allocator) ![]u8 {
        return try self.vtable.snapshot_registry_json(self.ptr, allocator);
    }

    pub fn withRegistry(self: RuntimeAdapter, context: ?*anyopaque, callback: RegistryCallback) !void {
        try self.vtable.with_registry(self.ptr, context, callback);
    }

    pub fn applyCliFlagValues(self: RuntimeAdapter, entries: []const extension_registry.ParsedCliFlag) !void {
        try self.vtable.apply_cli_flag_values(self.ptr, entries);
    }

    pub fn takeUiRequests(self: RuntimeAdapter, allocator: std.mem.Allocator) ![]ExtensionUiRequest {
        return try self.vtable.take_ui_requests(self.ptr, allocator);
    }

    pub fn sendExtensionUiResponse(self: RuntimeAdapter, id: []const u8, payload_json: []const u8) !void {
        try self.vtable.send_extension_ui_response(self.ptr, id, payload_json);
    }

    pub fn sendExtensionEventFrame(self: RuntimeAdapter, frame_json: []const u8) void {
        self.vtable.send_extension_event_frame(self.ptr, frame_json);
    }

    pub fn shutdown(self: RuntimeAdapter) !void {
        try self.vtable.shutdown(self.ptr);
    }

    pub fn deinit(self: RuntimeAdapter) void {
        self.vtable.deinit(self.ptr);
    }
};

pub fn startRuntime(allocator: std.mem.Allocator, io: std.Io, options: RuntimeOptions) !RuntimeAdapter {
    return switch (options) {
        .process_jsonl => |process_options| try startProcessJsonl(allocator, io, process_options),
        .wasm, .native, .remote => error.UnsupportedRuntime,
    };
}

pub fn startProcessJsonl(allocator: std.mem.Allocator, io: std.Io, options: ProcessJsonlOptions) !RuntimeAdapter {
    const host = try extension_host.HostProcess.start(allocator, io, options);
    return .{
        .ptr = @ptrCast(host),
        .vtable = &process_jsonl_vtable,
        .kind = .process_jsonl,
    };
}

fn processHost(ptr: *anyopaque) *extension_host.HostProcess {
    return @ptrCast(@alignCast(ptr));
}

fn processWaitForReady(ptr: *anyopaque, timeout_ms: u64) !void {
    try processHost(ptr).waitForReady(timeout_ms);
}

fn processPendingCount(ptr: *anyopaque) usize {
    return processHost(ptr).pendingCount();
}

fn processDiagnosticCount(ptr: *anyopaque) usize {
    return processHost(ptr).diagnosticCount();
}

fn processDiagnosticCategoryCount(ptr: *anyopaque, category: DiagnosticCategory) usize {
    return processHost(ptr).diagnosticCategoryCount(category);
}

fn processHasShutdownComplete(ptr: *anyopaque) bool {
    return processHost(ptr).hasShutdownComplete();
}

fn processRegistryFramesApplied(ptr: *anyopaque) usize {
    return processHost(ptr).registryFramesApplied();
}

fn processHasRegisteredCommand(ptr: *anyopaque, name: []const u8) bool {
    return processHost(ptr).hasRegisteredCommand(name);
}

fn processSnapshotRegistryJson(ptr: *anyopaque, allocator: std.mem.Allocator) ![]u8 {
    return try processHost(ptr).snapshotRegistryJson(allocator);
}

fn processWithRegistry(ptr: *anyopaque, context: ?*anyopaque, callback: RegistryCallback) !void {
    try processHost(ptr).withRegistry(context, callback);
}

fn processApplyCliFlagValues(ptr: *anyopaque, entries: []const extension_registry.ParsedCliFlag) !void {
    try processHost(ptr).applyCliFlagValues(entries);
}

fn processTakeUiRequests(ptr: *anyopaque, allocator: std.mem.Allocator) ![]ExtensionUiRequest {
    return try processHost(ptr).takeUiRequests(allocator);
}

fn processSendExtensionUiResponse(ptr: *anyopaque, id: []const u8, payload_json: []const u8) !void {
    try processHost(ptr).sendExtensionUiResponse(id, payload_json);
}

fn processSendExtensionEventFrame(ptr: *anyopaque, frame_json: []const u8) void {
    processHost(ptr).sendExtensionEventFrame(frame_json);
}

fn processShutdown(ptr: *anyopaque) !void {
    try processHost(ptr).shutdown();
}

fn processDeinit(ptr: *anyopaque) void {
    processHost(ptr).deinit();
}

const process_jsonl_vtable: RuntimeAdapter.VTable = .{
    .wait_for_ready = processWaitForReady,
    .pending_count = processPendingCount,
    .diagnostic_count = processDiagnosticCount,
    .diagnostic_category_count = processDiagnosticCategoryCount,
    .has_shutdown_complete = processHasShutdownComplete,
    .registry_frames_applied = processRegistryFramesApplied,
    .has_registered_command = processHasRegisteredCommand,
    .snapshot_registry_json = processSnapshotRegistryJson,
    .with_registry = processWithRegistry,
    .apply_cli_flag_values = processApplyCliFlagValues,
    .take_ui_requests = processTakeUiRequests,
    .send_extension_ui_response = processSendExtensionUiResponse,
    .send_extension_event_frame = processSendExtensionEventFrame,
    .shutdown = processShutdown,
    .deinit = processDeinit,
};

fn absoluteTmpPath(allocator: std.mem.Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(cwd);
    return try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "tmp", sub_path, name });
}

fn freeUiRequests(allocator: std.mem.Allocator, requests: []ExtensionUiRequest) void {
    for (requests) |*request| request.deinit(allocator);
    allocator.free(requests);
}

const RegistryExpectContext = struct {
    command_seen: bool = false,
    flag_seen: bool = false,
};

fn expectRegistryEntriesCallback(context: ?*anyopaque, registry: *const Registry) !void {
    const result: *RegistryExpectContext = @ptrCast(@alignCast(context.?));
    for (registry.commands.items) |command| {
        if (std.mem.eql(u8, command.name, "adapter-command")) result.command_seen = true;
    }
    for (registry.flags.items) |flag| {
        if (std.mem.eql(u8, flag.name, "adapter-flag")) result.flag_seen = true;
    }
}

fn expectAdapterRegistryUiEventShutdownConformance(allocator: std.mem.Allocator, adapter: RuntimeAdapter) !void {
    try adapter.waitForReady(500);
    var elapsed: u64 = 0;
    while ((adapter.pendingCount() < 1 or adapter.registryFramesApplied() < 2) and elapsed <= 1000) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingCount());
    try std.testing.expectEqual(@as(usize, 2), adapter.registryFramesApplied());
    try std.testing.expect(adapter.hasRegisteredCommand("adapter-command"));

    var registry_context = RegistryExpectContext{};
    try adapter.withRegistry(&registry_context, expectRegistryEntriesCallback);
    try std.testing.expect(registry_context.command_seen);
    try std.testing.expect(registry_context.flag_seen);

    const requests = try adapter.takeUiRequests(allocator);
    defer freeUiRequests(allocator, requests);
    try std.testing.expectEqual(@as(usize, 2), requests.len);
    try std.testing.expectEqualStrings("notify", requests[0].id);
    try std.testing.expect(!requests[0].response_required);
    try std.testing.expectEqualStrings("pending", requests[1].id);
    try std.testing.expect(requests[1].response_required);

    const empty_requests = try adapter.takeUiRequests(allocator);
    defer freeUiRequests(allocator, empty_requests);
    try std.testing.expectEqual(@as(usize, 0), empty_requests.len);

    try adapter.applyCliFlagValues(&.{
        .{ .name = "adapter-flag", .value = .{ .string = "from-cli" } },
    });
    const snapshot = try adapter.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"adapter-command\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"value\":\"from-cli\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"default\":\"default\"") != null);

    try adapter.sendExtensionUiResponse("unknown", "{\"ignored\":true}");
    try adapter.sendExtensionUiResponse("pending", "{\"accepted\":true}");
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingCount());
    adapter.sendExtensionEventFrame("{\"type\":\"agent_start\"}");
    try adapter.shutdown();
    try std.testing.expect(adapter.hasShutdownComplete());
    adapter.sendExtensionEventFrame("{\"type\":\"agent_end\",\"messages\":[]}");
}

test "extension runtime factory rejects reserved runtime kinds deterministically" {
    const allocator = std.testing.allocator;
    const unsupported = [_]RuntimeOptions{
        .{ .wasm = .{} },
        .{ .native = .{} },
        .{ .remote = .{} },
    };

    for (unsupported) |options| {
        try std.testing.expectError(error.UnsupportedRuntime, startRuntime(allocator, std.testing.io, options));
    }
    try std.testing.expectEqualStrings("process_jsonl", RuntimeKind.process_jsonl.jsonName());
    try std.testing.expectEqualStrings("wasm", RuntimeKind.wasm.jsonName());
    try std.testing.expectEqualStrings("native", RuntimeKind.native.jsonName());
    try std.testing.expectEqualStrings("remote", RuntimeKind.remote.jsonName());
}

test "process_jsonl runtime adapter preserves registry UI response event and shutdown semantics" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_path = try absoluteTmpPath(allocator, &tmp.sub_path, "process-jsonl-adapter-capture.jsonl");
    defer allocator.free(capture_path);
    const cwd_path = try absoluteTmpPath(allocator, &tmp.sub_path, "process-jsonl-adapter-cwd.txt");
    defer allocator.free(cwd_path);

    const script = try std.fmt.allocPrint(
        allocator,
        "pwd > {s}; " ++
            "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"notify\",\"method\":\"notice\",\"responseRequired\":false,\"payload\":{{\"ok\":true}}}}\\n'; " ++
            "printf '{{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true,\"payload\":{{\"text\":\"x\"}}}}\\n'; " ++
            "printf '{{\"type\":\"register_command\",\"name\":\"adapter-command\",\"description\":\"Adapter\",\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "printf '{{\"type\":\"register_flag\",\"name\":\"adapter-flag\",\"valueType\":\"string\",\"default\":\"default\",\"extensionPath\":\"fixture/adapter.ts\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{ cwd_path, capture_path, capture_path },
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "process-jsonl-runtime-adapter" };

    const adapter = try startRuntime(allocator, std.testing.io, .{ .process_jsonl = .{
        .argv = &argv,
        .cwd = "/tmp",
        .initialize = .{
            .marker = "adapter-marker",
            .cwd = "/adapter-initialize-cwd",
            .fixture = "adapter-fixture",
        },
        .shutdown_timeout_ms = 500,
    } });
    defer adapter.deinit();
    try std.testing.expectEqual(RuntimeKind.process_jsonl, adapter.kind);

    try expectAdapterRegistryUiEventShutdownConformance(allocator, adapter);

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"initialize\",\"marker\":\"adapter-marker\",\"cwd\":\"/adapter-initialize-cwd\",\"fixture\":\"adapter-fixture\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"extension_ui_response\",\"id\":\"pending\",\"payload\":{\"accepted\":true}}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"extension_ui_response\",\"id\":\"unknown\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"agent_start\"}\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"agent_end\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"shutdown\"}\n") != null);

    const child_cwd = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, cwd_path, allocator, .unlimited);
    defer allocator.free(child_cwd);
    try std.testing.expect(std.mem.eql(u8, "/tmp\n", child_cwd) or std.mem.eql(u8, "/private/tmp\n", child_cwd));
}

test "process_jsonl runtime adapter preserves readiness diagnostics timeout and startup errors" {
    const allocator = std.testing.allocator;

    const missing_argv = [_][]const u8{ "/tmp/pi-runtime-adapter-missing-host", "--adapter-startup-failure" };
    try std.testing.expectError(error.FileNotFound, startProcessJsonl(allocator, std.testing.io, .{
        .argv = &missing_argv,
        .initialize = .{
            .marker = "adapter-startup-failure",
            .cwd = "/tmp",
            .fixture = "startup-failure",
        },
        .shutdown_timeout_ms = 50,
    }));

    const timeout_script = "IFS= read -r init; sleep 1";
    const timeout_argv = [_][]const u8{ "/bin/sh", "-c", timeout_script, "process-jsonl-runtime-timeout" };
    const timeout_adapter = try startProcessJsonl(allocator, std.testing.io, .{
        .argv = &timeout_argv,
        .initialize = .{
            .marker = "adapter-timeout",
            .cwd = "/tmp",
            .fixture = "timeout",
        },
        .shutdown_timeout_ms = 50,
    });
    defer timeout_adapter.deinit();
    try std.testing.expectError(error.HostNotReady, timeout_adapter.waitForReady(20));
    try timeout_adapter.shutdown();

    const duplicate_ready_script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done";
    const duplicate_ready_argv = [_][]const u8{ "/bin/sh", "-c", duplicate_ready_script, "process-jsonl-runtime-duplicate-ready" };
    const duplicate_ready_adapter = try startProcessJsonl(allocator, std.testing.io, .{
        .argv = &duplicate_ready_argv,
        .initialize = .{
            .marker = "adapter-duplicate-ready",
            .cwd = "/tmp",
            .fixture = "duplicate-ready",
        },
        .shutdown_timeout_ms = 500,
    });
    defer duplicate_ready_adapter.deinit();
    try duplicate_ready_adapter.waitForReady(500);
    var elapsed: u64 = 0;
    while (duplicate_ready_adapter.diagnosticCategoryCount(.duplicate_ready) == 0 and elapsed <= 500) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), duplicate_ready_adapter.diagnosticCategoryCount(.duplicate_ready));
    try std.testing.expect(duplicate_ready_adapter.diagnosticCount() >= 1);
    try duplicate_ready_adapter.shutdown();
    try std.testing.expect(duplicate_ready_adapter.hasShutdownComplete());
}
