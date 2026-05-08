const std = @import("std");
const builtin = @import("builtin");
const enforcement = @import("enforcement.zig");
const extension_registry = @import("extension_registry.zig");
const extension_protocol = @import("extension_protocol.zig");
const common = @import("../tools/common.zig");

pub const HOST_MARKER_ENV = "PI_M6_EXTENSION_HOST_MARKER";

pub const DiagnosticCategory = extension_protocol.DiagnosticCategory;
pub const DiagnosticSeverity = extension_protocol.DiagnosticSeverity;
pub const Diagnostic = extension_protocol.Diagnostic;
pub const ExtensionUiRequest = extension_protocol.ExtensionUiRequest;
pub const RegistryFrame = extension_protocol.RegistryFrame;
pub const HostMessage = extension_protocol.HostMessage;
pub const JsonlFrameParser = extension_protocol.JsonlFrameParser;
pub const ProtocolState = extension_protocol.ProtocolState;
pub const InitializeFrame = extension_protocol.InitializeFrame;
pub const startupFailureDiagnostic = extension_protocol.startupFailureDiagnostic;
pub const writeInitializeFrame = extension_protocol.writeInitializeFrame;
pub const writeExtensionUiResponseFrame = extension_protocol.writeExtensionUiResponseFrame;
pub const writeToolCallFrame = extension_protocol.writeToolCallFrame;
pub const writeExtensionEventRequestFrame = extension_protocol.writeExtensionEventRequestFrame;
pub const writeShutdownFrame = extension_protocol.writeShutdownFrame;

const MAX_STDERR_DIAGNOSTICS: usize = 32;
const MAX_STDERR_LINE_BYTES: usize = 512;

pub const HostProcessOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    extension_path: ?[]const u8 = null,
    initialize: InitializeFrame,
    shutdown_timeout_ms: u64 = 1000,
    approved_capabilities: []const enforcement.Grant = &.{},
    resource_limits: enforcement.ResourceLimits = .{},
    policy_lookup_key: ?[]const u8 = null,
};

pub const HostProcess = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    stderr_file: ?std.Io.File,
    parser: JsonlFrameParser = .{},
    state: ProtocolState,
    mutex: std.Io.Mutex = .init,
    wait_thread: ?std.Thread = null,
    reader_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    wait_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reader_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    stderr_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    start_count: usize = 1,
    shutdown_timeout_ms: u64,
    exit_recorded: bool = false,
    wait_err: ?anyerror = null,
    reader_err: ?anyerror = null,
    stderr_err: ?anyerror = null,
    term: ?std.process.Child.Term = null,
    diagnostic_source: []u8,
    stderr_diagnostics_recorded: usize = 0,
    stderr_diagnostics_truncated: bool = false,
    extension_event_sequence: usize = 0,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, options: HostProcessOptions) !*HostProcess {
        const host = try allocator.create(HostProcess);
        errdefer allocator.destroy(host);

        var child = try std.process.spawn(io, .{
            .argv = options.argv,
            .cwd = if (options.cwd) |cwd| .{ .path = cwd } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .pgid = if (builtin.os.tag == .windows) null else 0,
        });
        errdefer if (child.id != null) child.kill(io);

        const stdin_file = child.stdin.?;
        child.stdin = null;
        const stdout_file = child.stdout.?;
        child.stdout = null;
        const stderr_file = child.stderr.?;
        child.stderr = null;
        const diagnostic_source = try allocator.dupe(u8, options.extension_path orelse options.initialize.fixture);
        errdefer allocator.free(diagnostic_source);

        host.* = .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .stderr_file = stderr_file,
            .state = ProtocolState.initWithPolicy(
                allocator,
                .{
                    .approved_grants = options.approved_capabilities,
                    .resource_limits = options.resource_limits,
                },
                .{
                    .runtime_kind = "process_jsonl",
                    .extension_id = options.extension_path orelse options.argv[0],
                    .policy_lookup_key = options.policy_lookup_key,
                    .package_root = options.cwd,
                },
            ),
            .shutdown_timeout_ms = options.shutdown_timeout_ms,
            .diagnostic_source = diagnostic_source,
        };

        try host.sendInitialize(options.initialize);
        host.wait_thread = try std.Thread.spawn(.{}, waitMain, .{host});
        host.reader_thread = try std.Thread.spawn(.{}, readerMain, .{host});
        host.stderr_thread = try std.Thread.spawn(.{}, stderrMain, .{host});
        return host;
    }

    pub fn deinit(self: *HostProcess) void {
        self.shutdown() catch {};
        self.parser.deinit(self.allocator);
        self.state.deinit();
        self.allocator.free(self.diagnostic_source);
        self.allocator.destroy(self);
    }

    pub fn shutdown(self: *HostProcess) !void {
        var shutdown_write_err: ?anyerror = null;
        if (!self.shutdown_requested.swap(true, .seq_cst)) {
            if (self.stdin_file) |file| {
                var shutdown_line: std.Io.Writer.Allocating = .init(self.allocator);
                defer shutdown_line.deinit();
                writeShutdownFrame(&shutdown_line.writer) catch |err| {
                    shutdown_write_err = err;
                };
                if (shutdown_write_err == null) {
                    file.writeStreamingAll(self.io, shutdown_line.written()) catch |err| {
                        shutdown_write_err = err;
                    };
                }
                file.close(self.io);
                self.stdin_file = null;
            }
        }

        var elapsed: u64 = 0;
        while (!self.wait_done.load(.seq_cst) and elapsed <= self.shutdown_timeout_ms) : (elapsed += 10) {
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
        }
        if (!self.wait_done.load(.seq_cst)) self.killProcessGroup();
        if (self.wait_thread) |thread| {
            thread.join();
            self.wait_thread = null;
        }
        if (self.reader_thread) |thread| {
            thread.join();
            self.reader_thread = null;
        }
        if (self.stderr_thread) |thread| {
            thread.join();
            self.stderr_thread = null;
        }
        if (self.stdin_file) |file| {
            file.close(self.io);
            self.stdin_file = null;
        }
        if (self.stdout_file) |file| {
            file.close(self.io);
            self.stdout_file = null;
        }
        if (self.stderr_file) |file| {
            file.close(self.io);
            self.stderr_file = null;
        }
        self.mutex.lockUncancelable(self.io);
        self.state.clearPendingRequests();
        self.mutex.unlock(self.io);
        if (shutdown_write_err) |err| return err;
    }

    pub fn waitForReady(self: *HostProcess, timeout_ms: u64) !void {
        var elapsed: u64 = 0;
        while (elapsed <= timeout_ms) : (elapsed += 10) {
            self.mutex.lockUncancelable(self.io);
            const ready = self.state.ready_seen;
            self.mutex.unlock(self.io);
            if (ready) return;
            if (self.wait_done.load(.seq_cst) and self.reader_done.load(.seq_cst)) break;
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
        }
        return error.HostNotReady;
    }

    pub fn pendingCount(self: *HostProcess) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.pendingCount();
    }

    pub fn diagnosticCount(self: *HostProcess) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.diagnostics.items.len;
    }

    pub fn diagnosticCategoryCount(self: *HostProcess, category: DiagnosticCategory) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.state.diagnostics.items) |diagnostic| {
            if (diagnostic.category == category) count += 1;
        }
        return count;
    }

    pub fn hasShutdownComplete(self: *HostProcess) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.shutdown_complete_seen;
    }

    /// Number of register_* JSONL frames the host has successfully
    /// applied to the runtime registry. Useful for fixture tests that
    /// need to wait for live Bun extensions to drain before
    /// snapshotting.
    pub fn registryFramesApplied(self: *HostProcess) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.registry_frames_applied;
    }

    pub fn hasRegisteredCommand(self: *HostProcess, name: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.registry.hasCommandInvocation(name);
    }

    pub fn hasRegisteredHook(self: *HostProcess, event_name: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.registry.hasHook(event_name);
    }

    /// Render a deterministic JSON snapshot of the runtime registry
    /// the host has accumulated. Caller owns the returned bytes.
    pub fn snapshotRegistryJson(self: *HostProcess, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try extension_registry.writeRegistrySnapshotJson(allocator, &self.state.registry, &out.writer);
        return try allocator.dupe(u8, out.written());
    }

    pub fn withRegistry(
        self: *HostProcess,
        context: ?*anyopaque,
        callback: *const fn (context: ?*anyopaque, registry: *const extension_registry.Registry) anyerror!void,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try callback(context, &self.state.registry);
    }

    /// Apply parsed CLI flag values into the live host registry so
    /// extension code can observe `--<flag>` values via `getFlag()`.
    /// Mirrors the TS runtime step that writes parsed CLI flag values
    /// into `extensionState.flags` after extension load.
    pub fn applyCliFlagValues(
        self: *HostProcess,
        entries: []const extension_registry.ParsedCliFlag,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (entries) |entry| {
            _ = try self.state.registry.setFlagValue(entry.name, entry.value);
        }
    }

    pub fn takeUiRequests(self: *HostProcess, allocator: std.mem.Allocator) ![]ExtensionUiRequest {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const requests = try allocator.alloc(ExtensionUiRequest, self.state.ui_requests.items.len);
        errdefer allocator.free(requests);
        for (self.state.ui_requests.items, 0..) |request, index| {
            requests[index] = try ExtensionUiRequest.clone(allocator, request);
        }
        for (self.state.ui_requests.items) |*request| request.deinit(self.allocator);
        self.state.ui_requests.clearRetainingCapacity();
        return requests;
    }

    pub fn sendExtensionUiResponse(self: *HostProcess, id: []const u8, payload_json: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!self.state.resolvePendingRequest(id)) return;
        const file = self.stdin_file orelse return;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try writeExtensionUiResponseFrame(self.allocator, &out.writer, id, payload_json);
        try file.writeStreamingAll(self.io, out.written());
    }

    pub fn executeTool(
        self: *HostProcess,
        allocator: std.mem.Allocator,
        tool_name: []const u8,
        tool_call_id: []const u8,
        args: std.json.Value,
        timeout_ms: u64,
    ) !extension_protocol.ToolExecutionResponse {
        {
            self.mutex.lockUncancelable(self.io);
            errdefer self.mutex.unlock(self.io);
            const file = self.stdin_file orelse {
                try self.state.addDiagnostic(.host_exit, .@"error", "extension host stdin was closed before tool execution");
                return error.ExtensionHostClosed;
            };
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            try writeToolCallFrame(self.allocator, &out.writer, tool_call_id, tool_name, args);
            try file.writeStreamingAll(self.io, out.written());
        }
        self.mutex.unlock(self.io);

        var elapsed: u64 = 0;
        while (elapsed <= timeout_ms) : (elapsed += 10) {
            self.mutex.lockUncancelable(self.io);
            if (self.state.takeToolResponse(tool_call_id)) |response| {
                self.mutex.unlock(self.io);
                defer {
                    var owned_response = response;
                    owned_response.deinit(self.allocator);
                }
                return try extension_protocol.ToolExecutionResponse.clone(allocator, response);
            }
            const exited = self.wait_done.load(.seq_cst) and self.reader_done.load(.seq_cst);
            if (exited) {
                self.state.removeToolResponses(tool_call_id);
                const message = try std.fmt.allocPrint(
                    self.allocator,
                    "extension host closed before process_jsonl tool response source={s} tool={s} toolCallId={s}",
                    .{ self.diagnostic_source, tool_name, tool_call_id },
                );
                defer self.allocator.free(message);
                try self.state.addDiagnostic(.host_exit, .@"error", message);
                self.mutex.unlock(self.io);
                return error.ExtensionHostClosed;
            }
            self.mutex.unlock(self.io);
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
        }
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.state.removeToolResponses(tool_call_id);
            const message = try std.fmt.allocPrint(
                self.allocator,
                "process_jsonl tool execution timed out after {d}ms source={s} tool={s} toolCallId={s}",
                .{ timeout_ms, self.diagnostic_source, tool_name, tool_call_id },
            );
            defer self.allocator.free(message);
            try self.state.addDiagnostic(.host_error, .@"error", message);
        }
        self.shutdown() catch {};
        return error.ToolExecutionTimedOut;
    }

    pub fn invokeExtensionEvent(
        self: *HostProcess,
        allocator: std.mem.Allocator,
        event_name: []const u8,
        event: std.json.Value,
        timeout_ms: u64,
    ) !?std.json.Value {
        var event_id_buffer: [96]u8 = undefined;
        const event_id = blk: {
            self.mutex.lockUncancelable(self.io);
            errdefer self.mutex.unlock(self.io);
            if (!self.state.registry.hasHook(event_name)) {
                self.mutex.unlock(self.io);
                return null;
            }
            self.extension_event_sequence += 1;
            const id = try std.fmt.bufPrint(
                &event_id_buffer,
                "event-{d}-{s}",
                .{ self.extension_event_sequence, event_name },
            );
            const file = self.stdin_file orelse {
                try self.state.addDiagnostic(.host_exit, .@"error", "extension host stdin was closed before event hook dispatch");
                self.mutex.unlock(self.io);
                return error.ExtensionHostClosed;
            };
            try self.state.addPendingExtensionEventRequest(id);
            errdefer _ = self.state.resolvePendingExtensionEventRequest(id);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            try writeExtensionEventRequestFrame(self.allocator, &out.writer, id, event);
            try file.writeStreamingAll(self.io, out.written());
            self.mutex.unlock(self.io);
            break :blk id;
        };

        var elapsed: u64 = 0;
        while (elapsed <= timeout_ms) : (elapsed += 10) {
            self.mutex.lockUncancelable(self.io);
            if (self.state.takeExtensionEventResponse(event_id)) |response| {
                self.mutex.unlock(self.io);
                defer {
                    var owned_response = response;
                    owned_response.deinit(self.allocator);
                }
                if (response.error_message) |message| {
                    const diagnostic = try std.fmt.allocPrint(
                        self.allocator,
                        "extension hook error source={s} event={s} eventId={s}: {s}",
                        .{ self.diagnostic_source, event_name, event_id, message },
                    );
                    defer self.allocator.free(diagnostic);
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    try self.state.addDiagnostic(.host_error, .warning, diagnostic);
                    return null;
                }
                return if (response.result) |result| try common.cloneJsonValue(allocator, result) else null;
            }
            const exited = self.wait_done.load(.seq_cst) and self.reader_done.load(.seq_cst);
            if (exited) {
                self.state.removeExtensionEventResponses(event_id);
                _ = self.state.resolvePendingExtensionEventRequest(event_id);
                const message = try std.fmt.allocPrint(
                    self.allocator,
                    "extension host closed before event hook response source={s} event={s} eventId={s}",
                    .{ self.diagnostic_source, event_name, event_id },
                );
                defer self.allocator.free(message);
                try self.state.addDiagnostic(.host_exit, .@"error", message);
                self.mutex.unlock(self.io);
                return error.ExtensionHostClosed;
            }
            self.mutex.unlock(self.io);
            std.Io.sleep(self.io, .fromMilliseconds(10), .awake) catch {};
        }
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.state.removeExtensionEventResponses(event_id);
            _ = self.state.resolvePendingExtensionEventRequest(event_id);
            const message = try std.fmt.allocPrint(
                self.allocator,
                "extension hook dispatch timed out after {d}ms source={s} event={s} eventId={s}",
                .{ timeout_ms, self.diagnostic_source, event_name, event_id },
            );
            defer self.allocator.free(message);
            try self.state.addDiagnostic(.host_error, .warning, message);
        }
        return null;
    }

    /// Send a JSONL extension event frame to the extension host stdin pipe.
    /// Non-blocking: if the pipe is full or unavailable, the event is dropped silently.
    /// Caller passes the JSON frame bytes without a trailing newline; this method adds it.
    /// Safe to call from any thread. Does nothing if no extension host stdin is open
    /// or if shutdown has been requested.
    pub fn sendExtensionEventFrame(self: *HostProcess, frame_json: []const u8) void {
        if (self.shutdown_requested.load(.seq_cst)) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const file = self.stdin_file orelse return;
        if (builtin.os.tag == .windows) {
            // On Windows, write directly — pipe semantics differ from POSIX.
            _ = file.writeStreamingAll(self.io, frame_json) catch return;
            _ = file.writeStreamingAll(self.io, "\n") catch return;
        } else {
            const fd = file.handle;
            // Set O_NONBLOCK on the fd temporarily so a full pipe drops the event
            // rather than blocking the agent loop.
            const nonblock_mask: u32 = @bitCast(std.posix.O{ .NONBLOCK = true });
            const prev_flags: c_int = std.c.fcntl(fd, std.c.F.GETFL, @as(c_int, 0));
            if (prev_flags == -1) return;
            defer _ = std.c.fcntl(fd, std.c.F.SETFL, prev_flags);
            _ = std.c.fcntl(fd, std.c.F.SETFL, prev_flags | @as(c_int, @intCast(nonblock_mask)));
            // Best-effort write of frame + newline. EAGAIN (pipe full) or any other
            // error means the event is dropped.
            _ = std.c.write(fd, frame_json.ptr, frame_json.len);
            _ = std.c.write(fd, "\n", 1);
        }
    }

    fn sendInitialize(self: *HostProcess, initialize: InitializeFrame) !void {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try writeInitializeFrame(self.allocator, &out.writer, initialize);
        try self.stdin_file.?.writeStreamingAll(self.io, out.written());
    }

    fn onMessage(self: *HostProcess, message: HostMessage) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const diagnostic_start = self.state.diagnostics.items.len;
        try self.state.onMessage(message);
        try self.annotateDiagnosticsFrom(diagnostic_start, "protocol");
    }

    fn onDiagnostic(self: *HostProcess, diagnostic: Diagnostic) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var owned_diagnostic = diagnostic;
        defer owned_diagnostic.deinit(self.allocator);
        var annotated = try self.annotatedDiagnostic(owned_diagnostic, "stdout_parser");
        errdefer annotated.deinit(self.allocator);
        try self.state.onDiagnostic(annotated);
    }

    fn annotateDiagnosticsFrom(self: *HostProcess, start_index: usize, phase: []const u8) !void {
        var index = start_index;
        while (index < self.state.diagnostics.items.len) : (index += 1) {
            try self.annotateStoredDiagnostic(&self.state.diagnostics.items[index], phase);
        }
    }

    fn annotateStoredDiagnostic(self: *HostProcess, diagnostic: *Diagnostic, phase: []const u8) !void {
        const message = try self.formatDiagnosticMessage(diagnostic.*, phase);
        self.allocator.free(diagnostic.message);
        diagnostic.message = message;
    }

    fn annotatedDiagnostic(self: *HostProcess, diagnostic: Diagnostic, phase: []const u8) !Diagnostic {
        return .{
            .category = diagnostic.category,
            .severity = diagnostic.severity,
            .message = try self.formatDiagnosticMessage(diagnostic, phase),
        };
    }

    fn formatDiagnosticMessage(self: *HostProcess, diagnostic: Diagnostic, phase: []const u8) ![]u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            "process_jsonl diagnostic source={s} phase={s} severity={s} category={s}: {s}",
            .{
                self.diagnostic_source,
                phase,
                diagnostic.severity.jsonName(),
                diagnostic.category.jsonName(),
                diagnostic.message,
            },
        );
    }

    fn markExited(self: *HostProcess) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state.closePendingRequests();
        if (!self.shutdown_requested.load(.seq_cst) and !self.exit_recorded) {
            self.state.addDiagnostic(.host_exit, .@"error", "extension host exited before shutdown") catch {};
        }
        self.exit_recorded = true;
    }

    fn killProcessGroup(self: *HostProcess) void {
        if (self.child.id) |pid| {
            if (builtin.os.tag == .windows) {
                _ = std.os.windows.ntdll.NtTerminateProcess(pid, @enumFromInt(@as(u32, 1)));
            } else {
                std.posix.kill(-pid, .TERM) catch {};
                std.posix.kill(-pid, .KILL) catch {};
            }
        }
    }

    fn onStderrLine(self: *HostProcess, raw_line: []const u8) !void {
        const without_cr = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        const line = std.mem.trim(u8, without_cr, " \t");
        if (line.len == 0) return;
        const excerpt = line[0..@min(line.len, MAX_STDERR_LINE_BYTES)];
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.stderr_diagnostics_recorded < MAX_STDERR_DIAGNOSTICS) {
            const suffix = if (line.len > excerpt.len) " [truncated]" else "";
            const message = try std.fmt.allocPrint(
                self.allocator,
                "host stderr source={s}: {s}{s}",
                .{ self.diagnostic_source, excerpt, suffix },
            );
            defer self.allocator.free(message);
            try self.state.addDiagnostic(.host_stderr, .warning, message);
            self.stderr_diagnostics_recorded += 1;
            return;
        }
        if (!self.stderr_diagnostics_truncated) {
            const message = try std.fmt.allocPrint(
                self.allocator,
                "host stderr source={s}: additional stderr diagnostics suppressed after {d} lines",
                .{ self.diagnostic_source, MAX_STDERR_DIAGNOSTICS },
            );
            defer self.allocator.free(message);
            try self.state.addDiagnostic(.host_stderr, .warning, message);
            self.stderr_diagnostics_truncated = true;
        }
    }
};

fn waitMain(host: *HostProcess) void {
    host.term = host.child.wait(host.io) catch |err| {
        host.wait_err = err;
        host.wait_done.store(true, .seq_cst);
        return;
    };
    host.markExited();
    host.wait_done.store(true, .seq_cst);
}

const HostParserSink = struct {
    host: *HostProcess,

    pub fn onMessage(self: *HostParserSink, message: HostMessage) !void {
        try self.host.onMessage(message);
    }

    pub fn onDiagnostic(self: *HostParserSink, diagnostic: Diagnostic) !void {
        try self.host.onDiagnostic(diagnostic);
    }
};

fn readerMain(host: *HostProcess) void {
    var sink: HostParserSink = .{ .host = host };
    var buffer: [4096]u8 = undefined;
    while (true) {
        const file = host.stdout_file orelse break;
        const bytes_read = file.readStreaming(host.io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => {
                host.reader_err = err;
                break;
            },
        };
        if (bytes_read == 0) break;
        host.parser.feed(host.allocator, buffer[0..bytes_read], &sink) catch |err| {
            host.reader_err = err;
            break;
        };
    }
    host.parser.finish(host.allocator, &sink) catch |err| {
        host.reader_err = err;
    };
    if (host.wait_done.load(.seq_cst) and !host.shutdown_requested.load(.seq_cst)) host.markExited();
    host.reader_done.store(true, .seq_cst);
}

fn stderrMain(host: *HostProcess) void {
    var line_buffer = std.ArrayList(u8).empty;
    defer line_buffer.deinit(host.allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const file = host.stderr_file orelse break;
        const bytes_read = std.posix.read(file.handle, &buffer) catch |err| {
            host.stderr_err = err;
            break;
        };
        if (bytes_read == 0) break;
        for (buffer[0..bytes_read]) |byte| {
            if (byte == '\n') {
                host.onStderrLine(line_buffer.items) catch |err| {
                    host.stderr_err = err;
                    break;
                };
                line_buffer.clearRetainingCapacity();
            } else if (line_buffer.items.len < MAX_STDERR_LINE_BYTES * 2) {
                line_buffer.append(host.allocator, byte) catch |err| {
                    host.stderr_err = err;
                    break;
                };
            }
        }
        if (host.stderr_err != null) break;
    }
    if (line_buffer.items.len > 0) {
        host.onStderrLine(line_buffer.items) catch |err| {
            host.stderr_err = err;
        };
    }
    host.stderr_done.store(true, .seq_cst);
}

test "M6 host lifecycle starts once initializes becomes ready and shuts down" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_path = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "pi-m6-host-lifecycle-capture.jsonl",
    });
    defer allocator.free(capture_path);

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '%s\\n' \"$init\" > {s}; printf '{{\"type\":\"ready\"}}\\n'; while IFS= read -r line; do printf '%s\\n' \"$line\" >> {s}; case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; done",
        .{ capture_path, capture_path },
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m6-host-marker-lifecycle" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-m6-host-marker-lifecycle",
            .cwd = "/tmp",
            .fixture = "lifecycle",
        },
        .shutdown_timeout_ms = 500,
    });
    defer host.deinit();

    try host.waitForReady(500);
    try std.testing.expectEqual(@as(usize, 1), host.start_count);
    try host.shutdown();
    try std.testing.expect(host.hasShutdownComplete());

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try std.testing.expectEqualStrings(
        "{\"type\":\"initialize\",\"marker\":\"pi-m6-host-marker-lifecycle\",\"cwd\":\"/tmp\",\"fixture\":\"lifecycle\"}\n{\"type\":\"shutdown\"}\n",
        capture,
    );
}

test "process_jsonl host executes correlated tool calls and consumes repeated ids" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_path = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "pi-process-tool-call-capture.jsonl",
    });
    defer allocator.free(capture_path);

    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; printf '{{\"type\":\"ready\"}}\\n'; count=0; while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in " ++
            "*'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; " ++
            "*'\"toolCallId\":\"repeat\"'*) count=$((count+1)); printf '{{\"type\":\"tool_result\",\"toolCallId\":\"repeat\",\"content\":[{{\"type\":\"text\",\"text\":\"result-%s\"}}],\"details\":{{\"count\":%s}}}}\\n' \"$count\" \"$count\";; " ++
            "*'\"toolCallId\":\"fail\"'*) printf '{{\"type\":\"tool_error\",\"toolCallId\":\"fail\",\"message\":\"fixture failure\"}}\\n';; " ++
            "esac; done",
        .{capture_path},
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-process-tool-call" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-process-tool-call",
            .cwd = "/tmp",
            .fixture = "tool-call",
        },
        .shutdown_timeout_ms = 500,
    });
    defer host.deinit();

    try host.waitForReady(500);
    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"alpha\"}", .{});
    defer args.deinit();

    var first = try host.executeTool(allocator, "fixture.tool", "repeat", args.value, 500);
    defer first.deinit(allocator);
    try std.testing.expect(!first.is_error);
    try std.testing.expectEqualStrings("result-1", first.content[0].text.text);
    try std.testing.expectEqual(@as(i64, 1), first.details.?.object.get("count").?.integer);

    var second = try host.executeTool(allocator, "fixture.tool", "repeat", args.value, 500);
    defer second.deinit(allocator);
    try std.testing.expect(!second.is_error);
    try std.testing.expectEqualStrings("result-2", second.content[0].text.text);
    try std.testing.expectEqual(@as(i64, 2), second.details.?.object.get("count").?.integer);

    var failed = try host.executeTool(allocator, "fixture.tool", "fail", args.value, 500);
    defer failed.deinit(allocator);
    try std.testing.expect(failed.is_error);
    try std.testing.expectEqualStrings("fixture failure", failed.content[0].text.text);

    try host.shutdown();
    try std.testing.expect(host.hasShutdownComplete());

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"type\":\"tool_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"toolName\":\"fixture.tool\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "\"input\":{\"value\":\"alpha\"}") != null);
}

test "process_jsonl host keeps stderr and malformed stdout diagnostic-only while preserving tool result" {
    const allocator = std.testing.allocator;
    const script =
        "IFS= read -r init; " ++
        "printf 'stderr fixture log before ready\\n' >&2; " ++
        "printf 'not-json\\n'; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "while IFS= read -r line; do " ++
        "case \"$line\" in " ++
        "*'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; " ++
        "*'\"toolCallId\":\"robust-ok\"'*) " ++
        "printf '{\"type\":\"tool_result\",\"content\":[{\"type\":\"text\",\"text\":\"missing id must not win\"}]}\\n'; " ++
        "printf 'stderr fixture log during call\\n' >&2; " ++
        "printf '{\"type\":\"diagnostic\",\"category\":\"host_error\",\"severity\":\"warning\",\"message\":\"fixture diagnostic frame\"}\\n'; " ++
        "printf '{\"type\":\"tool_result\",\"toolCallId\":\"robust-ok\",\"content\":[{\"type\":\"text\",\"text\":\"declared result only\"}],\"details\":{\"ok\":true}}\\n';; " ++
        "esac; done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-process-jsonl-robust-noise" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .extension_path = "fixture/noisy-extension.js",
        .initialize = .{
            .marker = "pi-process-jsonl-robust-noise",
            .cwd = "/tmp",
            .fixture = "noisy-fixture",
        },
        .shutdown_timeout_ms = 500,
    });
    defer host.deinit();

    try host.waitForReady(500);
    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"alpha\"}", .{});
    defer args.deinit();

    var response = try host.executeTool(allocator, "fixture.noisy", "robust-ok", args.value, 500);
    defer response.deinit(allocator);
    try std.testing.expect(!response.is_error);
    try std.testing.expectEqualStrings("declared result only", response.content[0].text.text);
    try std.testing.expectEqual(true, response.details.?.object.get("ok").?.bool);

    try std.testing.expect(host.diagnosticCategoryCount(.malformed_json) >= 1);
    try std.testing.expect(host.diagnosticCategoryCount(.unsupported_message_type) >= 1);
    try std.testing.expect(host.diagnosticCategoryCount(.host_stderr) >= 1);
    try std.testing.expect(hostDiagnosticContains(host, .malformed_json, "source=fixture/noisy-extension.js"));
    try std.testing.expect(hostDiagnosticContains(host, .malformed_json, "phase=stdout_parser"));
    try std.testing.expect(hostDiagnosticContains(host, .malformed_json, "severity=error"));
    try std.testing.expect(hostDiagnosticContains(host, .malformed_json, "category=malformed_json"));
    try std.testing.expect(hostDiagnosticContains(host, .unsupported_message_type, "source=fixture/noisy-extension.js"));
    try std.testing.expect(hostDiagnosticContains(host, .unsupported_message_type, "phase=stdout_parser"));
    try std.testing.expect(hostDiagnosticContains(host, .unsupported_message_type, "severity=error"));
    try std.testing.expect(hostDiagnosticContains(host, .host_stderr, "fixture/noisy-extension.js"));
    try std.testing.expect(hostDiagnosticContains(host, .host_error, "fixture diagnostic frame"));
    try std.testing.expect(hostDiagnosticContains(host, .host_error, "source=fixture/noisy-extension.js"));
    try std.testing.expect(hostDiagnosticContains(host, .host_error, "phase=protocol"));
    try std.testing.expect(hostDiagnosticContains(host, .host_error, "severity=warning"));

    try host.shutdown();
    try std.testing.expect(host.hasShutdownComplete());
}

test "process_jsonl host times out unresponsive tool call and cleans child process" {
    const allocator = std.testing.allocator;
    const script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "while IFS= read -r line; do " ++
        "case \"$line\" in " ++
        "*'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; " ++
        "*'\"toolCallId\":\"slow-call\"'*) sleep 5;; " ++
        "esac; done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-process-jsonl-timeout" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .extension_path = "fixture/slow-extension.js",
        .initialize = .{
            .marker = "pi-process-jsonl-timeout",
            .cwd = "/tmp",
            .fixture = "slow-fixture",
        },
        .shutdown_timeout_ms = 50,
    });
    defer host.deinit();

    try host.waitForReady(500);
    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"slow\"}", .{});
    defer args.deinit();

    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    try std.testing.expectError(error.ToolExecutionTimedOut, host.executeTool(allocator, "fixture.slow", "slow-call", args.value, 50));
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 1500);
    try std.testing.expect(host.wait_done.load(.seq_cst));
    try std.testing.expect(host.reader_done.load(.seq_cst));
    try std.testing.expect(hostDiagnosticContains(host, .host_error, "timed out"));
    try std.testing.expect(hostDiagnosticContains(host, .host_error, "slow-call"));
}

test "process_jsonl host times out unresponsive extension event hook and rejects late response" {
    const allocator = std.testing.allocator;
    const script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "while IFS= read -r line; do " ++
        "case \"$line\" in " ++
        "*'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; " ++
        "*'\"extension_event\"'*) sleep 0.2; printf '{\"type\":\"extension_event_result\",\"eventId\":\"event-1-message_end\",\"result\":{\"late\":true}}\\n';; " ++
        "esac; done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-process-jsonl-hook-timeout" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .extension_path = "fixture/slow-hook.js",
        .initialize = .{
            .marker = "pi-process-jsonl-hook-timeout",
            .cwd = "/tmp",
            .fixture = "slow-hook-fixture",
        },
        .shutdown_timeout_ms = 50,
    });
    defer host.deinit();

    try host.waitForReady(500);
    host.mutex.lockUncancelable(std.testing.io);
    try host.state.registry.registerHook("message_end", "fixture/slow-hook.js");
    host.mutex.unlock(std.testing.io);
    try std.testing.expect(host.hasRegisteredHook("message_end"));

    var event = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"message_end\"}", .{});
    defer event.deinit();
    const start_ns = std.Io.Clock.now(.awake, std.testing.io).nanoseconds;
    const result = try host.invokeExtensionEvent(allocator, "message_end", event.value, 50);
    try std.testing.expect(result == null);
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds - start_ns, std.time.ns_per_ms);
    try std.testing.expect(elapsed_ms < 1500);
    try std.testing.expect(hostDiagnosticContains(host, .host_error, "extension hook dispatch timed out"));
    try std.testing.expect(hostDiagnosticContains(host, .host_error, "message_end"));
    try std.testing.expectEqual(@as(usize, 0), host.state.pending_extension_event_ids.count());
    std.Io.sleep(std.testing.io, .fromMilliseconds(300), .awake) catch {};
    try std.testing.expect(hostDiagnosticContains(host, .host_error, "stale or unknown extension event response"));
}

test "process_jsonl host reports EOF during pending tool call without successful result" {
    const allocator = std.testing.allocator;
    const script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "while IFS= read -r line; do " ++
        "case \"$line\" in " ++
        "*'\"toolCallId\":\"eof-call\"'*) exit 0;; " ++
        "esac; done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-process-jsonl-eof" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .extension_path = "fixture/eof-extension.js",
        .initialize = .{
            .marker = "pi-process-jsonl-eof",
            .cwd = "/tmp",
            .fixture = "eof-fixture",
        },
        .shutdown_timeout_ms = 50,
    });
    defer host.deinit();

    try host.waitForReady(500);
    var args = try std.json.parseFromSlice(std.json.Value, allocator, "{\"value\":\"eof\"}", .{});
    defer args.deinit();

    try std.testing.expectError(error.ExtensionHostClosed, host.executeTool(allocator, "fixture.eof", "eof-call", args.value, 500));
    try std.testing.expectEqual(@as(usize, 0), host.pendingCount());
    try std.testing.expect(hostDiagnosticContains(host, .host_exit, "eof-call"));
    try std.testing.expect(hostDiagnosticContains(host, .host_exit, "fixture/eof-extension.js"));
}

test "M6 host lifecycle contains unexpected exit without respawn and clears pending requests" {
    const allocator = std.testing.allocator;
    const script =
        "printf '{\"type\":\"ready\"}\\n'; printf '{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true}\\n'; exit 3";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m6-host-marker-crash" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-m6-host-marker-crash",
            .cwd = "/tmp",
            .fixture = "crash",
        },
        .shutdown_timeout_ms = 500,
    });
    defer host.deinit();

    try host.waitForReady(500);
    var elapsed: u64 = 0;
    while (!host.wait_done.load(.seq_cst) and elapsed <= 500) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(host.wait_done.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), host.start_count);
    try std.testing.expectEqual(@as(usize, 0), host.pendingCount());
    try std.testing.expect(host.diagnosticCount() >= 1);
    while (!host.reader_done.load(.seq_cst) and elapsed <= 1000) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expect(host.reader_done.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), host.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), host.diagnosticCategoryCount(.host_exit));
}

test "M6 host lifecycle reports startup failure deterministically" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{ "/tmp/pi-m6-missing-host-runtime", "--pi-m6-host-marker-startup-failure" };
    const result = HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-m6-host-marker-startup-failure",
            .cwd = "/tmp",
            .fixture = "startup-failure",
        },
        .shutdown_timeout_ms = 50,
    });
    try std.testing.expectError(error.FileNotFound, result);

    var diagnostic = try startupFailureDiagnostic(allocator);
    defer diagnostic.deinit(allocator);
    try std.testing.expectEqual(DiagnosticCategory.startup_failure, diagnostic.category);
    try std.testing.expectEqualStrings("extension host failed to start", diagnostic.message);
}

test "M6 host lifecycle kills and reaps unresponsive shutdown" {
    const allocator = std.testing.allocator;
    const script = "IFS= read -r init; printf '{\"type\":\"ready\"}\\n'; while true; do sleep 1; done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m6-host-marker-interrupted-shutdown" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-m6-host-marker-interrupted-shutdown",
            .cwd = "/tmp",
            .fixture = "interrupted-shutdown",
        },
        .shutdown_timeout_ms = 50,
    });
    defer host.deinit();

    try host.waitForReady(500);
    try host.shutdown();
    try std.testing.expect(host.wait_done.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 1), host.start_count);
}

test "M6 host lifecycle cleans up after shutdown write failure" {
    const allocator = std.testing.allocator;
    const script =
        "IFS= read -r init; exec 0<&-; printf '{\"type\":\"ready\"}\\n'; printf '{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true}\\n'; while true; do sleep 1; done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m6-host-marker-shutdown-write-failure" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-m6-host-marker-shutdown-write-failure",
            .cwd = "/tmp",
            .fixture = "shutdown-write-failure",
        },
        .shutdown_timeout_ms = 50,
    });
    defer host.deinit();

    try host.waitForReady(500);
    var elapsed: u64 = 0;
    while (host.pendingCount() == 0 and elapsed <= 500) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), host.pendingCount());
    var saw_write_error = false;
    host.shutdown() catch |err| {
        try std.testing.expectEqual(error.BrokenPipe, err);
        saw_write_error = true;
    };
    try std.testing.expect(saw_write_error);
    try std.testing.expect(host.wait_done.load(.seq_cst));
    try std.testing.expect(host.wait_thread == null);
    try std.testing.expect(host.reader_thread == null);
    try std.testing.expect(host.stdin_file == null);
    try std.testing.expect(host.stdout_file == null);
    try std.testing.expectEqual(@as(usize, 0), host.pendingCount());
}

test "M11 host process drains live register_* frames into observable runtime registry" {
    const allocator = std.testing.allocator;
    const script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "printf '{\"type\":\"register_tool\",\"name\":\"say-hello\",\"label\":\"Say Hello\",\"description\":\"Greets the world\",\"extensionPath\":\"fixture/extension.ts\"}\\n'; " ++
        "printf '{\"type\":\"register_command\",\"name\":\"say-hello\",\"description\":\"Slash\",\"extensionPath\":\"fixture/extension.ts\"}\\n'; " ++
        "printf '{\"type\":\"register_shortcut\",\"shortcut\":\"ctrl+h\",\"command\":\"say-hello\",\"extensionPath\":\"fixture/extension.ts\"}\\n'; " ++
        "printf '{\"type\":\"register_flag\",\"name\":\"plan\",\"valueType\":\"boolean\",\"default\":true,\"extensionPath\":\"fixture/extension.ts\"}\\n'; " ++
        "printf '{\"type\":\"register_flag\",\"name\":\"model-alias\",\"valueType\":\"string\",\"default\":\"claude-haiku\",\"extensionPath\":\"fixture/extension.ts\"}\\n'; " ++
        "printf '{\"type\":\"register_provider\",\"name\":\"fake-provider\",\"displayName\":\"Fake\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"fake-1\",\"name\":\"Fake 1\"}],\"extensionPath\":\"fixture/extension.ts\"}\\n'; " ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m11-extension-fixture" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-m11-extension-fixture",
            .cwd = "/tmp",
            .fixture = "registration-fixture",
        },
        .shutdown_timeout_ms = 500,
        .approved_capabilities = enforcement.CANONICAL_GRANTS[0..],
    });
    defer host.deinit();

    try host.waitForReady(500);

    // Wait for all 6 registration frames to drain.
    var elapsed: u64 = 0;
    while (host.registryFramesApplied() < 6 and elapsed <= 1000) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 6), host.registryFramesApplied());

    // Apply CLI flag values into the live registry, mirroring the
    // runtime step that hands parsed --<flag> values back to the host
    // after extension load.
    try host.applyCliFlagValues(&.{
        .{ .name = "plan", .value = .{ .boolean = true } },
        .{ .name = "model-alias", .value = .{ .string = "claude-opus" } },
    });

    const snapshot = try host.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"say-hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"fake-provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"shortcut\":\"ctrl+h\"") != null);
    // Resolved CLI value must appear in the snapshot value field.
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"value\":\"claude-opus\"") != null);
    // The default must still be visible alongside the resolved value.
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"default\":\"claude-haiku\"") != null);

    try host.shutdown();
    try std.testing.expect(host.hasShutdownComplete());
}

test "live host dynamic provider re-registration and unregister ordering has no stale model" {
    const allocator = std.testing.allocator;
    const script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "printf '{\"type\":\"register_provider\",\"name\":\"dynamic-provider\",\"displayName\":\"Dynamic\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"first\",\"name\":\"First\"}],\"extensionPath\":\"fixture/extension.ts\"}\\n'; " ++
        "printf '{\"type\":\"unregister_provider\",\"name\":\"dynamic-provider\"}\\n'; " ++
        "printf '{\"type\":\"register_provider\",\"name\":\"dynamic-provider\",\"displayName\":\"Dynamic\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"second\",\"name\":\"Second\"}],\"extensionPath\":\"fixture/extension.ts\"}\\n'; " ++
        "while IFS= read -r line; do case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-m11-reregister-fixture" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-m11-reregister-fixture",
            .cwd = "/tmp",
            .fixture = "registration-reregister-fixture",
        },
        .shutdown_timeout_ms = 500,
        .approved_capabilities = enforcement.CANONICAL_GRANTS[0..],
    });
    defer host.deinit();

    try host.waitForReady(500);
    var elapsed: u64 = 0;
    while (host.registryFramesApplied() < 3 and elapsed <= 1000) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 3), host.registryFramesApplied());

    const snapshot = try host.snapshotRegistryJson(allocator);
    defer allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"name\":\"dynamic-provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"id\":\"second\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"id\":\"first\"") == null);

    try host.shutdown();
    try std.testing.expect(host.hasShutdownComplete());
}

test "event_emission: sendExtensionEventFrame writes JSONL frames to host stdin" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const capture_path = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "pi-event-emission-capture.jsonl",
    });
    defer allocator.free(capture_path);

    // Shell script host that captures every line written to its stdin after ready
    const script = try std.fmt.allocPrint(
        allocator,
        "IFS= read -r init; " ++
            "printf '{{\"type\":\"ready\"}}\\n'; " ++
            "while IFS= read -r line; do " ++
            "printf '%s\\n' \"$line\" >> {s}; " ++
            "case \"$line\" in *'\"shutdown\"'*) printf '{{\"type\":\"shutdown_complete\"}}\\n'; exit 0;; esac; " ++
            "done",
        .{capture_path},
    );
    defer allocator.free(script);
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-event-emission-test" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-event-emission-test",
            .cwd = "/tmp",
            .fixture = "event-emission",
        },
        .shutdown_timeout_ms = 500,
    });
    defer host.deinit();
    try host.waitForReady(500);

    // Send representative extension event frames covering the major event types
    host.sendExtensionEventFrame("{\"type\":\"agent_start\"}");
    host.sendExtensionEventFrame("{\"type\":\"agent_end\",\"messages\":[]}");
    host.sendExtensionEventFrame("{\"type\":\"turn_start\"}");
    host.sendExtensionEventFrame("{\"type\":\"turn_end\",\"message\":{}}");
    host.sendExtensionEventFrame("{\"type\":\"message_start\",\"message\":{\"role\":\"user\"}}");
    host.sendExtensionEventFrame("{\"type\":\"message_end\",\"message\":{\"role\":\"user\"}}");
    host.sendExtensionEventFrame("{\"type\":\"tool_call\",\"toolCallId\":\"c1\",\"toolName\":\"bash\",\"input\":{}}");
    host.sendExtensionEventFrame("{\"type\":\"tool_result\",\"toolCallId\":\"c1\",\"toolName\":\"bash\",\"input\":{},\"content\":[],\"isError\":false}");
    host.sendExtensionEventFrame("{\"type\":\"model_select\",\"model\":{\"id\":\"m\"},\"source\":\"set\"}");
    host.sendExtensionEventFrame("{\"type\":\"thinking_level_select\",\"level\":\"medium\",\"previousLevel\":\"off\"}");
    host.sendExtensionEventFrame("{\"type\":\"input\",\"text\":\"hello\",\"source\":\"rpc\"}");

    // Small delay to allow the shell script to flush writes to the capture file
    var elapsed: u64 = 0;
    while (elapsed <= 200) : (elapsed += 10) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
    }

    try host.shutdown();
    try std.testing.expect(host.hasShutdownComplete());

    const capture = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, capture_path, allocator, .unlimited);
    defer allocator.free(capture);

    // Verify all event types were written to the extension host stdin
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"agent_start\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"agent_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"turn_start\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"turn_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"message_start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"message_end\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"tool_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"tool_result\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"model_select\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"thinking_level_select\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture, "{\"type\":\"input\"") != null);

    // Verify each frame is on its own line (JSONL format)
    var lines = std.mem.splitScalar(u8, capture, '\n');
    var line_count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        // Each non-empty line must be valid JSON starting with {
        try std.testing.expect(line[0] == '{');
        line_count += 1;
    }
    // Should have at least 11 event frames plus the shutdown frame
    try std.testing.expect(line_count >= 11);
}

test "event_emission: sendExtensionEventFrame does not write when shutdown is requested" {
    const allocator = std.testing.allocator;

    // Host that captures stdin and runs for a bit
    const script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "while IFS= read -r line; do " ++
        "case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; " ++
        "done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-event-emission-shutdown-test" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-event-emission-shutdown-test",
            .cwd = "/tmp",
            .fixture = "shutdown-guard",
        },
        .shutdown_timeout_ms = 500,
    });
    defer host.deinit();
    try host.waitForReady(500);
    try host.shutdown();

    // After shutdown, sendExtensionEventFrame must not block or crash.
    // The shutdown_requested flag prevents writes.
    host.sendExtensionEventFrame("{\"type\":\"agent_start\"}");
    host.sendExtensionEventFrame("{\"type\":\"agent_end\",\"messages\":[]}");
    // No assertion needed: if the above doesn't hang or crash, the test passes.
}

test "event_emission: sendExtensionEventFrame is non-blocking when pipe buffer is full" {
    const allocator = std.testing.allocator;

    // Host that reads stdin VERY slowly (sleeps before each read) to fill the pipe buffer
    const script =
        "IFS= read -r init; " ++
        "printf '{\"type\":\"ready\"}\\n'; " ++
        "while IFS= read -r line; do " ++
        "sleep 10; " ++
        "case \"$line\" in *'\"shutdown\"'*) printf '{\"type\":\"shutdown_complete\"}\\n'; exit 0;; esac; " ++
        "done";
    const argv = [_][]const u8{ "/bin/sh", "-c", script, "pi-event-emission-full-pipe-test" };
    var host = try HostProcess.start(allocator, std.testing.io, .{
        .argv = &argv,
        .initialize = .{
            .marker = "pi-event-emission-full-pipe-test",
            .cwd = "/tmp",
            .fixture = "full-pipe",
        },
        .shutdown_timeout_ms = 200,
    });
    defer host.deinit();
    try host.waitForReady(500);

    // Flood the pipe with many large frames to fill the 64KB buffer.
    // Each call must return immediately (O_NONBLOCK drops writes on full pipe).
    var i: usize = 0;
    const large_payload = "x" ** 1024; // 1KB per frame
    while (i < 100) : (i += 1) {
        host.sendExtensionEventFrame(large_payload);
    }
    // If we reach here without blocking, the non-blocking behavior is confirmed.
    // Shut down the host (which will kill the slow-reading process).
    try host.shutdown();
}

const EXTENSION_HOST_PROTOCOL_FUZZ_SMOKE_SEED: u64 = 0x5eed_4578_0000_0005;

test "VAL-REFACTOR-012 deterministic extension host UI protocol fuzz smoke" {
    const allocator = std.testing.allocator;

    const body =
        "{\"type\":\"extension_ui_request\",\"id\":\"before-ready\",\"method\":\"input\",\"responseRequired\":true}\n" ++
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"select-1\",\"method\":\"select\",\"responseRequired\":true,\"payload\":{\"title\":\"Pick\",\"options\":[\"a\",\"b\"],\"timeout\":25}}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"unknown-ui\",\"method\":\"unknownUi\",\"payload\":{\"unknown\":{\"nested\":true}}}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"top-level-payload\",\"method\":\"setStatus\",\"statusKey\":\"guard\",\"statusText\":\"ok\",\"unexpected\":42}\n" ++
        "not-json\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"partial\"";

    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    feedExtensionHostFuzzChunks(allocator, &parser, body, &state) catch |err| {
        reportExtensionHostProtocolFuzzFailure(EXTENSION_HOST_PROTOCOL_FUZZ_SMOKE_SEED, "chunked-request-malformed-unknown-payload", body);
        return err;
    };
    parser.finish(allocator, &state) catch |err| {
        reportExtensionHostProtocolFuzzFailure(EXTENSION_HOST_PROTOCOL_FUZZ_SMOKE_SEED, "finish-incomplete-frame", body);
        return err;
    };

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 3), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount());
    try std.testing.expectEqualStrings("select-1", state.ui_requests.items[0].id);
    try std.testing.expectEqualStrings("unknownUi", state.ui_requests.items[1].method);
    try std.testing.expect(std.mem.indexOf(u8, state.ui_requests.items[2].payload_json, "\"unexpected\":42") != null);
    try std.testing.expectEqual(@as(usize, 3), state.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticCategory.host_error, state.diagnostics.items[0].category);
    try std.testing.expectEqual(DiagnosticCategory.malformed_json, state.diagnostics.items[1].category);
    try std.testing.expectEqual(DiagnosticCategory.incomplete_frame, state.diagnostics.items[2].category);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    writeExtensionUiResponseFrame(allocator, &out.writer, "select-1", "{\"cancelled\":true}") catch |err| {
        reportExtensionHostProtocolFuzzFailure(EXTENSION_HOST_PROTOCOL_FUZZ_SMOKE_SEED, "response-cancel-envelope", "{\"cancelled\":true}");
        return err;
    };
    try std.testing.expectEqualStrings(
        "{\"type\":\"extension_ui_response\",\"id\":\"select-1\",\"payload\":{\"cancelled\":true}}\n",
        out.written(),
    );
}

fn hostDiagnosticContains(host: *HostProcess, category: DiagnosticCategory, needle: []const u8) bool {
    host.mutex.lockUncancelable(host.io);
    defer host.mutex.unlock(host.io);
    for (host.state.diagnostics.items) |diagnostic| {
        if (diagnostic.category == category and std.mem.indexOf(u8, diagnostic.message, needle) != null) return true;
    }
    return false;
}

fn feedExtensionHostFuzzChunks(
    allocator: std.mem.Allocator,
    parser: *JsonlFrameParser,
    body: []const u8,
    state: *ProtocolState,
) !void {
    var prng = std.Random.DefaultPrng.init(EXTENSION_HOST_PROTOCOL_FUZZ_SMOKE_SEED);
    const random = prng.random();
    var offset: usize = 0;
    while (offset < body.len) {
        const remaining = body.len - offset;
        const len = @min(remaining, random.intRangeAtMost(usize, 1, 17));
        try parser.feed(allocator, body[offset .. offset + len], state);
        offset += len;
    }
}

fn reportExtensionHostProtocolFuzzFailure(seed: u64, label: []const u8, input: []const u8) void {
    std.debug.print("Extension host UI protocol fuzz smoke failure seed=0x{x} case={s} minimized_input={s}", .{
        seed,
        label,
        input,
    });
}
