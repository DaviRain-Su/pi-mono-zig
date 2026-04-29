const std = @import("std");
const event_stream = @import("../event_stream.zig");
const types = @import("../types.zig");

const MAX_PROVIDER_ERROR_BODY_BYTES: usize = 512;

pub fn formatHttpStatusError(
    allocator: std.mem.Allocator,
    status: u16,
    body: []const u8,
) ![]u8 {
    const detail = try sanitizeProviderErrorDetail(allocator, body);
    defer allocator.free(detail);

    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status, detail });
}

pub fn pushHttpStatusError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    status: u16,
    body: []const u8,
) !void {
    const error_message = try formatHttpStatusError(allocator, status, body);
    const message = types.AssistantMessage{
        .role = "assistant",
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = error_message,
        .timestamp = 0,
    };
    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = message,
    });
    stream_ptr.end(message);
}

pub fn runtimeStopReason(err: anyerror) types.StopReason {
    return switch (err) {
        error.RequestAborted => .aborted,
        else => .error_reason,
    };
}

pub fn runtimeErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.RequestAborted => "Request was aborted",
        else => @errorName(err),
    };
}

pub fn pushTerminalRuntimeError(
    stream_ptr: *event_stream.AssistantMessageEventStream,
    message: types.AssistantMessage,
) void {
    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = message.error_message,
        .message = message,
    });
    stream_ptr.end(message);
}

pub fn sanitizeProviderErrorDetail(
    allocator: std.mem.Allocator,
    body: []const u8,
) ![]u8 {
    if (std.mem.trim(u8, body, &std.ascii.whitespace).len == 0) {
        return allocator.dupe(u8, "<empty body>");
    }

    const scan_len = @min(body.len, MAX_PROVIDER_ERROR_BODY_BYTES);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var i: usize = 0;
    while (i < scan_len) {
        if (sensitiveKeyLengthAt(body[0..scan_len], i)) |key_len| {
            try out.appendSlice(allocator, "[REDACTED]");
            i = skipSensitiveValue(body[0..scan_len], i + key_len);
            continue;
        }

        if (secretTokenLengthAt(body[0..scan_len], i)) |token_len| {
            try out.appendSlice(allocator, "[REDACTED]");
            i += token_len;
            continue;
        }

        if (localPathLengthAt(body[0..scan_len], i)) |path_len| {
            try out.appendSlice(allocator, "[PATH]");
            i += path_len;
            continue;
        }

        const byte = body[i];
        try out.append(allocator, if (byte < 0x20 and byte != '\n' and byte != '\r' and byte != '\t') ' ' else byte);
        i += 1;
    }

    const truncated = body.len > scan_len;
    var sanitized = std.mem.trim(u8, out.items, &std.ascii.whitespace);
    if (sanitized.len == 0) sanitized = "<redacted>";

    if (truncated) {
        return std.fmt.allocPrint(allocator, "{s} [truncated]", .{sanitized});
    }
    return allocator.dupe(u8, sanitized);
}

fn sensitiveKeyLengthAt(body: []const u8, index: usize) ?usize {
    if (index > 0 and isKeyChar(body[index - 1])) return null;

    const keys = [_][]const u8{
        "authorization",
        "x-goog-api-key",
        "api_key",
        "apikey",
        "apiKey",
        "access_token",
        "refresh_token",
        "id_token",
        "secret_access_key",
        "secretAccessKey",
        "accessKeyId",
        "private_key",
        "credential",
        "credentials",
        "password",
        "secret",
        "token",
        "request_id",
        "requestId",
        "x-request-id",
    };

    for (keys) |key| {
        if (body.len - index < key.len) continue;
        if (!std.ascii.eqlIgnoreCase(body[index .. index + key.len], key)) continue;
        if (index + key.len < body.len and isKeyChar(body[index + key.len])) continue;
        return key.len;
    }
    return null;
}

fn skipSensitiveValue(body: []const u8, start: usize) usize {
    var i = start;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    if (i < body.len and (body[i] == ':' or body[i] == '=')) i += 1;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}

    if (i < body.len and body[i] == '"') {
        i += 1;
        while (i < body.len) : (i += 1) {
            if (body[i] == '\\' and i + 1 < body.len) {
                i += 1;
                continue;
            }
            if (body[i] == '"') {
                i += 1;
                break;
            }
        }
        return i;
    }

    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            '\n', '\r', ',', '&', '}' => break,
            else => {},
        }
    }
    return i;
}

fn secretTokenLengthAt(body: []const u8, index: usize) ?usize {
    const prefixes = [_][]const u8{ "sk-", "AIza", "AKIA", "ASIA", "req_" };
    for (prefixes) |prefix| {
        if (body.len - index < prefix.len) continue;
        if (!std.ascii.eqlIgnoreCase(body[index .. index + prefix.len], prefix)) continue;

        var end = index + prefix.len;
        while (end < body.len and isTokenChar(body[end])) : (end += 1) {}
        if (end - index >= prefix.len + 4) return end - index;
    }
    return null;
}

fn localPathLengthAt(body: []const u8, index: usize) ?usize {
    const prefixes = [_][]const u8{ "/Users/", "/home/", "/var/folders/" };
    for (prefixes) |prefix| {
        if (body.len - index < prefix.len) continue;
        if (!std.mem.eql(u8, body[index .. index + prefix.len], prefix)) continue;
        var end = index + prefix.len;
        while (end < body.len) : (end += 1) {
            switch (body[end]) {
                ' ', '\t', '\n', '\r', '"', '\'', ')', ']', '}' => break,
                else => {},
            }
        }
        return end - index;
    }
    return null;
}

fn isKeyChar(byte: u8) bool {
    return isAsciiAlnum(byte) or byte == '_' or byte == '-';
}

fn isTokenChar(byte: u8) bool {
    return isAsciiAlnum(byte) or byte == '_' or byte == '-' or byte == '.' or byte == '/';
}

fn isAsciiAlnum(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9');
}

pub const TestStatusServer = struct {
    io: std.Io,
    server: std.Io.net.Server,
    status: u16,
    reason: []const u8,
    response_headers: []const u8,
    body: []const u8,
    thread: ?std.Thread = null,

    pub fn init(
        io: std.Io,
        status: u16,
        reason: []const u8,
        response_headers: []const u8,
        body: []const u8,
    ) !TestStatusServer {
        return .{
            .io = io,
            .server = try std.Io.net.IpAddress.listen(&.{ .ip4 = .loopback(0) }, io, .{ .reuse_address = true }),
            .status = status,
            .reason = reason,
            .response_headers = response_headers,
            .body = body,
        };
    }

    pub fn start(self: *TestStatusServer) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn deinit(self: *TestStatusServer) void {
        self.server.deinit(self.io);
        if (self.thread) |thread| thread.join();
    }

    pub fn url(self: *const TestStatusServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    fn run(self: *TestStatusServer) void {
        const stream = self.server.accept(self.io) catch |err| switch (err) {
            error.SocketNotListening, error.Canceled => return,
            else => std.debug.panic("test status server accept failed: {}", .{err}),
        };
        defer stream.close(self.io);

        readRequestHead(stream) catch |err| std.debug.panic("test status server read failed: {}", .{err});
        writeResponse(self, stream) catch |err| std.debug.panic("test status server write failed: {}", .{err});
    }

    fn readRequestHead(stream: std.Io.net.Stream) !void {
        var read_buffer: [1024]u8 = undefined;
        var reader = stream.reader(std.testing.io, &read_buffer);
        var tail = [_]u8{ 0, 0, 0, 0 };
        var count: usize = 0;

        while (true) {
            const byte = try reader.interface.takeByte();
            tail[count % tail.len] = byte;
            count += 1;
            if (count >= 4) {
                const start_index = count % tail.len;
                const ordered = [_]u8{
                    tail[start_index],
                    tail[(start_index + 1) % tail.len],
                    tail[(start_index + 2) % tail.len],
                    tail[(start_index + 3) % tail.len],
                };
                if (std.mem.eql(u8, &ordered, "\r\n\r\n")) break;
            }
        }
    }

    fn writeResponse(self: *TestStatusServer, stream: std.Io.net.Stream) !void {
        var write_buffer: [1024]u8 = undefined;
        var writer = stream.writer(self.io, &write_buffer);
        try writer.interface.print(
            "HTTP/1.1 {d} {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n{s}\r\n",
            .{ self.status, self.reason, self.body.len, self.response_headers },
        );
        try writer.interface.writeAll(self.body);
        try writer.interface.flush();
    }
};

test "HTTP provider error formatter redacts secrets paths ids and bounds body" {
    const allocator = std.testing.allocator;

    var large_body = std.ArrayList(u8).empty;
    defer large_body.deinit(allocator);
    try large_body.appendSlice(allocator, "{\"error\":\"bad\",\"Authorization\":\"Bearer sk-live-secret\",\"x-goog-api-key\":\"AIza-secret\",\"request_id\":\"req_random_123456789\",\"trace\":\"/Users/alice/project/file.zig:1\"}");
    try large_body.appendNTimes(allocator, 'x', 900);

    const message = try formatHttpStatusError(allocator, 429, large_body.items);
    defer allocator.free(message);

    try std.testing.expect(std.mem.startsWith(u8, message, "HTTP 429: "));
    try std.testing.expect(std.mem.indexOf(u8, message, "bad") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "[truncated]") != null);
    try std.testing.expect(message.len < 700);
    try std.testing.expect(std.mem.indexOf(u8, message, "sk-live-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "AIza-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "req_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, message, "/Users/alice") == null);
}

test "HTTP status helper emits one terminal error event with result identity" {
    const allocator = std.testing.allocator;
    var stream = event_stream.createAssistantMessageEventStream(allocator, std.Io.failing);
    defer stream.deinit();

    const model = types.Model{
        .id = "fixture-model",
        .name = "Fixture Model",
        .api = "openai-completions",
        .provider = "fixture-provider",
        .base_url = "http://localhost",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1024,
        .max_tokens = 256,
    };

    try pushHttpStatusError(allocator, &stream, model, 500, "{\"error\":\"down\"}");
    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expectEqualStrings("openai-completions", event.message.?.api);
    try std.testing.expectEqualStrings("fixture-provider", event.message.?.provider);
    try std.testing.expectEqualStrings("fixture-model", event.message.?.model);
    try std.testing.expectEqual(types.StopReason.error_reason, event.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqualStrings(event.message.?.api, result.api);
    try std.testing.expectEqualStrings(event.message.?.provider, result.provider);
    try std.testing.expectEqualStrings(event.message.?.model, result.model);
    try std.testing.expectEqual(event.message.?.usage.total_tokens, result.usage.total_tokens);
    allocator.free(result.error_message.?);
}
