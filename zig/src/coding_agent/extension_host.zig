const std = @import("std");

pub const HOST_MARKER_ENV = "PI_M6_EXTENSION_HOST_MARKER";

pub const DiagnosticCategory = enum {
    blank_frame,
    malformed_json,
    non_object_frame,
    unsupported_message_type,
    duplicate_ready,
    duplicate_pending_request,
    incomplete_frame,
    startup_failure,
    host_error,
    host_exit,

    pub fn jsonName(self: DiagnosticCategory) []const u8 {
        return switch (self) {
            .blank_frame => "blank_frame",
            .malformed_json => "malformed_json",
            .non_object_frame => "non_object_frame",
            .unsupported_message_type => "unsupported_message_type",
            .duplicate_ready => "duplicate_ready",
            .duplicate_pending_request => "duplicate_pending_request",
            .incomplete_frame => "incomplete_frame",
            .startup_failure => "startup_failure",
            .host_error => "host_error",
            .host_exit => "host_exit",
        };
    }
};

pub const DiagnosticSeverity = enum {
    info,
    warning,
    @"error",

    pub fn jsonName(self: DiagnosticSeverity) []const u8 {
        return switch (self) {
            .info => "info",
            .warning => "warning",
            .@"error" => "error",
        };
    }
};

pub const Diagnostic = struct {
    category: DiagnosticCategory,
    severity: DiagnosticSeverity,
    message: []u8,

    pub fn clone(allocator: std.mem.Allocator, diagnostic: Diagnostic) !Diagnostic {
        return .{
            .category = diagnostic.category,
            .severity = diagnostic.severity,
            .message = try allocator.dupe(u8, diagnostic.message),
        };
    }

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        self.* = undefined;
    }
};

pub const ExtensionUiRequest = struct {
    id: []u8,
    method: []u8,
    response_required: bool = false,
    payload_json: []u8,

    pub fn clone(allocator: std.mem.Allocator, request: ExtensionUiRequest) !ExtensionUiRequest {
        return .{
            .id = try allocator.dupe(u8, request.id),
            .method = try allocator.dupe(u8, request.method),
            .response_required = request.response_required,
            .payload_json = try allocator.dupe(u8, request.payload_json),
        };
    }

    pub fn deinit(self: *ExtensionUiRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.method);
        allocator.free(self.payload_json);
        self.* = undefined;
    }
};

pub const HostMessage = union(enum) {
    ready,
    diagnostic: Diagnostic,
    extension_ui_request: ExtensionUiRequest,
    shutdown_complete,
    error_message: Diagnostic,

    pub fn deinit(self: *HostMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .diagnostic => |*diagnostic| diagnostic.deinit(allocator),
            .extension_ui_request => |*request| request.deinit(allocator),
            .error_message => |*diagnostic| diagnostic.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

pub const JsonlFrameParser = struct {
    buffer: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *JsonlFrameParser, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.* = undefined;
    }

    pub fn feed(self: *JsonlFrameParser, allocator: std.mem.Allocator, bytes: []const u8, sink: anytype) !void {
        for (bytes) |byte| {
            if (byte == '\n') {
                try self.processLine(allocator, self.buffer.items, sink);
                self.buffer.clearRetainingCapacity();
            } else {
                try self.buffer.append(allocator, byte);
            }
        }
    }

    pub fn finish(self: *JsonlFrameParser, allocator: std.mem.Allocator, sink: anytype) !void {
        const trimmed = std.mem.trim(u8, self.buffer.items, " \t\r\n");
        if (trimmed.len != 0) {
            try sink.onDiagnostic(.{
                .category = .incomplete_frame,
                .severity = .@"error",
                .message = try allocator.dupe(u8, "host stdout ended with an incomplete JSONL frame"),
            });
        }
        self.buffer.clearRetainingCapacity();
    }

    fn processLine(self: *JsonlFrameParser, allocator: std.mem.Allocator, raw_line: []const u8, sink: anytype) !void {
        _ = self;
        const line = stripTrailingCarriageReturn(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            try sink.onDiagnostic(.{
                .category = .blank_frame,
                .severity = .warning,
                .message = try allocator.dupe(u8, "host emitted a blank JSONL frame"),
            });
            return;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
            try sink.onDiagnostic(.{
                .category = .malformed_json,
                .severity = .@"error",
                .message = try allocator.dupe(u8, "host emitted malformed JSON"),
            });
            return;
        };
        defer parsed.deinit();

        const object = switch (parsed.value) {
            .object => |object| object,
            else => {
                try sink.onDiagnostic(.{
                    .category = .non_object_frame,
                    .severity = .@"error",
                    .message = try allocator.dupe(u8, "host frame must be a JSON object"),
                });
                return;
            },
        };

        var message = parseObjectMessage(allocator, object) catch |err| switch (err) {
            error.UnsupportedHostMessageType => {
                try sink.onDiagnostic(.{
                    .category = .unsupported_message_type,
                    .severity = .@"error",
                    .message = try allocator.dupe(u8, "host emitted an unsupported message type"),
                });
                return;
            },
            else => return err,
        };
        defer message.deinit(allocator);
        try sink.onMessage(message);
    }
};

pub const ProtocolState = struct {
    allocator: std.mem.Allocator,
    ready_seen: bool = false,
    shutdown_complete_seen: bool = false,
    pending_request_ids: std.StringHashMap(void),
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    ui_requests: std.ArrayList(ExtensionUiRequest) = .empty,

    pub fn init(allocator: std.mem.Allocator) ProtocolState {
        return .{
            .allocator = allocator,
            .pending_request_ids = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *ProtocolState) void {
        var pending_iterator = self.pending_request_ids.iterator();
        while (pending_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_request_ids.deinit();

        for (self.diagnostics.items) |*diagnostic| diagnostic.deinit(self.allocator);
        self.diagnostics.deinit(self.allocator);
        for (self.ui_requests.items) |*request| request.deinit(self.allocator);
        self.ui_requests.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn onMessage(self: *ProtocolState, message: HostMessage) !void {
        switch (message) {
            .ready => {
                if (self.ready_seen) {
                    try self.addDiagnostic(.duplicate_ready, .@"error", "host emitted duplicate readiness");
                    return;
                }
                self.ready_seen = true;
            },
            .diagnostic => |diagnostic| try self.diagnostics.append(self.allocator, try Diagnostic.clone(self.allocator, diagnostic)),
            .error_message => |diagnostic| try self.diagnostics.append(self.allocator, try Diagnostic.clone(self.allocator, diagnostic)),
            .extension_ui_request => |request| {
                if (!self.ready_seen) {
                    try self.addDiagnostic(.host_error, .@"error", "host emitted UI request before readiness");
                    return;
                }
                if (request.response_required) {
                    if (self.pending_request_ids.contains(request.id)) {
                        try self.addDiagnostic(.duplicate_pending_request, .@"error", "host emitted duplicate pending request id");
                        return;
                    }
                    try self.pending_request_ids.put(try self.allocator.dupe(u8, request.id), {});
                }
                try self.ui_requests.append(self.allocator, try ExtensionUiRequest.clone(self.allocator, request));
            },
            .shutdown_complete => self.shutdown_complete_seen = true,
        }
    }

    pub fn onDiagnostic(self: *ProtocolState, diagnostic: Diagnostic) !void {
        try self.diagnostics.append(self.allocator, diagnostic);
    }

    pub fn clearPendingRequests(self: *ProtocolState) void {
        var pending_iterator = self.pending_request_ids.iterator();
        while (pending_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending_request_ids.clearRetainingCapacity();
    }

    pub fn pendingCount(self: *const ProtocolState) usize {
        return self.pending_request_ids.count();
    }

    fn addDiagnostic(self: *ProtocolState, category: DiagnosticCategory, severity: DiagnosticSeverity, message: []const u8) !void {
        try self.diagnostics.append(self.allocator, .{
            .category = category,
            .severity = severity,
            .message = try self.allocator.dupe(u8, message),
        });
    }
};

pub fn startupFailureDiagnostic(allocator: std.mem.Allocator) !Diagnostic {
    return .{
        .category = .startup_failure,
        .severity = .@"error",
        .message = try allocator.dupe(u8, "extension host failed to start"),
    };
}

pub const InitializeFrame = struct {
    marker: []const u8,
    cwd: []const u8,
    fixture: []const u8,
};

pub const HostProcessOptions = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    initialize: InitializeFrame,
    shutdown_timeout_ms: u64 = 1000,
};

pub const HostProcess = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    stdin_file: ?std.Io.File,
    stdout_file: ?std.Io.File,
    parser: JsonlFrameParser = .{},
    state: ProtocolState,
    mutex: std.Io.Mutex = .init,
    wait_thread: ?std.Thread = null,
    reader_thread: ?std.Thread = null,
    wait_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reader_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    start_count: usize = 1,
    shutdown_timeout_ms: u64,
    exit_recorded: bool = false,
    wait_err: ?anyerror = null,
    reader_err: ?anyerror = null,
    term: ?std.process.Child.Term = null,

    pub fn start(allocator: std.mem.Allocator, io: std.Io, options: HostProcessOptions) !*HostProcess {
        const host = try allocator.create(HostProcess);
        errdefer allocator.destroy(host);

        var child = try std.process.spawn(io, .{
            .argv = options.argv,
            .cwd = if (options.cwd) |cwd| .{ .path = cwd } else .inherit,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        });
        errdefer if (child.id != null) child.kill(io);

        const stdin_file = child.stdin.?;
        child.stdin = null;
        const stdout_file = child.stdout.?;
        child.stdout = null;

        host.* = .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .stdin_file = stdin_file,
            .stdout_file = stdout_file,
            .state = ProtocolState.init(allocator),
            .shutdown_timeout_ms = options.shutdown_timeout_ms,
        };

        try host.sendInitialize(options.initialize);
        host.wait_thread = try std.Thread.spawn(.{}, waitMain, .{host});
        host.reader_thread = try std.Thread.spawn(.{}, readerMain, .{host});
        return host;
    }

    pub fn deinit(self: *HostProcess) void {
        self.shutdown() catch {};
        self.parser.deinit(self.allocator);
        self.state.deinit();
        self.allocator.destroy(self);
    }

    pub fn shutdown(self: *HostProcess) !void {
        if (!self.shutdown_requested.swap(true, .seq_cst)) {
            if (self.stdin_file) |file| {
                var shutdown_line: std.Io.Writer.Allocating = .init(self.allocator);
                defer shutdown_line.deinit();
                try writeShutdownFrame(&shutdown_line.writer);
                try file.writeStreamingAll(self.io, shutdown_line.written());
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
        if (self.stdin_file) |file| {
            file.close(self.io);
            self.stdin_file = null;
        }
        if (self.stdout_file) |file| {
            file.close(self.io);
            self.stdout_file = null;
        }
    }

    pub fn waitForReady(self: *HostProcess, timeout_ms: u64) !void {
        var elapsed: u64 = 0;
        while (elapsed <= timeout_ms) : (elapsed += 10) {
            self.mutex.lockUncancelable(self.io);
            const ready = self.state.ready_seen;
            self.mutex.unlock(self.io);
            if (ready) return;
            if (self.wait_done.load(.seq_cst)) break;
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

    pub fn hasShutdownComplete(self: *HostProcess) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.state.shutdown_complete_seen;
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
        try self.state.onMessage(message);
    }

    fn onDiagnostic(self: *HostProcess, diagnostic: Diagnostic) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.state.onDiagnostic(diagnostic);
    }

    fn markExited(self: *HostProcess) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state.clearPendingRequests();
        if (!self.shutdown_requested.load(.seq_cst) and !self.exit_recorded) {
            self.state.addDiagnostic(.host_exit, .@"error", "extension host exited before shutdown") catch {};
        }
        self.exit_recorded = true;
    }

    fn killProcessGroup(self: *HostProcess) void {
        if (self.child.id) |pid| {
            std.posix.kill(-pid, .TERM) catch {};
            std.posix.kill(-pid, .KILL) catch {};
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

fn readerMain(host: *HostProcess) void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const file = host.stdout_file orelse break;
        const bytes_read = std.posix.read(file.handle, &buffer) catch |err| {
            host.reader_err = err;
            break;
        };
        if (bytes_read == 0) break;
        host.parser.feed(host.allocator, buffer[0..bytes_read], host) catch |err| {
            host.reader_err = err;
            break;
        };
    }
    host.parser.finish(host.allocator, host) catch |err| {
        host.reader_err = err;
    };
    if (host.wait_done.load(.seq_cst) and !host.shutdown_requested.load(.seq_cst)) host.markExited();
    host.reader_done.store(true, .seq_cst);
}

pub fn writeInitializeFrame(allocator: std.mem.Allocator, writer: *std.Io.Writer, frame: InitializeFrame) !void {
    try writer.writeAll("{\"type\":\"initialize\",\"marker\":");
    try writeJsonString(allocator, writer, frame.marker);
    try writer.writeAll(",\"cwd\":");
    try writeJsonString(allocator, writer, frame.cwd);
    try writer.writeAll(",\"fixture\":");
    try writeJsonString(allocator, writer, frame.fixture);
    try writer.writeAll("}\n");
}

pub fn writeExtensionUiResponseFrame(allocator: std.mem.Allocator, writer: *std.Io.Writer, id: []const u8, payload_json: []const u8) !void {
    try writer.writeAll("{\"type\":\"extension_ui_response\",\"id\":");
    try writeJsonString(allocator, writer, id);
    try writer.writeAll(",\"payload\":");
    try writer.writeAll(payload_json);
    try writer.writeAll("}\n");
}

pub fn writeShutdownFrame(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"type\":\"shutdown\"}\n");
}

fn parseObjectMessage(allocator: std.mem.Allocator, object: std.json.ObjectMap) !HostMessage {
    const type_name = optionalString(object, "type") orelse return error.UnsupportedHostMessageType;
    if (std.mem.eql(u8, type_name, "ready")) return .ready;
    if (std.mem.eql(u8, type_name, "shutdown_complete")) return .shutdown_complete;
    if (std.mem.eql(u8, type_name, "diagnostic")) {
        return .{ .diagnostic = try parseDiagnostic(allocator, object, .warning) };
    }
    if (std.mem.eql(u8, type_name, "error")) {
        return .{ .error_message = try parseDiagnostic(allocator, object, .@"error") };
    }
    if (std.mem.eql(u8, type_name, "extension_ui_request")) {
        const id = optionalString(object, "id") orelse return error.UnsupportedHostMessageType;
        const method = optionalString(object, "method") orelse return error.UnsupportedHostMessageType;
        const payload_json = try allocator.dupe(u8, "{}");
        errdefer allocator.free(payload_json);
        return .{ .extension_ui_request = .{
            .id = try allocator.dupe(u8, id),
            .method = try allocator.dupe(u8, method),
            .response_required = optionalBool(object, "responseRequired") orelse false,
            .payload_json = payload_json,
        } };
    }
    return error.UnsupportedHostMessageType;
}

fn parseDiagnostic(allocator: std.mem.Allocator, object: std.json.ObjectMap, default_severity: DiagnosticSeverity) !Diagnostic {
    return .{
        .category = parseCategory(optionalString(object, "category")) orelse .host_error,
        .severity = parseSeverity(optionalString(object, "severity")) orelse default_severity,
        .message = try allocator.dupe(u8, optionalString(object, "message") orelse "host diagnostic"),
    };
}

fn optionalString(object: std.json.ObjectMap, field: []const u8) ?[]const u8 {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn optionalBool(object: std.json.ObjectMap, field: []const u8) ?bool {
    const value = object.get(field) orelse return null;
    return switch (value) {
        .bool => |flag| flag,
        else => null,
    };
}

fn parseCategory(name: ?[]const u8) ?DiagnosticCategory {
    const text = name orelse return null;
    inline for (@typeInfo(DiagnosticCategory).@"enum".fields) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(DiagnosticCategory, field.name);
    }
    return null;
}

fn parseSeverity(name: ?[]const u8) ?DiagnosticSeverity {
    const text = name orelse return null;
    if (std.mem.eql(u8, text, "info")) return .info;
    if (std.mem.eql(u8, text, "warning")) return .warning;
    if (std.mem.eql(u8, text, "error")) return .@"error";
    return null;
}

fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn writeJsonString(allocator: std.mem.Allocator, writer: *std.Io.Writer, value: []const u8) !void {
    const encoded = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    try writer.writeAll(encoded);
}

test "M6 host protocol parses ordered JSONL frames" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    try parser.feed(allocator, "{\"type\":\"diagnostic\",\"category\":\"host_error\",\"severity\":\"warning\",\"message\":\"fixture warning\"}\n{\"type\":\"rea", &state);
    try parser.feed(allocator, "dy\"}\r\n{\"type\":\"extension_ui_request\",\"id\":\"a\",\"method\":\"select\",\"responseRequired\":true}\n{\"type\":\"extension_ui_request\",\"id\":\"b\",\"method\":\"notify\"}\n", &state);
    try parser.finish(allocator, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 1), state.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 2), state.ui_requests.items.len);
    try std.testing.expectEqualStrings("a", state.ui_requests.items[0].id);
    try std.testing.expectEqualStrings("b", state.ui_requests.items[1].id);
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount());
}

test "M6 host protocol contains malformed unsupported duplicate and incomplete frames" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    try parser.feed(allocator, "   \nnot-json\n[]\n{\"type\":\"unknown\"}\n", &state);
    try parser.feed(allocator, "{\"type\":\"ready\"}\n{\"type\":\"ready\"}\n", &state);
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"dup\",\"method\":\"input\",\"responseRequired\":true}\n", &state);
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"dup\",\"method\":\"input\",\"responseRequired\":true}\n", &state);
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\"", &state);
    try parser.finish(allocator, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 1), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 7), state.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticCategory.blank_frame, state.diagnostics.items[0].category);
    try std.testing.expectEqual(DiagnosticCategory.malformed_json, state.diagnostics.items[1].category);
    try std.testing.expectEqual(DiagnosticCategory.non_object_frame, state.diagnostics.items[2].category);
    try std.testing.expectEqual(DiagnosticCategory.unsupported_message_type, state.diagnostics.items[3].category);
    try std.testing.expectEqual(DiagnosticCategory.duplicate_ready, state.diagnostics.items[4].category);
    try std.testing.expectEqual(DiagnosticCategory.duplicate_pending_request, state.diagnostics.items[5].category);
    try std.testing.expectEqual(DiagnosticCategory.incomplete_frame, state.diagnostics.items[6].category);
}

test "M6 host protocol serializes deterministic Zig to host frames" {
    const allocator = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try writeInitializeFrame(allocator, &out.writer, .{
        .marker = "pi-m6-host-marker",
        .cwd = "/workspace",
        .fixture = "fixture-a",
    });
    try writeExtensionUiResponseFrame(allocator, &out.writer, "req-1", "{\"value\":\"ok\"}");
    try writeShutdownFrame(&out.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"initialize\",\"marker\":\"pi-m6-host-marker\",\"cwd\":\"/workspace\",\"fixture\":\"fixture-a\"}\n{\"type\":\"extension_ui_response\",\"id\":\"req-1\",\"payload\":{\"value\":\"ok\"}}\n{\"type\":\"shutdown\"}\n",
        out.written(),
    );
}

test "M6 host lifecycle starts once initializes becomes ready and shuts down" {
    const allocator = std.testing.allocator;
    const capture_path = "/tmp/pi-m6-host-lifecycle-capture.jsonl";
    std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};
    defer std.Io.Dir.deleteFileAbsolute(std.testing.io, capture_path) catch {};

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
