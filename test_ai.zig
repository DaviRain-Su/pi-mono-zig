const std = @import("std");
const ai = @import("ai");

fn currentMs() i64 {
    const ts = std.posix.clock_gettime(std.os.linux.CLOCK.REALTIME) catch return 0;
    return @as(i64, ts.sec) * 1000 + @divFloor(ts.nsec, std.time.ns_per_ms);
}

pub fn main(init: std.process.Init) !void {
    // Register providers
    ai.openai_completions_provider.registerOpenAICompletionsProvider();

    // Register Kimi model
    const kimi_model = ai.Model{
        .id = "kimi-latest",
        .name = "Kimi Latest",
        .api = .{ .known = .openai_completions },
        .provider = .{ .known = .kimi_coding },
        .base_url = "https://api.moonshot.cn/v1",
        .reasoning = false,
        .input_types = &.{"text"},
        .context_window = 200000,
        .max_tokens = 8192,
    };
    ai.registerModel(kimi_model);

    const context = ai.Context{
        .system_prompt = "You are a helpful assistant.",
        .messages = &.{
            ai.Message{ .user = .{ .content = .{ .text = "Say hello in one word." }, .timestamp = currentMs() } },
        },
    };

    const api_key = init.environ_map.get("KIMI_API_KEY");

    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);

    var es = ai.streamSimple(kimi_model, context, .{ .base = .{ .api_key = api_key, .io = init.io } });

    while (true) {
        const ev = es.next() orelse break;
        switch (ev) {
            .start => {
                try stdout_writer.interface.print("[start]\n", .{});
            },
            .text_delta => |d| {
                try stdout_writer.interface.print("{s}", .{d.delta});
            },
            .text_end => {
                try stdout_writer.interface.print("\n", .{});
            },
            .done => |d| {
                try stdout_writer.interface.print("\n[done] reason={s}\n", .{@tagName(d.reason)});
                break;
            },
            .err_event => |e| {
                try stdout_writer.interface.print("\n[error] reason={s} msg={s}\n", .{ @tagName(e.reason), e.err_msg.error_message orelse "unknown" });
                break;
            },
            else => {},
        }
    }
    try stdout_writer.flush();
}
