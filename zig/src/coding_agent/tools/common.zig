const std = @import("std");
const ai = @import("ai");
const provider_json = ai.provider_json;

pub fn makeTextContent(allocator: std.mem.Allocator, text: []const u8) ![]const ai.ContentBlock {
    const blocks = try allocator.alloc(ai.ContentBlock, 1);
    blocks[0] = .{
        .text = .{
            .text = try allocator.dupe(u8, text),
        },
    };
    return blocks;
}

pub fn deinitContentBlocks(allocator: std.mem.Allocator, blocks: []const ai.ContentBlock) void {
    for (blocks) |block| {
        switch (block) {
            .text => |text| {
                allocator.free(text.text);
                if (text.text_signature) |signature| allocator.free(signature);
            },
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
            .thinking => |thinking| {
                allocator.free(thinking.thinking);
                if (thinking.thinking_signature) |signature| allocator.free(signature);
                if (thinking.signature) |signature| allocator.free(signature);
            },
            .tool_call => |tool_call| {
                allocator.free(tool_call.id);
                allocator.free(tool_call.name);
                if (tool_call.thought_signature) |signature| allocator.free(signature);
                provider_json.freeValue(allocator, tool_call.arguments);
            },
        }
    }
    allocator.free(blocks);
}

pub fn resolvePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) {
        return allocator.dupe(u8, path);
    }
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, path });
}

pub fn writeFileAbsolute(io: std.Io, absolute_path: []const u8, data: []const u8, make_path: bool) !void {
    var atomic_file = try std.Io.Dir.createFileAtomic(.cwd(), io, absolute_path, .{
        .make_path = make_path,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [1024]u8 = undefined;
    var file_writer = atomic_file.file.writer(io, &buffer);
    try file_writer.interface.writeAll(data);
    try file_writer.flush();
    try atomic_file.replace(io);
}

pub const cloneJsonValue = provider_json.cloneValue;
pub const deinitJsonValue = provider_json.freeValue;
