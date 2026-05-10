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

/// Schema helpers — shared across all built-in tools.

pub fn schemaProperty(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    description: []const u8,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, type_name) });
    try object.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, description) });
    return .{ .object = object };
}

pub fn parseRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return (try parseOptionalString(object, key)) orelse error.InvalidToolArguments;
}

pub fn parseOptionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

pub fn getOptionalPositiveInt(object: std.json.ObjectMap, key: []const u8) !?usize {
    const value = object.get(key) orelse return null;
    if (value != .integer) return error.InvalidToolArguments;
    if (value.integer <= 0) return error.InvalidToolArguments;
    return @intCast(value.integer);
}

pub fn jsonObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}

/// Test helpers — only available in test builds.
/// Resolves a relative test path against the current working directory.
pub fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

test "resolvePath returns absolute paths unchanged" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/home/user", "/etc/config");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/etc/config", result);
}

test "resolvePath resolves relative paths against cwd" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/home/user", "src/file.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/src/file.zig", result);
}

test "resolvePath resolves dot paths" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/home/user", "./file.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/file.zig", result);
}

test "resolvePath resolves parent traversal" {
    const allocator = std.testing.allocator;
    const result = try resolvePath(allocator, "/home/user/project", "../file.zig");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/home/user/file.zig", result);
}

test "makeTextContent allocates owned text block" {
    const allocator = std.testing.allocator;
    const blocks = try makeTextContent(allocator, "hello");
    defer deinitContentBlocks(allocator, blocks);
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("hello", blocks[0].text.text);
}
