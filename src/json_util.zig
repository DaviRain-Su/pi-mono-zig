const std = @import("std");

fn compatIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn compatCwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

pub fn writeJson(writer: *std.Io.Writer, value: anytype) !void {
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, writer);
}

pub fn writeJsonLine(path: []const u8, value: anytype) !void {
    const io = compatIo();
    const cwd = compatCwd();
    var out = try std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, 0);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeByte('\n');

    var f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    const out_slice = out.writer.buffer[0..out.writer.end];
    try f.writePositionalAll(io, out_slice, 0);
}

pub fn appendJsonLine(path: []const u8, value: anytype) !void {
    const io = compatIo();
    const cwd = compatCwd();
    var out = try std.Io.Writer.Allocating.initCapacity(std.heap.page_allocator, 0);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    try out.writer.writeByte('\n');

    var f = try cwd.openFile(io, path, .{ .mode = .read_write });
    defer f.close(io);
    const n = try f.length(io);
    const out_slice = out.writer.buffer[0..out.writer.end];
    try f.writePositionalAll(io, out_slice, n);
}

pub fn parseJson(arena: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return try std.json.parseFromSlice(std.json.Value, arena, bytes, .{});
}
