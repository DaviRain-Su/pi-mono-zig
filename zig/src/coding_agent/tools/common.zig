const std = @import("std");
const ai = @import("ai");

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
            .text => |text| allocator.free(text.text),
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
            .thinking => |thinking| {
                allocator.free(thinking.thinking);
                if (thinking.signature) |signature| allocator.free(signature);
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

pub fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => .null,
        .bool => |v| .{ .bool = v },
        .integer => |v| .{ .integer = v },
        .float => |v| .{ .float = v },
        .number_string => |v| .{ .number_string = try allocator.dupe(u8, v) },
        .string => |v| .{ .string = try allocator.dupe(u8, v) },
        .array => |array| blk: {
            var clone = std.json.Array.init(allocator);
            for (array.items) |item| {
                try clone.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = clone };
        },
        .object => |object| blk: {
            var clone = try std.json.ObjectMap.init(allocator, &.{}, &.{});
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try clone.put(
                    allocator,
                    try allocator.dupe(u8, entry.key_ptr.*),
                    try cloneJsonValue(allocator, entry.value_ptr.*),
                );
            }
            break :blk .{ .object = clone };
        },
    };
}

pub fn deinitJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .null, .bool, .integer, .float => {},
        .number_string => |v| allocator.free(v),
        .string => |v| allocator.free(v),
        .array => |array| {
            for (array.items) |item| deinitJsonValue(allocator, item);
            var array_mut = array;
            array_mut.deinit();
        },
        .object => |object| {
            var object_mut = object;
            var iterator = object_mut.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitJsonValue(allocator, entry.value_ptr.*);
            }
            object_mut.deinit(allocator);
        },
    }
}
