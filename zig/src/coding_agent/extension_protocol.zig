const std = @import("std");
const common = @import("tools/common.zig");
const extension_registry = @import("extension_registry.zig");

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

/// Live Bun JSONL `register_*`/`unregister_*` registration frame. The
/// host parser owns a deep-cloned copy of the JSON object payload so
/// the protocol state can apply it to the runtime registry on the
/// host's mutex-guarded thread without holding a reference to the
/// short-lived parser arena.
pub const RegistryFrame = struct {
    payload: std.json.Value,

    pub fn deinit(self: *RegistryFrame, allocator: std.mem.Allocator) void {
        common.deinitJsonValue(allocator, self.payload);
        self.* = undefined;
    }
};

pub const HostMessage = union(enum) {
    ready,
    diagnostic: Diagnostic,
    extension_ui_request: ExtensionUiRequest,
    shutdown_complete,
    error_message: Diagnostic,
    /// Live Bun-hosted register_tool / register_command /
    /// register_shortcut / register_flag / register_provider /
    /// unregister_provider frame. Routed through `ProtocolState` to
    /// `extension_registry.applyHostFrame` so the runtime registry
    /// reflects extension contributions in CLI / TS-RPC output.
    registry_frame: RegistryFrame,

    pub fn deinit(self: *HostMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .diagnostic => |*diagnostic| diagnostic.deinit(allocator),
            .extension_ui_request => |*request| request.deinit(allocator),
            .error_message => |*diagnostic| diagnostic.deinit(allocator),
            .registry_frame => |*frame| frame.deinit(allocator),
            else => {},
        }
        self.* = undefined;
    }
};

/// Names of JSONL message types that carry registration data.
const REGISTRY_FRAME_TYPES = [_][]const u8{
    "register_tool",
    "register_command",
    "register_shortcut",
    "register_flag",
    "register_provider",
    "unregister_provider",
    "register_capability",
    "unregister_capability",
    "set_header",
    "clear_header",
    "set_footer",
    "clear_footer",
    "register_terminal_input",
    "unregister_terminal_input",
    "set_editor_component",
    "clear_editor_component",
    "set_widget",
    "clear_widget",
    "clear_ui_hooks_for_reload",
    "clear_extension_registrations",
    "resources_discover",
    "register_message_renderer",
    "unregister_message_renderer",
};

pub fn registryFrameTypeNames() []const []const u8 {
    return REGISTRY_FRAME_TYPES[0..];
}

pub fn diagnosticCategoryNames() []const []const u8 {
    return &.{
        "blank_frame",
        "malformed_json",
        "non_object_frame",
        "unsupported_message_type",
        "duplicate_ready",
        "duplicate_pending_request",
        "incomplete_frame",
        "startup_failure",
        "host_error",
        "host_exit",
    };
}

fn isRegistryFrameType(type_name: []const u8) bool {
    inline for (REGISTRY_FRAME_TYPES) |candidate| {
        if (std.mem.eql(u8, type_name, candidate)) return true;
    }
    return false;
}

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
    pending_requests_closed: bool = false,
    pending_request_ids: std.StringHashMap(void),
    diagnostics: std.ArrayList(Diagnostic) = .empty,
    ui_requests: std.ArrayList(ExtensionUiRequest) = .empty,
    /// Live runtime registry populated as register_* JSONL frames
    /// arrive over the host stdout protocol. Mirrors the TypeScript
    /// `runtime.extensionState.registry` shape so CLI / TS-RPC consumers
    /// can observe registered tools, commands, shortcuts, flags, and
    /// providers without depending on local sidecar manifests.
    registry: extension_registry.Registry,
    /// Total number of registry frames successfully applied. Useful for
    /// fixture tests that need to wait for the host to drain its
    /// register_* frames before snapshotting.
    registry_frames_applied: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ProtocolState {
        return .{
            .allocator = allocator,
            .pending_request_ids = std.StringHashMap(void).init(allocator),
            .registry = extension_registry.Registry.init(allocator),
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
        self.registry.deinit();
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
                if (self.pending_requests_closed) return;
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
            .registry_frame => |frame| {
                const outcome = extension_registry.applyHostFrame(&self.registry, frame.payload) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    error.WriteFailed => return err,
                };
                switch (outcome) {
                    .registered_tool,
                    .registered_command,
                    .registered_shortcut,
                    .registered_flag,
                    .registered_provider,
                    .unregistered_provider,
                    .registered_capability,
                    .unregistered_capability,
                    .set_header_hook,
                    .cleared_header_hook,
                    .set_footer_hook,
                    .cleared_footer_hook,
                    .registered_terminal_input,
                    .unregistered_terminal_input,
                    .set_editor_component_hook,
                    .cleared_editor_component_hook,
                    .set_widget_hook,
                    .cleared_widget_hook,
                    .cleared_ui_hooks_for_reload,
                    .cleared_extension_registrations,
                    .resources_discovered,
                    .registered_message_renderer,
                    .unregistered_message_renderer,
                    => self.registry_frames_applied += 1,
                    .none, .ignored_unsupported, .ignored_malformed => {},
                }
            },
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

    pub fn closePendingRequests(self: *ProtocolState) void {
        self.clearPendingRequests();
        self.pending_requests_closed = true;
    }

    pub fn pendingCount(self: *const ProtocolState) usize {
        return self.pending_request_ids.count();
    }

    pub fn diagnosticCategoryCount(self: *const ProtocolState, category: DiagnosticCategory) usize {
        var count: usize = 0;
        for (self.diagnostics.items) |diagnostic| {
            if (diagnostic.category == category) count += 1;
        }
        return count;
    }

    pub fn resolvePendingRequest(self: *ProtocolState, id: []const u8) bool {
        if (self.pending_request_ids.fetchRemove(id)) |removed| {
            self.allocator.free(removed.key);
            return true;
        }
        return false;
    }

    pub fn addDiagnostic(self: *ProtocolState, category: DiagnosticCategory, severity: DiagnosticSeverity, message: []const u8) !void {
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
        const payload_json = try extensionUiPayloadJson(allocator, object);
        errdefer allocator.free(payload_json);
        return .{ .extension_ui_request = .{
            .id = try allocator.dupe(u8, id),
            .method = try allocator.dupe(u8, method),
            .response_required = optionalBool(object, "responseRequired") orelse false,
            .payload_json = payload_json,
        } };
    }
    if (isRegistryFrameType(type_name)) {
        const cloned = try common.cloneJsonValue(allocator, .{ .object = object });
        return .{ .registry_frame = .{ .payload = cloned } };
    }
    return error.UnsupportedHostMessageType;
}

fn extensionUiPayloadJson(allocator: std.mem.Allocator, object: std.json.ObjectMap) ![]u8 {
    if (object.get("payload")) |payload| {
        if (payload == .object) {
            return try std.json.Stringify.valueAlloc(allocator, payload, .{});
        }
    }

    var payload = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const payload_value = std.json.Value{ .object = payload };
        common.deinitJsonValue(allocator, payload_value);
    }
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "type") or
            std.mem.eql(u8, entry.key_ptr.*, "id") or
            std.mem.eql(u8, entry.key_ptr.*, "method") or
            std.mem.eql(u8, entry.key_ptr.*, "responseRequired"))
        {
            continue;
        }
        try payload.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try common.cloneJsonValue(allocator, entry.value_ptr.*));
    }
    const payload_value = std.json.Value{ .object = payload };
    defer {
        common.deinitJsonValue(allocator, payload_value);
    }
    return try std.json.Stringify.valueAlloc(allocator, payload_value, .{});
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

test "ProtocolState handles resources_discover only through registry frames" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/skills\",42],\"promptPaths\":[\"fixture/prompts\",false],\"themePaths\":[\"fixture/themes\",null],\"extensionPath\":\"fixture/extension.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 0), state.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.resource_discoveries.items.len);

    const discovery = state.registry.resource_discoveries.items[0];
    try std.testing.expectEqualStrings("fixture/extension.ts", discovery.extension_path);
    try std.testing.expectEqual(@as(usize, 1), discovery.skill_paths.items.len);
    try std.testing.expectEqualStrings("fixture/skills", discovery.skill_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), discovery.prompt_paths.items.len);
    try std.testing.expectEqualStrings("fixture/prompts", discovery.prompt_paths.items[0]);
    try std.testing.expectEqual(@as(usize, 1), discovery.theme_paths.items.len);
    try std.testing.expectEqualStrings("fixture/themes", discovery.theme_paths.items[0]);
}

test "ProtocolState keeps UI request edge cases stable" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"pre-ready\",\"method\":\"input\",\"responseRequired\":true}\n", &state);
    try std.testing.expectEqual(@as(usize, 1), state.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticCategory.host_error, state.diagnostics.items[0].category);
    try std.testing.expectEqual(@as(usize, 0), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());

    const ready_and_requests =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"notify\",\"method\":\"notification\",\"responseRequired\":false}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true}\n";
    try parser.feed(allocator, ready_and_requests, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 2), state.diagnostics.items.len);
    try std.testing.expectEqual(DiagnosticCategory.duplicate_pending_request, state.diagnostics.items[1].category);
    try std.testing.expectEqual(@as(usize, 2), state.ui_requests.items.len);
    try std.testing.expectEqualStrings("notify", state.ui_requests.items[0].id);
    try std.testing.expect(!state.ui_requests.items[0].response_required);
    try std.testing.expectEqualStrings("pending", state.ui_requests.items[1].id);
    try std.testing.expect(state.ui_requests.items[1].response_required);
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount());
    try std.testing.expect(!state.resolvePendingRequest("unknown"));

    state.closePendingRequests();
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"after-close\",\"method\":\"input\",\"responseRequired\":true}\n", &state);
    try std.testing.expectEqual(@as(usize, 2), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
    try std.testing.expect(!state.resolvePendingRequest("pending"));
}

test "ProtocolState registry_frames_applied counts only accepted registry outcomes" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    try parser.feed(allocator, "{\"type\":\"ready\"}\n", &state);
    try std.testing.expectEqual(@as(usize, 0), state.registry_frames_applied);

    try parser.feed(allocator, "{\"type\":\"register_tool\",\"name\":\"tool\",\"label\":\"Tool\",\"extensionPath\":\"fixture/extension.ts\"}\n", &state);
    try std.testing.expectEqual(@as(usize, 1), state.registry_frames_applied);

    try parser.feed(allocator, "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/skills\"],\"extensionPath\":\"fixture/extension.ts\"}\n", &state);
    try std.testing.expectEqual(@as(usize, 2), state.registry_frames_applied);

    try parser.feed(allocator, "{\"type\":\"clear_extension_registrations\",\"extensionPath\":\"fixture/extension.ts\"}\n", &state);
    try std.testing.expectEqual(@as(usize, 3), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 0), state.registry.tools.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.registry.resource_discoveries.items.len);

    try parser.feed(allocator, "{\"type\":\"register_tool\",\"label\":\"missing name\",\"extensionPath\":\"fixture/extension.ts\"}\n", &state);
    try parser.feed(allocator, "{\"type\":\"clear_extension_registrations\"}\n", &state);
    try parser.feed(allocator, "{\"type\":\"unsupported\"}\n", &state);
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"notify\",\"method\":\"notification\",\"responseRequired\":false}\n", &state);
    try std.testing.expectEqual(@as(usize, 3), state.registry_frames_applied);

    var unsupported = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"unsupported_registry_frame\"}", .{});
    defer unsupported.deinit();
    try state.onMessage(.{ .registry_frame = .{ .payload = unsupported.value } });
    try std.testing.expectEqual(@as(usize, 3), state.registry_frames_applied);

    var none = try std.json.parseFromSlice(std.json.Value, allocator, "{\"type\":\"extension_ui_request\",\"id\":\"record-only\"}", .{});
    defer none.deinit();
    try state.onMessage(.{ .registry_frame = .{ .payload = none.value } });
    try std.testing.expectEqual(@as(usize, 3), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.ui_request_ids.items.len);
    try std.testing.expectEqualStrings("record-only", state.registry.ui_request_ids.items[0]);
}

test "extension protocol ABI conformance helper covers diagnostics registry frames and UI lifecycle" {
    const frame_types = registryFrameTypeNames();
    try std.testing.expectEqual(@as(usize, 23), frame_types.len);
    try std.testing.expectEqualStrings("register_tool", frame_types[0]);
    try std.testing.expectEqualStrings("unregister_message_renderer", frame_types[frame_types.len - 1]);

    const diagnostic_names = diagnosticCategoryNames();
    try std.testing.expectEqual(@typeInfo(DiagnosticCategory).@"enum".fields.len, diagnostic_names.len);
    inline for (@typeInfo(DiagnosticCategory).@"enum".fields, 0..) |field, index| {
        const category: DiagnosticCategory = @enumFromInt(field.value);
        try std.testing.expectEqualStrings(category.jsonName(), diagnostic_names[index]);
    }

    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"extension_ui_request\",\"id\":\"pre-ready\",\"method\":\"input\",\"responseRequired\":true}\n" ++
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true}\n" ++
        "{\"type\":\"extension_ui_request\",\"id\":\"pending\",\"method\":\"input\",\"responseRequired\":true}\n" ++
        "{\"type\":\"register_message_renderer\",\"customType\":\"custom\",\"extensionPath\":\"fixture/protocol.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 1), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount());
    try std.testing.expectEqual(@as(usize, 1), state.diagnosticCategoryCount(.host_error));
    try std.testing.expectEqual(@as(usize, 1), state.diagnosticCategoryCount(.duplicate_ready));
    try std.testing.expectEqual(@as(usize, 1), state.diagnosticCategoryCount(.duplicate_pending_request));
    try std.testing.expectEqual(@as(usize, 1), state.registry.message_renderers.items.len);

    try std.testing.expect(state.resolvePendingRequest("pending"));
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
    state.closePendingRequests();
    try parser.feed(allocator, "{\"type\":\"extension_ui_request\",\"id\":\"after-close\",\"method\":\"input\",\"responseRequired\":true}\n", &state);
    try std.testing.expectEqual(@as(usize, 1), state.ui_requests.items.len);
    try std.testing.expectEqual(@as(usize, 0), state.pendingCount());
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

test "M11 host protocol applies live register_* JSONL frames into runtime registry" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_tool\",\"name\":\"say-hello\",\"label\":\"Say Hello\",\"description\":\"Greets the world\",\"extensionPath\":\"fixture/extension.ts\"}\n" ++
        "{\"type\":\"register_command\",\"name\":\"say-hello\",\"description\":\"Slash command\",\"extensionPath\":\"fixture/extension.ts\"}\n" ++
        "{\"type\":\"register_shortcut\",\"shortcut\":\"ctrl+h\",\"command\":\"say-hello\",\"extensionPath\":\"fixture/extension.ts\"}\n" ++
        "{\"type\":\"register_flag\",\"name\":\"plan\",\"valueType\":\"boolean\",\"default\":true,\"extensionPath\":\"fixture/extension.ts\"}\n" ++
        "{\"type\":\"register_flag\",\"name\":\"model-alias\",\"valueType\":\"string\",\"default\":\"claude-haiku\",\"extensionPath\":\"fixture/extension.ts\"}\n" ++
        "{\"type\":\"register_provider\",\"name\":\"fake-provider\",\"displayName\":\"Fake\",\"api\":\"openai-completions\",\"models\":[{\"id\":\"fake-1\",\"name\":\"Fake 1\"}],\"extensionPath\":\"fixture/extension.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 6), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.tools.items.len);
    try std.testing.expectEqualStrings("say-hello", state.registry.tools.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), state.registry.commands.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.registry.shortcuts.items.len);
    try std.testing.expectEqual(@as(usize, 2), state.registry.flags.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.registry.providers.items.len);

    // Default values resolve through getFlag when no CLI value is set.
    const plan_value = state.registry.getFlag("plan");
    try std.testing.expect(plan_value == .boolean and plan_value.boolean);
    const alias_value = state.registry.getFlag("model-alias");
    try std.testing.expect(alias_value == .string);
    try std.testing.expectEqualStrings("claude-haiku", alias_value.string);

    // Apply parsed CLI values; getFlag now reflects them over defaults.
    _ = try state.registry.setFlagValue("plan", .{ .boolean = true });
    _ = try state.registry.setFlagValue("model-alias", .{ .string = "claude-opus" });
    const alias_after = state.registry.getFlag("model-alias");
    try std.testing.expectEqualStrings("claude-opus", alias_after.string);
}

test "extension_host ProtocolState accepts live register_capability frame" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_capability\",\"id\":\"cap-workflow\",\"kind\":\"workflow\",\"title\":\"Workflow\",\"description\":\"Runs workflow\",\"command\":\"workflow\",\"resourcePath\":\"skills/workflow\",\"extensionPath\":\"fixture/extension.ts\"}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 1), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.capabilities.items.len);
    try std.testing.expectEqualStrings("cap-workflow", state.registry.capabilities.items[0].id);
    try std.testing.expectEqualStrings("workflow", state.registry.capabilities.items[0].kind);
    try std.testing.expectEqualStrings("Workflow", state.registry.capabilities.items[0].title);
}

test "extension_host ProtocolState applies clear_extension_registrations without clearing UI lifecycle" {
    const allocator = std.testing.allocator;
    var parser = JsonlFrameParser{};
    defer parser.deinit(allocator);
    var state = ProtocolState.init(allocator);
    defer state.deinit();

    const frames =
        "{\"type\":\"ready\"}\n" ++
        "{\"type\":\"register_tool\",\"name\":\"target-tool\",\"label\":\"Target\",\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"register_tool\",\"name\":\"other-tool\",\"label\":\"Other\",\"extensionPath\":\"fixture/other.ts\"}\n" ++
        "{\"type\":\"register_capability\",\"id\":\"target-capability\",\"kind\":\"workflow\",\"title\":\"Target\",\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"register_capability\",\"id\":\"other-capability\",\"kind\":\"workflow\",\"title\":\"Other\",\"extensionPath\":\"fixture/other.ts\"}\n" ++
        "{\"type\":\"register_message_renderer\",\"customType\":\"target-message\",\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"register_message_renderer\",\"customType\":\"other-message\",\"extensionPath\":\"fixture/other.ts\"}\n" ++
        "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/target/skills\"],\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"resources_discover\",\"skillPaths\":[\"fixture/other/skills\"],\"extensionPath\":\"fixture/other.ts\"}\n" ++
        "{\"type\":\"set_header\",\"lines\":[\"Target header\"],\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"set_widget\",\"key\":\"target-widget\",\"lines\":[\"Target widget\"],\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"clear_extension_registrations\",\"extensionPath\":\"fixture/target.ts\"}\n" ++
        "{\"type\":\"clear_extension_registrations\",\"extensionPath\":42}\n";
    try parser.feed(allocator, frames, &state);

    try std.testing.expect(state.ready_seen);
    try std.testing.expectEqual(@as(usize, 11), state.registry_frames_applied);
    try std.testing.expectEqual(@as(usize, 1), state.registry.tools.items.len);
    try std.testing.expectEqualStrings("other-tool", state.registry.tools.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), state.registry.capabilities.items.len);
    try std.testing.expectEqualStrings("other-capability", state.registry.capabilities.items[0].id);
    try std.testing.expectEqual(@as(usize, 1), state.registry.message_renderers.items.len);
    try std.testing.expectEqualStrings("other-message", state.registry.message_renderers.items[0].custom_type);
    try std.testing.expectEqual(@as(usize, 1), state.registry.resource_discoveries.items.len);
    try std.testing.expectEqualStrings("fixture/other.ts", state.registry.resource_discoveries.items[0].extension_path);
    try std.testing.expect(state.registry.header_hook != null);
    try std.testing.expectEqualStrings("fixture/target.ts", state.registry.header_hook.?.extension_path);
    try std.testing.expectEqual(@as(usize, 1), state.registry.widgets.items.len);
    try std.testing.expectEqualStrings("target-widget", state.registry.widgets.items[0].key);
}
