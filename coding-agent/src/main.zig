const std = @import("std");
const args_mod = @import("args.zig");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer it.deinit();

    var args_list = std.ArrayList([]const u8).empty;
    defer args_list.deinit(allocator);

    while (it.next()) |arg| {
        try args_list.append(allocator, try allocator.dupe(u8, arg));
    }

    var parsed = try args_mod.parseArgs(allocator, args_list.items[1..]);
    defer parsed.deinit();

    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);

    if (parsed.help) {
        const help_text = try args_mod.printHelpAlloc(allocator);
        defer allocator.free(help_text);
        try stdout_writer.interface.print("{s}", .{help_text});
        return;
    }

    if (parsed.version) {
        try stdout_writer.interface.print("pi 0.0.1 (zig rewrite)\n", .{});
        return;
    }

    for (parsed.diagnostics.items.items) |diag| {
        const prefix = switch (diag.severity) {
            .warning => "Warning: ",
            .error_msg => "Error: ",
        };
        try stdout_writer.interface.print("{s}{s}\n", .{ prefix, diag.message });
    }

    const mode_str = if (parsed.mode) |m| @tagName(m) else "interactive";
    try stdout_writer.interface.print("pi coding agent (zig rewrite) - mode={s}\n", .{mode_str});
}
