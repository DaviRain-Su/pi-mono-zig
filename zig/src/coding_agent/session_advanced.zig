const std = @import("std");
const ai = @import("ai");
const agent = @import("agent");
const session_mod = @import("session.zig");
const session_manager_mod = @import("session_manager.zig");
const common = @import("tools/common.zig");
const formatting = @import("interactive_mode/formatting.zig");

pub const ContextUsage = struct {
    tokens: ?u32,
    context_window: u32,
    percent: ?f64,
};

pub const SessionStats = struct {
    session_file: ?[]const u8,
    session_id: []const u8,
    session_name: ?[]const u8,
    user_messages: usize,
    assistant_messages: usize,
    tool_calls: usize,
    tool_results: usize,
    total_messages: usize,
    tokens: struct {
        input: u64,
        output: u64,
        cache_read: u64,
        cache_write: u64,
        total: u64,
    },
    cost: f64,
    context_usage: ?ContextUsage,
};

pub fn getSessionStats(session: *const session_mod.AgentSession) SessionStats {
    const messages = session.agent.getMessages();

    var user_messages: usize = 0;
    var assistant_messages: usize = 0;
    var tool_calls: usize = 0;
    var tool_results: usize = 0;
    var total_input: u64 = 0;
    var total_output: u64 = 0;
    var total_cache_read: u64 = 0;
    var total_cache_write: u64 = 0;
    var total_cost: f64 = 0;

    for (messages) |message| {
        switch (message) {
            .user => user_messages += 1,
            .assistant => |assistant_message| {
                assistant_messages += 1;
                if (assistant_message.tool_calls) |calls| tool_calls += calls.len;
                total_input += assistant_message.usage.input;
                total_output += assistant_message.usage.output;
                total_cache_read += assistant_message.usage.cache_read;
                total_cache_write += assistant_message.usage.cache_write;
                total_cost += assistant_message.usage.cost.total;
            },
            .tool_result => tool_results += 1,
        }
    }

    return .{
        .session_file = session.session_manager.getSessionFile(),
        .session_id = session.session_manager.getSessionId(),
        .session_name = session.session_manager.getSessionName(),
        .user_messages = user_messages,
        .assistant_messages = assistant_messages,
        .tool_calls = tool_calls,
        .tool_results = tool_results,
        .total_messages = messages.len,
        .tokens = .{
            .input = total_input,
            .output = total_output,
            .cache_read = total_cache_read,
            .cache_write = total_cache_write,
            .total = total_input + total_output + total_cache_read + total_cache_write,
        },
        .cost = total_cost,
        .context_usage = getContextUsage(session),
    };
}

pub fn exportToJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    output_path: ?[]const u8,
) ![]const u8 {
    const resolved_path = try resolveExportPath(allocator, session, output_path, ".json");
    errdefer allocator.free(resolved_path);
    try session.session_manager.exportJson(allocator, io, resolved_path);
    return resolved_path;
}

pub fn exportToMarkdown(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    output_path: ?[]const u8,
) ![]const u8 {
    const resolved_path = try resolveExportPath(allocator, session, output_path, ".md");
    errdefer allocator.free(resolved_path);

    const stats = getSessionStats(session);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try writer.writer.print("# Session {s}\n\n", .{stats.session_name orelse stats.session_id});
    try writer.writer.print("- Session ID: `{s}`\n", .{stats.session_id});
    try writer.writer.print("- Session file: `{s}`\n", .{stats.session_file orelse "in-memory"});
    try writer.writer.print("- Working directory: `{s}`\n", .{session.cwd});
    try writer.writer.print("- Model: `{s}` / `{s}`\n", .{ session.agent.getModel().provider, session.agent.getModel().id });
    try writer.writer.print("- User messages: {d}\n", .{stats.user_messages});
    try writer.writer.print("- Assistant messages: {d}\n", .{stats.assistant_messages});
    try writer.writer.print("- Tool calls: {d}\n", .{stats.tool_calls});
    try writer.writer.print("- Tool results: {d}\n", .{stats.tool_results});
    try writer.writer.print("- Tokens: {d}\n", .{stats.tokens.total});
    try writer.writer.print("- Cost: {d:.4}\n\n", .{stats.cost});
    try writer.writer.writeAll("## Transcript\n\n");

    for (session.agent.getMessages(), 0..) |message, index| {
        try writer.writer.print("### {d}. {s}\n\n", .{ index + 1, messageTitle(message) });
        const text = try messageToMarkdown(allocator, message);
        defer allocator.free(text);
        if (text.len == 0) {
            try writer.writer.writeAll("_No text content_\n\n");
        } else {
            try writer.writer.print("{s}\n\n", .{text});
        }
    }

    try common.writeFileAbsolute(io, resolved_path, writer.written(), true);
    return resolved_path;
}

pub fn exportToHtml(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    output_path: ?[]const u8,
) ![]const u8 {
    const resolved_path = try resolveExportPath(allocator, session, output_path, ".html");
    errdefer allocator.free(resolved_path);

    const html = try renderSessionHtml(allocator, session);
    defer allocator.free(html);

    try common.writeFileAbsolute(io, resolved_path, html, true);
    return resolved_path;
}

pub fn exportFromFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    session_file: []const u8,
    output_path: ?[]const u8,
) ![]const u8 {
    var session = try session_mod.AgentSession.open(allocator, io, .{
        .session_file = session_file,
        .cwd_override = cwd,
    });
    defer session.deinit();

    if (output_path) |path| {
        if (std.mem.endsWith(u8, path, ".jsonl")) {
            return exportToJsonl(allocator, io, &session, path);
        }
        if (std.mem.endsWith(u8, path, ".json")) {
            return exportToJson(allocator, io, &session, path);
        }
        if (std.mem.endsWith(u8, path, ".md")) {
            return exportToMarkdown(allocator, io, &session, path);
        }
        if (!std.mem.endsWith(u8, path, ".html")) {
            return error.UnsupportedExportPath;
        }
    }

    return exportToHtml(allocator, io, &session, output_path);
}

fn resolveExportPath(
    allocator: std.mem.Allocator,
    session: *const session_mod.AgentSession,
    output_path: ?[]const u8,
    extension: []const u8,
) ![]const u8 {
    if (output_path) |path| {
        return common.resolvePath(allocator, session.cwd, path);
    }

    const base_dir = if (session.session_manager.getSessionDir().len > 0)
        session.session_manager.getSessionDir()
    else
        session.cwd;
    const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ session.session_manager.getSessionId(), extension });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &[_][]const u8{ base_dir, filename });
}

pub fn exportToJsonl(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const session_mod.AgentSession,
    output_path: []const u8,
) ![]const u8 {
    const session_file = session.session_manager.getSessionFile() orelse return error.SessionExportRequiresPersistentFile;
    const resolved_path = try common.resolvePath(allocator, session.cwd, output_path);
    errdefer allocator.free(resolved_path);

    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, session_file, allocator, .unlimited);
    defer allocator.free(bytes);
    try common.writeFileAbsolute(io, resolved_path, bytes, true);
    return resolved_path;
}

fn renderSessionHtml(allocator: std.mem.Allocator, session: *const session_mod.AgentSession) ![]u8 {
    const stats = getSessionStats(session);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    const title = stats.session_name orelse stats.session_id;
    try writer.writer.writeAll(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\  <meta charset="utf-8" />
        \\  <meta name="viewport" content="width=device-width, initial-scale=1" />
        \\  <title>
    );
    try writeEscapedHtml(&writer.writer, title);
    try writer.writer.writeAll(
        \\</title>
        \\  <style>
        \\    :root {
        \\      color-scheme: dark light;
        \\      --bg: #0f172a;
        \\      --panel: #111827;
        \\      --panel-alt: #0b1220;
        \\      --border: #334155;
        \\      --text: #e2e8f0;
        \\      --muted: #94a3b8;
        \\      --accent: #7aa2f7;
        \\      --accent-alt: #bb9af7;
        \\      --success: #9ece6a;
        \\      --warning: #e0af68;
        \\      --error: #f7768e;
        \\      --code-bg: #020617;
        \\      --inline-code-bg: rgba(148, 163, 184, 0.16);
        \\      --shadow: rgba(15, 23, 42, 0.35);
        \\      --tok-keyword: #7aa2f7;
        \\      --tok-string: #9ece6a;
        \\      --tok-number: #ff9e64;
        \\      --tok-comment: #64748b;
        \\      --tok-builtin: #bb9af7;
        \\      --user-accent: #38bdf8;
        \\      --assistant-accent: #a78bfa;
        \\      --tool-accent: #f59e0b;
        \\    }
        \\    :root[data-theme="light"] {
        \\      color-scheme: light;
        \\      --bg: #f8fafc;
        \\      --panel: #ffffff;
        \\      --panel-alt: #f1f5f9;
        \\      --border: #cbd5e1;
        \\      --text: #0f172a;
        \\      --muted: #475569;
        \\      --accent: #3451b2;
        \\      --accent-alt: #6f42c1;
        \\      --success: #2f8f4e;
        \\      --warning: #a05a00;
        \\      --error: #c1392b;
        \\      --code-bg: #e2e8f0;
        \\      --inline-code-bg: rgba(148, 163, 184, 0.18);
        \\      --shadow: rgba(15, 23, 42, 0.08);
        \\      --tok-keyword: #3451b2;
        \\      --tok-string: #2f8f4e;
        \\      --tok-number: #b45309;
        \\      --tok-comment: #64748b;
        \\      --tok-builtin: #7c3aed;
        \\      --user-accent: #0369a1;
        \\      --assistant-accent: #7c3aed;
        \\      --tool-accent: #b45309;
        \\    }
        \\    @media (prefers-color-scheme: light) {
        \\      :root:not([data-theme]) {
        \\        color-scheme: light;
        \\        --bg: #f8fafc;
        \\        --panel: #ffffff;
        \\        --panel-alt: #f1f5f9;
        \\        --border: #cbd5e1;
        \\        --text: #0f172a;
        \\        --muted: #475569;
        \\        --accent: #3451b2;
        \\        --accent-alt: #6f42c1;
        \\        --success: #2f8f4e;
        \\        --warning: #a05a00;
        \\        --error: #c1392b;
        \\        --code-bg: #e2e8f0;
        \\        --inline-code-bg: rgba(148, 163, 184, 0.18);
        \\        --shadow: rgba(15, 23, 42, 0.08);
        \\        --tok-keyword: #3451b2;
        \\        --tok-string: #2f8f4e;
        \\        --tok-number: #b45309;
        \\        --tok-comment: #64748b;
        \\        --tok-builtin: #7c3aed;
        \\        --user-accent: #0369a1;
        \\        --assistant-accent: #7c3aed;
        \\        --tool-accent: #b45309;
        \\      }
        \\    }
        \\    * { box-sizing: border-box; }
        \\    body {
        \\      margin: 0;
        \\      font-family: ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        \\      background: var(--bg);
        \\      color: var(--text);
        \\      line-height: 1.55;
        \\    }
        \\    main { max-width: 1080px; margin: 0 auto; padding: 24px; }
        \\    .card {
        \\      background: var(--panel);
        \\      border: 1px solid var(--border);
        \\      border-radius: 16px;
        \\      padding: 20px;
        \\      margin-bottom: 18px;
        \\      box-shadow: 0 20px 40px -32px var(--shadow);
        \\    }
        \\    .hero { display: flex; gap: 16px; align-items: flex-start; justify-content: space-between; flex-wrap: wrap; }
        \\    .hero h1 { margin: 0 0 8px; font-size: 1.9rem; }
        \\    .meta-grid {
        \\      display: grid;
        \\      grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
        \\      gap: 12px;
        \\      margin-top: 16px;
        \\    }
        \\    .meta-item {
        \\      border: 1px solid var(--border);
        \\      border-radius: 12px;
        \\      padding: 12px 14px;
        \\      background: var(--panel-alt);
        \\    }
        \\    .meta-item .label {
        \\      display: block;
        \\      font-size: 0.75rem;
        \\      letter-spacing: 0.06em;
        \\      text-transform: uppercase;
        \\      color: var(--muted);
        \\      margin-bottom: 4px;
        \\    }
        \\    .meta-item .value { font-weight: 600; }
        \\    .toolbar { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
        \\    .theme-toggle {
        \\      border: 1px solid var(--border);
        \\      background: var(--panel-alt);
        \\      color: var(--text);
        \\      border-radius: 999px;
        \\      padding: 8px 14px;
        \\      cursor: pointer;
        \\      font: inherit;
        \\    }
        \\    .theme-note { color: var(--muted); font-size: 0.9rem; }
        \\    .message-card { border-left: 4px solid var(--border); }
        \\    .message-card.role-user { border-left-color: var(--user-accent); }
        \\    .message-card.role-assistant { border-left-color: var(--assistant-accent); }
        \\    .message-card.role-tool-result { border-left-color: var(--tool-accent); }
        \\    .message-header {
        \\      display: flex;
        \\      align-items: center;
        \\      justify-content: space-between;
        \\      gap: 12px;
        \\      margin-bottom: 16px;
        \\      flex-wrap: wrap;
        \\    }
        \\    .message-header h2 { margin: 0; font-size: 1.05rem; }
        \\    .message-tags { display: flex; flex-wrap: wrap; gap: 8px; }
        \\    .badge {
        \\      display: inline-flex;
        \\      align-items: center;
        \\      gap: 6px;
        \\      border-radius: 999px;
        \\      padding: 4px 10px;
        \\      font-size: 0.78rem;
        \\      border: 1px solid var(--border);
        \\      background: var(--panel-alt);
        \\      color: var(--muted);
        \\    }
        \\    .badge-success { color: var(--success); }
        \\    .badge-warning { color: var(--warning); }
        \\    .badge-error { color: var(--error); }
        \\    .rich-text p { margin: 0 0 12px; }
        \\    .rich-text p:last-child { margin-bottom: 0; }
        \\    .inline-code,
        \\    code {
        \\      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
        \\    }
        \\    .inline-code {
        \\      background: var(--inline-code-bg);
        \\      border-radius: 6px;
        \\      padding: 0.1rem 0.35rem;
        \\      font-size: 0.92em;
        \\    }
        \\    .code-shell {
        \\      border: 1px solid var(--border);
        \\      border-radius: 12px;
        \\      overflow: hidden;
        \\      margin: 14px 0;
        \\      background: var(--code-bg);
        \\    }
        \\    .code-header {
        \\      display: flex;
        \\      align-items: center;
        \\      justify-content: space-between;
        \\      gap: 12px;
        \\      padding: 9px 12px;
        \\      border-bottom: 1px solid var(--border);
        \\      background: color-mix(in srgb, var(--panel) 75%, var(--code-bg));
        \\      color: var(--muted);
        \\      font-size: 0.82rem;
        \\      text-transform: uppercase;
        \\      letter-spacing: 0.04em;
        \\    }
        \\    .code-block {
        \\      margin: 0;
        \\      padding: 14px;
        \\      overflow-x: auto;
        \\      white-space: pre;
        \\      word-break: normal;
        \\      tab-size: 2;
        \\    }
        \\    .tool-list { display: grid; gap: 14px; margin-top: 16px; }
        \\    .tool-entry {
        \\      border: 1px solid var(--border);
        \\      border-radius: 12px;
        \\      padding: 14px;
        \\      background: var(--panel-alt);
        \\    }
        \\    .tool-entry h3 {
        \\      margin: 0 0 10px;
        \\      font-size: 0.95rem;
        \\      display: flex;
        \\      align-items: center;
        \\      gap: 8px;
        \\      flex-wrap: wrap;
        \\    }
        \\    .tool-entry .tool-id { color: var(--muted); font-size: 0.82rem; }
        \\    .tool-preview {
        \\      margin: 0 0 12px;
        \\      white-space: pre-wrap;
        \\      word-break: break-word;
        \\      background: var(--code-bg);
        \\      border-radius: 10px;
        \\      padding: 12px;
        \\      border: 1px solid var(--border);
        \\      font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", monospace;
        \\    }
        \\    .thinking-block {
        \\      margin: 14px 0;
        \\      border: 1px dashed var(--border);
        \\      border-radius: 12px;
        \\      padding: 12px 14px;
        \\      background: color-mix(in srgb, var(--panel-alt) 85%, transparent);
        \\    }
        \\    .thinking-block summary {
        \\      cursor: pointer;
        \\      font-weight: 600;
        \\      color: var(--muted);
        \\      margin-bottom: 12px;
        \\    }
        \\    .image-block {
        \\      margin: 14px 0;
        \\      border: 1px solid var(--border);
        \\      border-radius: 12px;
        \\      padding: 12px;
        \\      background: var(--panel-alt);
        \\    }
        \\    .image-block img { max-width: 100%; border-radius: 8px; display: block; }
        \\    .image-block figcaption { color: var(--muted); font-size: 0.82rem; margin-top: 8px; }
        \\    .tok-keyword { color: var(--tok-keyword); font-weight: 600; }
        \\    .tok-string { color: var(--tok-string); }
        \\    .tok-number { color: var(--tok-number); }
        \\    .tok-comment { color: var(--tok-comment); font-style: italic; }
        \\    .tok-builtin { color: var(--tok-builtin); }
        \\    .muted { color: var(--muted); }
        \\    .empty { color: var(--muted); font-style: italic; }
        \\    a { color: var(--accent); }
        \\  </style>
        \\</head>
        \\<body>
        \\  <main>
        \\    <section class="card hero">
        \\      <div>
        \\        <h1>
    );
    try writeEscapedHtml(&writer.writer, title);
    try writer.writer.writeAll(
        \\</h1>
        \\        <p class="muted">Standalone HTML export with theme switching, syntax highlighted code blocks, and structured tool rendering.</p>
        \\      </div>
        \\      <div class="toolbar">
        \\        <button type="button" class="theme-toggle" id="theme-toggle">Theme: System</button>
        \\        <span class="theme-note">Cycle exported themes</span>
        \\      </div>
        \\    </section>
        \\    <section class="card">
        \\      <div class="meta-grid">
        \\        <div class="meta-item"><span class="label">Session ID</span><span class="value"><code>
    );
    try writeEscapedHtml(&writer.writer, stats.session_id);
    try writer.writer.writeAll(
        \\</code></span></div>
        \\        <div class="meta-item"><span class="label">Session file</span><span class="value"><code>
    );
    try writeEscapedHtml(&writer.writer, stats.session_file orelse "in-memory");
    try writer.writer.writeAll(
        \\</code></span></div>
        \\        <div class="meta-item"><span class="label">Working directory</span><span class="value"><code>
    );
    try writeEscapedHtml(&writer.writer, session.cwd);
    try writer.writer.writeAll(
        \\</code></span></div>
        \\        <div class="meta-item"><span class="label">Model</span><span class="value"><code>
    );
    try writeEscapedHtml(&writer.writer, session.agent.getModel().provider);
    try writer.writer.writeAll(" / ");
    try writeEscapedHtml(&writer.writer, session.agent.getModel().id);
    try writer.writer.writeAll(
        \\</code></span></div>
        \\        <div class="meta-item"><span class="label">Messages</span><span class="value">
    );
    try writer.writer.print("{d}", .{stats.total_messages});
    try writer.writer.writeAll(
        \\</span></div>
        \\        <div class="meta-item"><span class="label">Tool calls</span><span class="value">
    );
    try writer.writer.print("{d}", .{stats.tool_calls});
    try writer.writer.writeAll(
        \\</span></div>
        \\        <div class="meta-item"><span class="label">Tool results</span><span class="value">
    );
    try writer.writer.print("{d}", .{stats.tool_results});
    try writer.writer.writeAll(
        \\</span></div>
        \\        <div class="meta-item"><span class="label">Tokens</span><span class="value">
    );
    try writer.writer.print("{d}", .{stats.tokens.total});
    try writer.writer.writeAll(
        \\</span></div>
        \\        <div class="meta-item"><span class="label">Cost</span><span class="value">$
    );
    try writer.writer.print("{d:.4}", .{stats.cost});
    try writer.writer.writeAll(
        \\</span></div>
    );
    if (stats.context_usage) |usage| {
        try writer.writer.writeAll(
            \\        <div class="meta-item"><span class="label">Context usage</span><span class="value">
        );
        try writer.writer.print("{d}/{d}", .{ usage.tokens orelse 0, usage.context_window });
        try writer.writer.writeAll(" (");
        try writer.writer.print("{d:.1}", .{usage.percent orelse 0});
        try writer.writer.writeAll(
            \\%)</span></div>
        );
    }
    try writer.writer.writeAll(
        \\      </div>
        \\    </section>
    );

    for (session.agent.getMessages(), 0..) |message, index| {
        const text = try messageToMarkdown(allocator, message);
        defer allocator.free(text);

        try writer.writer.writeAll(
            \\
            \\    <section class="card message-card role-
        );
        try writer.writer.writeAll(messageRoleClass(message));
        try writer.writer.writeAll(
            \\">
            \\      <div class="message-header">
            \\        <h2>
        );
        try writer.writer.print("{d}. ", .{index + 1});
        try writeEscapedHtml(&writer.writer, messageTitle(message));
        try writer.writer.writeAll(
            \\</h2>
            \\        <div class="message-tags">
        );
        switch (message) {
            .assistant => |assistant_message| {
                if (assistant_message.tool_calls) |calls| {
                    try writer.writer.writeAll("<span class=\"badge\">");
                    try writer.writer.print("{d} tool call", .{calls.len});
                    if (calls.len != 1) try writer.writer.writeByte('s');
                    try writer.writer.writeAll("</span>");
                }
                if (assistant_message.stop_reason == .error_reason) {
                    try writer.writer.writeAll("<span class=\"badge badge-error\">error</span>");
                } else if (assistant_message.stop_reason == .aborted) {
                    try writer.writer.writeAll("<span class=\"badge badge-warning\">interrupted</span>");
                } else {
                    try writer.writer.writeAll("<span class=\"badge badge-success\">complete</span>");
                }
            },
            .tool_result => |tool_result| {
                if (tool_result.is_error) {
                    try writer.writer.writeAll("<span class=\"badge badge-error\">error result</span>");
                } else {
                    try writer.writer.writeAll("<span class=\"badge badge-success\">result</span>");
                }
                try writer.writer.writeAll("<span class=\"badge\">");
                try writeEscapedHtml(&writer.writer, tool_result.tool_name);
                try writer.writer.writeAll("</span>");
            },
            .user => {
                try writer.writer.writeAll("<span class=\"badge\">user prompt</span>");
            },
        }
        try writer.writer.writeAll(
            \\        </div>
            \\      </div>
        );
        if (text.len == 0) {
            try writer.writer.writeAll("<p class=\"empty\">No text content.</p>");
        }
        try writeMessageHtml(&writer.writer, allocator, message);
        try writer.writer.writeAll(
            \\    </section>
        );
    }

    try writer.writer.writeAll(
        \\
        \\  </main>
        \\  <script>
        \\    (() => {
        \\      const htmlEscape = (value) => value
        \\        .replace(/&/g, "&amp;")
        \\        .replace(/</g, "&lt;")
        \\        .replace(/>/g, "&gt;");
        \\
        \\      const BUILTIN = new Set(["true", "false", "null", "undefined"]);
        \\      const KEYWORDS = {
        \\        default: new Set(["const", "let", "var", "fn", "pub", "struct", "enum", "union", "if", "else", "switch", "return", "for", "while", "break", "continue", "try", "catch", "defer", "errdefer", "async", "await", "function", "class", "interface", "type", "import", "export", "new"]),
        \\        json: new Set([]),
        \\        bash: new Set(["if", "then", "else", "fi", "for", "do", "done", "case", "esac", "while", "function", "local", "export"]),
        \\        zig: new Set(["const", "var", "fn", "pub", "struct", "enum", "union", "opaque", "error", "return", "if", "else", "switch", "for", "while", "break", "continue", "try", "catch", "defer", "errdefer", "usingnamespace", "comptime", "inline", "packed"]),
        \\      };
        \\
        \\      const normalizeLanguage = (language) => {
        \\        const lower = (language || "").toLowerCase();
        \\        if (lower === "sh" || lower === "shell" || lower === "zsh") return "bash";
        \\        if (lower === "js" || lower === "jsx" || lower === "ts" || lower === "tsx" || lower === "javascript" || lower === "typescript") return "default";
        \\        if (lower === "json" || lower === "bash" || lower === "zig") return lower;
        \\        return "default";
        \\      };
        \\
        \\      const isIdentStart = (char) => /[A-Za-z_$]/.test(char);
        \\      const isIdent = (char) => /[A-Za-z0-9_$-]/.test(char);
        \\      const isDigit = (char) => /[0-9]/.test(char);
        \\      const wrap = (cls, value) => `<span class="${cls}">${htmlEscape(value)}</span>`;
        \\
        \\      const highlight = (code, language) => {
        \\        const lang = normalizeLanguage(language);
        \\        const keywords = KEYWORDS[lang] || KEYWORDS.default;
        \\        let out = "";
        \\        let i = 0;
        \\        while (i < code.length) {
        \\          const rest = code.slice(i);
        \\          if ((lang === "bash" && rest.startsWith("#")) || rest.startsWith("//")) {
        \\            const end = code.indexOf("\n", i);
        \\            const stop = end === -1 ? code.length : end;
        \\            out += wrap("tok-comment", code.slice(i, stop));
        \\            i = stop;
        \\            continue;
        \\          }
        \\          if (rest.startsWith("/*")) {
        \\            const end = code.indexOf("*/", i + 2);
        \\            const stop = end === -1 ? code.length : end + 2;
        \\            out += wrap("tok-comment", code.slice(i, stop));
        \\            i = stop;
        \\            continue;
        \\          }
        \\          const quote = code[i];
        \\          if (quote === "'" || quote === "\"" || quote === "`") {
        \\            let stop = i + 1;
        \\            while (stop < code.length) {
        \\              if (code[stop] === "\\" && stop + 1 < code.length) {
        \\                stop += 2;
        \\                continue;
        \\              }
        \\              if (code[stop] === quote) {
        \\                stop += 1;
        \\                break;
        \\              }
        \\              stop += 1;
        \\            }
        \\            out += wrap("tok-string", code.slice(i, stop));
        \\            i = stop;
        \\            continue;
        \\          }
        \\          if ((code[i] === "-" && isDigit(code[i + 1])) || isDigit(code[i])) {
        \\            let stop = i + 1;
        \\            while (stop < code.length && /[0-9._xXa-fA-F]/.test(code[stop])) stop += 1;
        \\            out += wrap("tok-number", code.slice(i, stop));
        \\            i = stop;
        \\            continue;
        \\          }
        \\          if (isIdentStart(code[i])) {
        \\            let stop = i + 1;
        \\            while (stop < code.length && isIdent(code[stop])) stop += 1;
        \\            const ident = code.slice(i, stop);
        \\            if (keywords.has(ident)) out += wrap("tok-keyword", ident);
        \\            else if (BUILTIN.has(ident)) out += wrap("tok-builtin", ident);
        \\            else out += htmlEscape(ident);
        \\            i = stop;
        \\            continue;
        \\          }
        \\          out += htmlEscape(code[i]);
        \\          i += 1;
        \\        }
        \\        return out;
        \\      };
        \\
        \\      document.querySelectorAll("code[data-language]").forEach((node) => {
        \\        node.innerHTML = highlight(node.textContent || "", node.dataset.language || "text");
        \\      });
        \\
        \\      const themeButton = document.getElementById("theme-toggle");
        \\      if (!themeButton) return;
        \\      const key = "pi-export-theme";
        \\      const root = document.documentElement;
        \\      const labels = { system: "Theme: System", dark: "Theme: Dark", light: "Theme: Light" };
        \\      const order = ["system", "dark", "light"];
        \\      const applyTheme = (value) => {
        \\        if (value === "system") root.removeAttribute("data-theme");
        \\        else root.setAttribute("data-theme", value);
        \\        themeButton.textContent = labels[value] || labels.system;
        \\      };
        \\      const initial = window.localStorage.getItem(key) || "system";
        \\      applyTheme(initial);
        \\      themeButton.addEventListener("click", () => {
        \\        const current = root.getAttribute("data-theme") || "system";
        \\        const next = order[(order.indexOf(current) + 1) % order.length];
        \\        window.localStorage.setItem(key, next);
        \\        applyTheme(next);
        \\      });
        \\    })();
        \\  </script>
        \\</body>
        \\</html>
        \\
    );

    return try allocator.dupe(u8, writer.written());
}

fn messageRoleClass(message: agent.AgentMessage) []const u8 {
    return switch (message) {
        .user => "user",
        .assistant => "assistant",
        .tool_result => "tool-result",
    };
}

fn writeMessageHtml(writer: *std.Io.Writer, allocator: std.mem.Allocator, message: agent.AgentMessage) !void {
    switch (message) {
        .user => |user_message| try writeContentBlocksHtml(writer, user_message.content),
        .assistant => |assistant_message| {
            try writeContentBlocksHtml(writer, assistant_message.content);
            if (assistant_message.tool_calls) |tool_calls| {
                try writer.writeAll("<div class=\"tool-list\">");
                for (tool_calls) |tool_call| {
                    try writeToolCallHtml(writer, allocator, tool_call);
                }
                try writer.writeAll("</div>");
            }
        },
        .tool_result => |tool_result| try writeToolResultHtml(writer, allocator, tool_result),
    }
}

fn writeToolCallHtml(writer: *std.Io.Writer, allocator: std.mem.Allocator, tool_call: ai.ToolCall) !void {
    const summary = try formatting.formatToolCall(allocator, tool_call.name, tool_call.arguments);
    defer allocator.free(summary);
    const args = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{ .whitespace = .indent_2 });
    defer allocator.free(args);

    try writer.writeAll("<article class=\"tool-entry tool-call\"><h3><span class=\"badge\">tool call</span> ");
    try writeEscapedHtml(writer, tool_call.name);
    try writer.writeAll("</h3><div class=\"tool-id\">");
    try writeEscapedHtml(writer, tool_call.id);
    try writer.writeAll("</div>");
    if (summary.len > 0) {
        try writer.writeAll("<pre class=\"tool-preview\">");
        try writeEscapedHtml(writer, summary);
        try writer.writeAll("</pre>");
    }
    try writeCodeBlockHtml(writer, "json", args);
    try writer.writeAll("</article>");
}

fn writeToolResultHtml(writer: *std.Io.Writer, allocator: std.mem.Allocator, tool_result: anytype) !void {
    const summary = try formatting.formatToolResult(allocator, tool_result.tool_name, tool_result.content, tool_result.is_error);
    defer allocator.free(summary);

    try writer.writeAll("<article class=\"tool-entry tool-result\"><h3><span class=\"badge ");
    if (tool_result.is_error) {
        try writer.writeAll("badge-error\">error result");
    } else {
        try writer.writeAll("badge-success\">tool result");
    }
    try writer.writeAll("</span> ");
    try writeEscapedHtml(writer, tool_result.tool_name);
    try writer.writeAll("</h3><div class=\"tool-id\">");
    try writeEscapedHtml(writer, tool_result.tool_call_id);
    try writer.writeAll("</div>");
    if (summary.len > 0) {
        try writer.writeAll("<pre class=\"tool-preview\">");
        try writeEscapedHtml(writer, summary);
        try writer.writeAll("</pre>");
    }
    try writeContentBlocksHtml(writer, tool_result.content);
    try writer.writeAll("</article>");
}

fn writeContentBlocksHtml(writer: *std.Io.Writer, blocks: []const ai.ContentBlock) !void {
    var wrote_any = false;
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, &std.ascii.whitespace).len == 0) continue;
                try writeRichTextHtml(writer, text.text);
                wrote_any = true;
            },
            .thinking => |thinking| {
                if (std.mem.trim(u8, thinking.thinking, &std.ascii.whitespace).len == 0) continue;
                try writer.writeAll("<details class=\"thinking-block\"><summary>Thinking</summary>");
                try writeRichTextHtml(writer, thinking.thinking);
                try writer.writeAll("</details>");
                wrote_any = true;
            },
            .image => |image| {
                try writer.writeAll("<figure class=\"image-block\"><img alt=\"Session image\" src=\"data:");
                try writeEscapedHtml(writer, image.mime_type);
                try writer.writeAll(";base64,");
                try writeEscapedHtml(writer, image.data);
                try writer.writeAll("\" /><figcaption>");
                try writeEscapedHtml(writer, image.mime_type);
                try writer.writeAll("</figcaption></figure>");
                wrote_any = true;
            },
        }
    }

    if (!wrote_any) {
        try writer.writeAll("<p class=\"empty\">No text content.</p>");
    }
}

fn writeRichTextHtml(writer: *std.Io.Writer, text: []const u8) !void {
    if (std.mem.trim(u8, text, &std.ascii.whitespace).len == 0) return;

    try writer.writeAll("<div class=\"rich-text\">");
    var remaining = text;
    var rendered_any = false;
    while (std.mem.indexOf(u8, remaining, "```")) |open_index| {
        const before = remaining[0..open_index];
        if (std.mem.trim(u8, before, &std.ascii.whitespace).len > 0) {
            try writeProseHtml(writer, before);
            rendered_any = true;
        }

        const after_open = remaining[open_index + 3 ..];
        const language_line_end = std.mem.indexOfScalar(u8, after_open, '\n') orelse {
            try writeProseHtml(writer, remaining);
            rendered_any = true;
            remaining = "";
            break;
        };
        const language = std.mem.trim(u8, after_open[0..language_line_end], " \t\r");
        const after_language = after_open[language_line_end + 1 ..];
        const close_index = std.mem.indexOf(u8, after_language, "```") orelse {
            try writeProseHtml(writer, remaining);
            rendered_any = true;
            remaining = "";
            break;
        };
        const code = trimTrailingNewlines(after_language[0..close_index]);
        try writeCodeBlockHtml(writer, language, code);
        rendered_any = true;
        remaining = after_language[close_index + 3 ..];
    }

    if (std.mem.trim(u8, remaining, &std.ascii.whitespace).len > 0) {
        try writeProseHtml(writer, remaining);
        rendered_any = true;
    }

    if (!rendered_any) {
        try writer.writeAll("<p class=\"empty\">No text content.</p>");
    }
    try writer.writeAll("</div>");
}

fn writeProseHtml(writer: *std.Io.Writer, text: []const u8) !void {
    var remaining = text;
    while (remaining.len > 0) {
        const separator_index = std.mem.indexOf(u8, remaining, "\n\n");
        const paragraph = std.mem.trim(u8, remaining[0 .. separator_index orelse remaining.len], " \t\r\n");
        if (paragraph.len > 0) {
            try writer.writeAll("<p>");
            try writeInlineHtml(writer, paragraph);
            try writer.writeAll("</p>");
        }
        if (separator_index) |index| {
            remaining = remaining[index + 2 ..];
        } else {
            break;
        }
    }
}

fn writeInlineHtml(writer: *std.Io.Writer, text: []const u8) !void {
    var remaining = text;
    while (remaining.len > 0) {
        if (remaining[0] == '`') {
            if (std.mem.indexOfScalar(u8, remaining[1..], '`')) |end_index| {
                try writer.writeAll("<code class=\"inline-code\">");
                try writeEscapedHtml(writer, remaining[1 .. 1 + end_index]);
                try writer.writeAll("</code>");
                remaining = remaining[end_index + 2 ..];
                continue;
            }
        }

        const next_special = findNextInlineSpecial(remaining);
        const plain = remaining[0..next_special];
        if (plain.len > 0) {
            try writeEscapedHtml(writer, plain);
        }
        if (next_special >= remaining.len) break;
        switch (remaining[next_special]) {
            '\n' => try writer.writeAll("<br />"),
            else => try writeEscapedHtml(writer, remaining[next_special .. next_special + 1]),
        }
        remaining = remaining[next_special + 1 ..];
    }
}

fn findNextInlineSpecial(text: []const u8) usize {
    for (text, 0..) |byte, index| {
        if (byte == '\n' or byte == '`') return index;
    }
    return text.len;
}

fn writeCodeBlockHtml(writer: *std.Io.Writer, language: []const u8, code: []const u8) !void {
    const effective_language = if (language.len > 0) language else "text";
    try writer.writeAll("<div class=\"code-shell\"><div class=\"code-header\"><span>");
    try writeEscapedHtml(writer, effective_language);
    try writer.writeAll("</span></div><pre class=\"code-block\"><code data-language=\"");
    try writeEscapedHtml(writer, effective_language);
    try writer.writeAll("\" class=\"language-");
    try writeEscapedHtml(writer, effective_language);
    try writer.writeAll("\">");
    try writeEscapedHtml(writer, code);
    try writer.writeAll("</code></pre></div>");
}

fn trimTrailingNewlines(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) : (end -= 1) {}
    return text[0..end];
}

fn writeEscapedHtml(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&#39;"),
            else => try writer.writeByte(byte),
        }
    }
}

fn messageTitle(message: agent.AgentMessage) []const u8 {
    return switch (message) {
        .user => "User",
        .assistant => "Assistant",
        .tool_result => "Tool Result",
    };
}

fn messageToMarkdown(allocator: std.mem.Allocator, message: agent.AgentMessage) ![]u8 {
    return switch (message) {
        .user => |user_message| blocksToText(allocator, user_message.content),
        .assistant => |assistant_message| blk: {
            const text = try blocksToText(allocator, assistant_message.content);
            if (text.len > 0) break :blk text;
            if (assistant_message.tool_calls) |calls| {
                var writer: std.Io.Writer.Allocating = .init(allocator);
                defer writer.deinit();
                for (calls, 0..) |tool_call, index| {
                    if (index > 0) try writer.writer.writeAll("\n");
                    const args = try std.json.Stringify.valueAlloc(allocator, tool_call.arguments, .{ .whitespace = .indent_2 });
                    defer allocator.free(args);
                    try writer.writer.print("- `{s}` `{s}`\n```json\n{s}\n```", .{ tool_call.name, tool_call.id, args });
                }
                break :blk try allocator.dupe(u8, writer.written());
            }
            break :blk allocator.dupe(u8, "");
        },
        .tool_result => |tool_result| blk: {
            const text = try blocksToText(allocator, tool_result.content);
            defer allocator.free(text);
            if (text.len == 0) {
                break :blk try std.fmt.allocPrint(allocator, "`{s}` returned no text content", .{tool_result.tool_name});
            }
            break :blk try std.fmt.allocPrint(allocator, "`{s}`\n\n{s}", .{ tool_result.tool_name, text });
        },
    };
}

fn blocksToText(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    var wrote_any = false;
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                if (text.text.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.writeAll(text.text);
                wrote_any = true;
            },
            .thinking => |thinking| {
                if (thinking.thinking.len == 0) continue;
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.print("_Thinking:_ {s}", .{thinking.thinking});
                wrote_any = true;
            },
            .image => |image| {
                if (wrote_any) try writer.writer.writeAll("\n");
                try writer.writer.print("![image](data:{s};base64,{s})", .{ image.mime_type, image.data });
                wrote_any = true;
            },
        }
    }

    return try allocator.dupe(u8, writer.written());
}

fn getContextUsage(session: *const session_mod.AgentSession) ?ContextUsage {
    const context_window = session.agent.getModel().context_window;
    if (context_window == 0) return null;

    const tokens = estimateContextTokens(session.agent.getMessages());
    return .{
        .tokens = tokens,
        .context_window = context_window,
        .percent = (@as(f64, @floatFromInt(tokens)) / @as(f64, @floatFromInt(context_window))) * 100.0,
    };
}

fn estimateContextTokens(messages: []const agent.AgentMessage) u32 {
    var total: u32 = 0;
    for (messages) |message| {
        total +|= estimateMessageTokens(message);
    }
    return total;
}

fn estimateMessageTokens(message: agent.AgentMessage) u32 {
    var chars: usize = 0;
    switch (message) {
        .user => |user_message| chars += estimateContentBlockChars(user_message.content),
        .assistant => |assistant_message| {
            if (assistant_message.stop_reason == .error_reason) return 0;
            chars += estimateContentBlockChars(assistant_message.content);
            if (assistant_message.tool_calls) |calls| {
                for (calls) |call| {
                    chars += call.name.len;
                    chars += jsonValueCharCount(call.arguments);
                }
            }
        },
        .tool_result => |tool_result| chars += estimateContentBlockChars(tool_result.content),
    }
    return @intCast((chars + 3) / 4);
}

fn estimateContentBlockChars(blocks: []const ai.ContentBlock) usize {
    var chars: usize = 0;
    for (blocks) |block| {
        switch (block) {
            .text => |text| chars += text.text.len,
            .thinking => |thinking| chars += thinking.thinking.len,
            .image => chars += 4800,
        }
    }
    return chars;
}

fn jsonValueCharCount(value: std.json.Value) usize {
    return switch (value) {
        .null => 4,
        .bool => |bool_value| if (bool_value) 4 else 5,
        .integer => |integer| std.fmt.count("{}", .{integer}),
        .float => |float_value| std.fmt.count("{d}", .{float_value}),
        .number_string => |number_string| number_string.len,
        .string => |string| string.len,
        .array => |array| blk: {
            var total: usize = 2;
            for (array.items, 0..) |item, index| {
                if (index > 0) total += 1;
                total += jsonValueCharCount(item);
            }
            break :blk total;
        },
        .object => |object| blk: {
            var total: usize = 2;
            var iterator = object.iterator();
            var first = true;
            while (iterator.next()) |entry| {
                if (!first) total += 1;
                first = false;
                total += entry.key_ptr.*.len + jsonValueCharCount(entry.value_ptr.*) + 1;
            }
            break :blk total;
        },
    };
}

test "session advanced stats and exports cover markdown json and html output" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const relative_dir = try std.fs.path.join(allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "sessions",
    });
    defer allocator.free(relative_dir);

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const absolute_dir = try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_dir });
    defer allocator.free(absolute_dir);

    var session = try session_mod.AgentSession.create(allocator, std.testing.io, .{
        .cwd = "/tmp/project",
        .system_prompt = "system",
        .model = agent.DEFAULT_MODEL,
        .session_dir = absolute_dir,
    });
    defer session.deinit();

    var user = try makeUserMessage("document this session with `inline code`", 1);
    defer session_manager_mod.deinitMessage(allocator, &user);
    _ = try session.session_manager.appendMessage(user);

    var assistant = try makeAssistantMessage(
        "done\n\n```zig\nconst answer: i32 = 42;\n```",
        "{\"path\":\"README.md\",\"offset\":2}",
        2,
    );
    defer session_manager_mod.deinitMessage(allocator, &assistant);
    _ = try session.session_manager.appendMessage(assistant);

    var tool_result = try makeToolResultMessage(
        "call-read-1",
        "read",
        "```json\n{\"answer\":42}\n```",
        3,
    );
    defer session_manager_mod.deinitMessage(allocator, &tool_result);
    _ = try session.session_manager.appendMessage(tool_result);

    try session.agent.setMessages(&[_]agent.AgentMessage{ user, assistant, tool_result });

    const stats = getSessionStats(&session);
    try std.testing.expectEqual(@as(usize, 1), stats.user_messages);
    try std.testing.expectEqual(@as(usize, 1), stats.assistant_messages);
    try std.testing.expectEqual(@as(usize, 1), stats.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), stats.tool_results);

    const json_path = try exportToJson(allocator, std.testing.io, &session, null);
    defer allocator.free(json_path);
    const markdown_path = try exportToMarkdown(allocator, std.testing.io, &session, null);
    defer allocator.free(markdown_path);
    const html_path = try exportToHtml(allocator, std.testing.io, &session, null);
    defer allocator.free(html_path);

    const json_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, json_path, allocator, .limited(1024 * 1024));
    defer allocator.free(json_bytes);
    const markdown_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, markdown_path, allocator, .limited(1024 * 1024));
    defer allocator.free(markdown_bytes);
    const html_bytes = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, html_path, allocator, .limited(1024 * 1024));
    defer allocator.free(html_bytes);

    try std.testing.expect(std.mem.indexOf(u8, json_bytes, "\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_bytes, "# Session") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown_bytes, "document this session") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "document this session") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "theme-toggle") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "language-zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "tool-entry tool-call") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "tool-entry tool-result") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "call-read-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html_bytes, "const answer: i32 = 42;") != null);
}

fn makeUserMessage(text: []const u8, timestamp: i64) !agent.AgentMessage {
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, text) } };
    return .{ .user = .{
        .role = try std.testing.allocator.dupe(u8, "user"),
        .content = blocks,
        .timestamp = timestamp,
    } };
}

fn makeAssistantMessage(text: []const u8, args_json: []const u8, timestamp: i64) !agent.AgentMessage {
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, text) } };
    const parsed_args = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, args_json, .{});
    defer parsed_args.deinit();
    const tool_calls = try std.testing.allocator.alloc(ai.ToolCall, 1);
    errdefer std.testing.allocator.free(tool_calls);
    tool_calls[0] = .{
        .id = try std.testing.allocator.dupe(u8, "call-read-1"),
        .name = try std.testing.allocator.dupe(u8, "read"),
        .arguments = try common.cloneJsonValue(std.testing.allocator, parsed_args.value),
    };
    return .{ .assistant = .{
        .role = try std.testing.allocator.dupe(u8, "assistant"),
        .content = blocks,
        .tool_calls = tool_calls,
        .api = try std.testing.allocator.dupe(u8, agent.DEFAULT_MODEL.api),
        .provider = try std.testing.allocator.dupe(u8, agent.DEFAULT_MODEL.provider),
        .model = try std.testing.allocator.dupe(u8, agent.DEFAULT_MODEL.id),
        .usage = ai.Usage.init(),
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

fn makeToolResultMessage(tool_call_id: []const u8, tool_name: []const u8, text: []const u8, timestamp: i64) !agent.AgentMessage {
    const blocks = try std.testing.allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try std.testing.allocator.dupe(u8, text) } };
    return .{ .tool_result = .{
        .role = try std.testing.allocator.dupe(u8, "toolResult"),
        .tool_call_id = try std.testing.allocator.dupe(u8, tool_call_id),
        .tool_name = try std.testing.allocator.dupe(u8, tool_name),
        .content = blocks,
        .timestamp = timestamp,
    } };
}
