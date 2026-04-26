const std = @import("std");
const ai = @import("ai");
const cli = @import("args.zig");
const config_mod = @import("../coding_agent/config.zig");

pub const CliStdin = struct {
    is_tty: bool = true,
    content: ?[]const u8 = null,
    owns_content: bool = false,

    pub fn deinit(self: *CliStdin, allocator: std.mem.Allocator) void {
        if (self.owns_content and self.content != null) allocator.free(self.content.?);
        self.* = .{};
    }
};

pub const PreparedInitialInput = struct {
    prompt: ?[]u8 = null,
    images: []ai.ImageContent = &.{},

    pub fn deinit(self: *PreparedInitialInput, allocator: std.mem.Allocator) void {
        if (self.prompt) |prompt| allocator.free(prompt);
        if (self.images.len > 0) {
            for (self.images) |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            }
            allocator.free(self.images);
        }
        self.* = .{};
    }
};

pub fn stdinIsTty(io: std.Io) bool {
    return std.Io.File.stdin().isTty(io) catch true;
}

pub fn detectCliStdin(allocator: std.mem.Allocator, io: std.Io, mode: cli.Mode) !CliStdin {
    if (mode == .rpc or stdinIsTty(io)) return .{};

    const content = try readPipedStdin(allocator, io);
    return .{
        .is_tty = false,
        .content = content,
        .owns_content = content != null,
    };
}

fn readPipedStdin(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    var collected = std.ArrayList(u8).empty;
    defer collected.deinit(allocator);

    while (true) {
        const byte = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try collected.append(allocator, byte);
    }

    const trimmed = std.mem.trim(u8, collected.items, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

pub fn prepareInitialInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    cwd: []const u8,
    file_args: ?[]const []const u8,
    prompt: ?[]const u8,
    stdin_content: ?[]const u8,
    stderr: *std.Io.Writer,
) !PreparedInitialInput {
    var file_text = std.ArrayList(u8).empty;
    defer file_text.deinit(allocator);
    var images = std.ArrayList(ai.ImageContent).empty;
    errdefer {
        for (images.items) |image| {
            allocator.free(image.data);
            allocator.free(image.mime_type);
        }
        images.deinit(allocator);
    }

    if (file_args) |paths| {
        for (paths) |path| {
            const absolute_path = try config_mod.expandPath(allocator, env_map, path, cwd);
            defer allocator.free(absolute_path);

            const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, absolute_path, allocator, .unlimited) catch |err| {
                switch (err) {
                    error.FileNotFound => try stderr.print("Error: File not found: {s}\n", .{absolute_path}),
                    else => try stderr.print("Error: Could not read file {s}: {s}\n", .{ absolute_path, @errorName(err) }),
                }
                return error.CliInputFailed;
            };
            defer allocator.free(bytes);

            if (bytes.len == 0) continue;

            if (detectImageMime(bytes)) |mime_type| {
                const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
                _ = std.base64.standard.Encoder.encode(encoded, bytes);

                try images.append(allocator, .{
                    .data = encoded,
                    .mime_type = try allocator.dupe(u8, mime_type),
                });

                const note = try std.fmt.allocPrint(allocator, "<file name=\"{s}\"></file>\n", .{absolute_path});
                defer allocator.free(note);
                try file_text.appendSlice(allocator, note);
            } else {
                const header = try std.fmt.allocPrint(allocator, "<file name=\"{s}\">\n", .{absolute_path});
                defer allocator.free(header);
                try file_text.appendSlice(allocator, header);
                try file_text.appendSlice(allocator, bytes);
                try file_text.appendSlice(allocator, "\n</file>\n");
            }
        }
    }

    var prompt_builder = std.ArrayList(u8).empty;
    defer prompt_builder.deinit(allocator);
    if (stdin_content) |content| try prompt_builder.appendSlice(allocator, content);
    if (file_text.items.len > 0) try prompt_builder.appendSlice(allocator, file_text.items);
    if (prompt) |text| try prompt_builder.appendSlice(allocator, text);

    return .{
        .prompt = if (prompt_builder.items.len > 0)
            try prompt_builder.toOwnedSlice(allocator)
        else
            null,
        .images = try images.toOwnedSlice(allocator),
    };
}

fn detectImageMime(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) {
        return "image/gif";
    }
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        return "image/webp";
    }
    return null;
}
