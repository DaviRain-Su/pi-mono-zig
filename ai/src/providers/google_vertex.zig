const std = @import("std");
const ai = @import("../root.zig");
const google_gen = @import("google_generative_ai.zig");

fn resolveVertexConfig(model: ai.Model, options: ?ai.StreamOptions) struct {
    project: []const u8,
    location: []const u8,
    api_key: ?[]const u8,
} {
    const project = blk: {
        if (options) |opts| {
            if (opts.metadata) |meta| {
                if (meta.object.get("project")) |v| {
                    if (v == .string) break :blk v.string;
                }
            }
        }
        break :blk std.process.getEnvVarOwned(std.heap.page_allocator, "GOOGLE_CLOUD_PROJECT") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => std.process.getEnvVarOwned(std.heap.page_allocator, "GCLOUD_PROJECT") catch |e2| switch (e2) {
                error.EnvironmentVariableNotFound => break :blk null,
                else => break :blk null,
            },
            else => break :blk null,
        };
    };

    const location = blk: {
        if (options) |opts| {
            if (opts.metadata) |meta| {
                if (meta.object.get("location")) |v| {
                    if (v == .string) break :blk v.string;
                }
            }
        }
        break :blk std.process.getEnvVarOwned(std.heap.page_allocator, "GOOGLE_CLOUD_LOCATION") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk null,
            else => break :blk null,
        };
    };

    const api_key = blk: {
        if (options) |opts| {
            if (opts.api_key) |k| break :blk k;
        }
        break :blk std.process.getEnvVarOwned(std.heap.page_allocator, "GOOGLE_CLOUD_API_KEY") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => break :blk null,
            else => break :blk null,
        };
    };

    const fallback_project = if (model.base_url) |bu| extractProjectFromBaseUrl(bu) else null;
    const fallback_location = if (model.base_url) |bu| extractLocationFromBaseUrl(bu) else null;

    return .{
        .project = project orelse fallback_project orelse "",
        .location = location orelse fallback_location orelse "",
        .api_key = api_key,
    };
}

fn extractProjectFromBaseUrl(url: []const u8) ?[]const u8 {
    // Very naive extraction, just for fallback.
    // URL format: https://{location}-aiplatform.googleapis.com/v1/projects/{project}/locations/{location}/...
    const prefix = "/projects/";
    const idx = std.mem.indexOf(u8, url, prefix) orelse return null;
    const rest = url[idx + prefix.len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse return rest;
    return rest[0..end];
}

fn extractLocationFromBaseUrl(url: []const u8) ?[]const u8 {
    const prefix = "/locations/";
    const idx = std.mem.indexOf(u8, url, prefix) orelse return null;
    const rest = url[idx + prefix.len..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse return rest;
    return rest[0..end];
}

fn getAccessTokenViaGcloud(gpa: std.mem.Allocator) !?[]const u8 {
    const argv = &[_][]const u8{
        "gcloud", "auth", "application-default", "print-access-token",
    };
    const result = std.process.Child.run(.{
        .allocator = gpa,
        .argv = argv,
    }) catch return null;
    if (result.term != .Exited or result.term.Exited != 0) {
        gpa.free(result.stdout);
        gpa.free(result.stderr);
        return null;
    }
    gpa.free(result.stderr);
    const trimmed = std.mem.trimWhitespace(result.stdout);
    if (trimmed.len == 0) {
        gpa.free(result.stdout);
        return null;
    }
    // Child.run allocates fresh memory; we keep it but must ensure it's exactly trimmed length
    if (trimmed.ptr == result.stdout.ptr and trimmed.len == result.stdout.len) {
        return trimmed;
    }
    const duped = try gpa.dupe(u8, trimmed);
    gpa.free(result.stdout);
    return duped;
}

pub fn streamGoogleVertex(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions) ai.AssistantMessageEventStream {
    const gpa = std.heap.page_allocator;
    var es = ai.createAssistantMessageEventStream(gpa) catch @panic("OOM");

    const config = resolveVertexConfig(model, options);
    if (config.project.len == 0 or config.location.len == 0) {
        const o = ai.AssistantMessage{
            .role = "assistant",
            .content = &[_]ai.ContentBlock{},
            .api = .{ .known = .google_vertex },
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .err,
            .error_message = "Vertex AI requires project and location. Set GOOGLE_CLOUD_PROJECT and GOOGLE_CLOUD_LOCATION env vars or pass them in metadata.",
            .timestamp = 0,
        };
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    }

    const api_key = config.api_key;
    const token = if (api_key == null) getAccessTokenViaGcloud(gpa) catch null else null;
    if (api_key == null and token == null) {
        const o = ai.AssistantMessage{
            .role = "assistant",
            .content = &[_]ai.ContentBlock{},
            .api = .{ .known = .google_vertex },
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .err,
            .error_message = "Vertex AI authentication failed. Set GOOGLE_CLOUD_API_KEY or ensure 'gcloud auth application-default print-access-token' works.",
            .timestamp = 0,
        };
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    }

    const output = ai.AssistantMessage{
        .role = "assistant",
        .content = &[_]ai.ContentBlock{},
        .api = .{ .known = .google_vertex },
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = currentMs(),
    };

    const thread = std.Thread.spawn(.{}, vertexThread, .{ model, context, options, api_key, token, output, es }) catch |err| {
        var o = output;
        o.stop_reason = .err;
        o.error_message = @errorName(err);
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    };
    thread.detach();
    return es;
}

fn vertexThread(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions, api_key: ?[]const u8, token: ?[]const u8, output: ai.AssistantMessage, es: ai.AssistantMessageEventStream) void {
    const gpa = std.heap.page_allocator;
    const client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const config = resolveVertexConfig(model, options);

    var url: []const u8 = undefined;
    if (api_key) |key| {
        url = std.fmt.allocPrint(gpa, "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:streamGenerateContent?alt=sse&key={s}", .{
            config.location, config.project, config.location, model.id, key,
        }) catch {
            var o = output;
            o.stop_reason = .err;
            o.error_message = "OOM";
            es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
            es.end(null);
            return;
        };
    } else {
        url = std.fmt.allocPrint(gpa, "https://{s}-aiplatform.googleapis.com/v1/projects/{s}/locations/{s}/publishers/google/models/{s}:streamGenerateContent?alt=sse", .{
            config.location, config.project, config.location, model.id,
        }) catch {
            var o = output;
            o.stop_reason = .err;
            o.error_message = "OOM";
            es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
            es.end(null);
            return;
        };
    }
    defer gpa.free(url);

    const params = google_gen.buildParams(gpa, model, context, options) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to build request params";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };

    var body_list = std.ArrayList(u8).init(gpa);
    defer body_list.deinit();
    std.json.stringify(params, .{}, body_list.writer()) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to serialize request";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };

    var headers = std.ArrayList(std.http.Client.Header).init(gpa);
    defer headers.deinit();
    headers.append(.{ .name = "Content-Type", .value = "application/json" }) catch {};
    headers.append(.{ .name = "Accept", .value = "text/event-stream" }) catch {};
    if (token) |t| {
        const auth = std.fmt.allocPrint(gpa, "Bearer {s}", .{t}) catch {
            var o = output;
            o.stop_reason = .err;
            o.error_message = "OOM";
            es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
            es.end(null);
            return;
        };
        defer gpa.free(auth);
        headers.append(.{ .name = "Authorization", .value = auth }) catch {};
    }

    // Merge model.headers
    if (model.headers) |mh| {
        var it = mh.object.iterator();
        while (it.next()) |entry| {
            const val = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
            headers.append(.{ .name = entry.key_ptr.*, .value = val }) catch {};
        }
    }
    // Merge options.headers
    if (options) |opts| {
        if (opts.headers) |oh| {
            var it = oh.object.iterator();
            while (it.next()) |entry| {
                const val = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
                headers.append(.{ .name = entry.key_ptr.*, .value = val }) catch {};
            }
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const fetch_res = client.fetch(aa, .{
        .location = .{ .url = url },
        .method = .POST,
        .extra_headers = headers.items,
        .payload = body_list.items,
    }) catch |err| {
        var o = output;
        o.stop_reason = .err;
        o.error_message = @errorName(err);
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };

    if (fetch_res.status != .ok) {
        var o = output;
        o.stop_reason = .err;
        o.error_message = std.fmt.allocPrint(gpa, "HTTP {d}", .{@intFromEnum(fetch_res.status)}) catch "HTTP error";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    }

    es.push(.{ .start = .{ .partial = output } }) catch {
        es.end(null);
        return;
    };

    var buf: [4096]u8 = undefined;
    var reader = fetch_res.body.reader();
    var line_buf = std.ArrayList(u8).init(gpa);
    defer line_buf.deinit();

    var current_block: ?ai.ContentBlock = null;

    while (true) {
        const n = reader.read(&buf) catch {
            var o = output;
            o.stop_reason = .err;
            o.error_message = "Read error";
            es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
            es.end(null);
            return;
        };
        if (n == 0) break;

        for (buf[0..n]) |byte| {
            if (byte == '\n') {
                const line = std.mem.trim(u8, line_buf.items, " \r\n");
                if (line.len > 0) {
                    google_gen.processGoogleSseLine(gpa, line, &output, es, model, &current_block);
                }
                line_buf.clearRetainingCapacity();
            } else {
                line_buf.append(byte) catch {};
            }
        }
    }

    if (current_block) |cb| {
        google_gen.finalizeCurrentBlock(es, &output, cb);
    }

    es.push(.{ .done = .{ .reason = output.stop_reason, .message = output } }) catch {};
    es.end(null);
}

pub fn streamSimpleGoogleVertex(model: ai.Model, context: ai.Context, options: ?ai.types.SimpleStreamOptions) ai.AssistantMessageEventStream {
    var base_opts = ai.StreamOptions{};
    if (options) |opts| {
        base_opts = opts.base;
    }
    return streamGoogleVertex(model, context, base_opts);
}

pub fn registerGoogleVertexProvider() void {
    ai.registerApiProvider(.{
        .api = .{ .known = .google_vertex },
        .stream = streamGoogleVertex,
        .stream_simple = streamSimpleGoogleVertex,
    });
}

fn currentMs() i64 {
    const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}

test "google_vertex compiles and registers" {
    registerGoogleVertexProvider();
}
