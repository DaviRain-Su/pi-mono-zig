const std = @import("std");
const ai = @import("../root.zig");
const openai_responses = @import("openai_responses.zig");

const DEFAULT_API_VERSION = "v1";

fn resolveDeploymentName(model: ai.Model, options: ?ai.StreamOptions) []const u8 {
    // For now, use model.id as deployment name.
    // Future: support AZURE_OPENAI_DEPLOYMENT_NAME_MAP env var or options metadata.
    _ = options;
    return model.id;
}

fn resolveAzureConfig(model: ai.Model, options: ?ai.StreamOptions) struct { base_url: []const u8, api_version: []const u8 } {
    const api_version = blk: {
        if (options) |opts| {
            if (opts.metadata) |meta| {
                if (meta.object.get("azureApiVersion")) |v| {
                    if (v == .string) break :blk v.string;
                }
            }
        }
        break :blk std.process.getEnvVarOwned(std.heap.page_allocator, "AZURE_OPENAI_API_VERSION") catch |err| switch (err) {
            error.EnvironmentVariableNotFound => DEFAULT_API_VERSION,
            else => DEFAULT_API_VERSION,
        };
    };

    const base_url = blk: {
        if (model.base_url) |bu| break :blk bu;
        if (options) |opts| {
            if (opts.metadata) |meta| {
                if (meta.object.get("azureBaseUrl")) |v| {
                    if (v == .string) break :blk v.string;
                }
                if (meta.object.get("azureResourceName")) |v| {
                    if (v == .string) {
                        const gpa = std.heap.page_allocator;
                        const url = std.fmt.allocPrint(gpa, "https://{s}.openai.azure.com/openai", .{v.string}) catch break :blk DEFAULT_BASE_URL;
                        break :blk url;
                    }
                }
            }
        }
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "AZURE_OPENAI_BASE_URL")) |v| {
            break :blk v;
        } else |_| {}
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "AZURE_OPENAI_RESOURCE_NAME")) |v| {
            const gpa = std.heap.page_allocator;
            const url = std.fmt.allocPrint(gpa, "https://{s}.openai.azure.com/openai", .{v}) catch break :blk DEFAULT_BASE_URL;
            gpa.free(v);
            break :blk url;
        } else |_| {}
        break :blk DEFAULT_BASE_URL;
    };

    return .{ .base_url = std.mem.trimRight(u8, base_url, "/"), .api_version = api_version };
}

const DEFAULT_BASE_URL = "https://<resource>.openai.azure.com/openai";

fn normalizeAzureBaseUrl(base: []const u8) []const u8 {
    return std.mem.trimRight(u8, base, "/");
}

pub fn streamAzureOpenAIResponses(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions) ai.AssistantMessageEventStream {
    const gpa = std.heap.page_allocator;
    var es = ai.createAssistantMessageEventStream(gpa) catch @panic("OOM");

    const api_key = blk: {
        if (options) |opts| {
            if (opts.api_key) |k| break :blk k;
        }
        break :blk ai.getEnvApiKey(gpa, "azure_openai_responses") catch null;
    };
    if (api_key == null) {
        const o = ai.AssistantMessage{
            .role = "assistant",
            .content = &[_]ai.ContentBlock{},
            .api = .{ .known = .azure_openai_responses },
            .provider = model.provider,
            .model = model.id,
            .usage = .{},
            .stop_reason = .err,
            .error_message = "AZURE_OPENAI_API_KEY environment variable not set",
            .timestamp = 0,
        };
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    }

    const output = ai.AssistantMessage{
        .role = "assistant",
        .content = &[_]ai.ContentBlock{},
        .api = .{ .known = .azure_openai_responses },
        .provider = model.provider,
        .model = model.id,
        .usage = .{},
        .stop_reason = .stop,
        .timestamp = currentMs(),
    };

    const thread = std.Thread.spawn(.{}, azureThread, .{ model, context, options, api_key.?, output, es }) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to spawn thread";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return es;
    };
    thread.detach();
    return es;
}

fn azureThread(model: ai.Model, context: ai.Context, options: ?ai.StreamOptions, api_key: []const u8, output: ai.AssistantMessage, es: ai.AssistantMessageEventStream) void {
    const gpa = std.heap.page_allocator;
    const client = std.http.Client{ .allocator = gpa };
    defer client.deinit();

    const config = resolveAzureConfig(model, options);
    const deployment_name = resolveDeploymentName(model, options);
    const base = normalizeAzureBaseUrl(config.base_url);

    const url = std.fmt.allocPrint(gpa, "{s}/deployments/{s}/responses?api-version={s}", .{ base, deployment_name, config.api_version }) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "OOM";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    defer gpa.free(url);

    var params = openai_responses.buildParams(gpa, model, context, options) catch {
        var o = output;
        o.stop_reason = .err;
        o.error_message = "Failed to build request params";
        es.push(.{ .err_event = .{ .reason = .err, .err_msg = o } }) catch {};
        es.end(null);
        return;
    };
    // Override model with deployment name for Azure
    if (params == .object) {
        params.object.put("model", .{ .string = deployment_name }) catch {};
    }

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

    var extra_headers = std.ArrayList(std.http.Client.Header).init(gpa);
    defer extra_headers.deinit();
    extra_headers.append(.{ .name = "api-key", .value = api_key }) catch {};
    extra_headers.append(.{ .name = "Accept", .value = "text/event-stream" }) catch {};

    // Merge model.headers
    if (model.headers) |mh| {
        var it = mh.object.iterator();
        while (it.next()) |entry| {
            const val = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
            extra_headers.append(.{ .name = entry.key_ptr.*, .value = val }) catch {};
        }
    }

    // Merge options.headers last so they override
    if (options) |opts| {
        if (opts.headers) |oh| {
            var it = oh.object.iterator();
            while (it.next()) |entry| {
                const val = if (entry.value_ptr.* == .string) entry.value_ptr.*.string else continue;
                extra_headers.append(.{ .name = entry.key_ptr.*, .value = val }) catch {};
            }
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    const fetch_res = client.fetch(aa, .{
        .location = .{ .url = url },
        .method = .POST,
        .extra_headers = extra_headers.items,
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
                    openai_responses.processResponsesSseLine(gpa, line, &output, es, model);
                }
                line_buf.clearRetainingCapacity();
            } else {
                line_buf.append(byte) catch {};
            }
        }
    }

    es.push(.{ .done = .{ .reason = output.stop_reason, .message = output } }) catch {};
    es.end(null);
}

pub fn streamSimpleAzureOpenAIResponses(model: ai.Model, context: ai.Context, options: ?ai.types.SimpleStreamOptions) ai.AssistantMessageEventStream {
    var base_opts = ai.StreamOptions{};
    const api_key = blk: {
        if (options) |opts| {
            base_opts = opts.base;
            if (opts.base.api_key) |k| break :blk k;
        }
        break :blk ai.getEnvApiKey(std.heap.page_allocator, "azure_openai_responses") catch null;
    };
    if (api_key) |k| {
        base_opts.api_key = k;
    }

    // Extract azure-specific metadata from simple options if present
    if (options) |opts| {
        if (opts.base.metadata) |meta| {
            base_opts.metadata = meta;
        }
    }

    return streamAzureOpenAIResponses(model, context, base_opts);
}

pub fn registerAzureOpenAIResponsesProvider() void {
    ai.registerApiProvider(.{
        .api = .{ .known = .azure_openai_responses },
        .stream = streamAzureOpenAIResponses,
        .stream_simple = streamSimpleAzureOpenAIResponses,
    });
}

fn currentMs() i64 {
    const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}

test "azure_openai_responses compiles and registers" {
    registerAzureOpenAIResponsesProvider();
}
