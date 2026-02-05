const std = @import("std");

pub fn writeJson(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, writer);
}

pub fn writeJsonLine(path: []const u8, value: anytype) !void {
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();

    var buf: [16 * 1024]u8 = undefined;
    var fw = std.fs.File.Writer.init(f, &buf);
    try std.json.Stringify.value(value, .{}, &fw.interface);
    try fw.interface.writeByte('\n');
    _ = try fw.interface.flush();
}

pub fn appendJsonLine(path: []const u8, value: anytype) !void {
    var f = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer f.close();
    try f.seekFromEnd(0);

    var buf: [16 * 1024]u8 = undefined;
    var fw = std.fs.File.Writer.initStreaming(f, &buf);
    try std.json.Stringify.value(value, .{}, &fw.interface);
    try fw.interface.writeByte('\n');
    _ = try fw.interface.flush();
}

pub fn parseJson(arena: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, arena, bytes, .{});
}
