const std = @import("std");
const ai = @import("ai");
const common = @import("common.zig");

const utf8_bom = "\xEF\xBB\xBF";

pub const EditArgs = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

pub const EditExecutionResult = struct {
    content: []const ai.ContentBlock,
    is_error: bool = false,

    pub fn deinit(self: *EditExecutionResult, allocator: std.mem.Allocator) void {
        common.deinitContentBlocks(allocator, self.content);
        self.* = undefined;
    }
};

pub const EditTool = struct {
    cwd: []const u8,
    io: std.Io,

    pub const name = "edit";
    pub const description =
        "Edit a single file using exact text replacement. The search text must match exactly one location in the file.";

    pub fn init(cwd: []const u8, io: std.Io) EditTool {
        return .{
            .cwd = cwd,
            .io = io,
        };
    }

    pub fn schema(allocator: std.mem.Allocator) !std.json.Value {
        var properties = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        errdefer {
            const value = std.json.Value{ .object = properties };
            common.deinitJsonValue(allocator, value);
        }

        try properties.put(allocator, try allocator.dupe(u8, "path"), try schemaProperty(
            allocator,
            "string",
            "Path to the file to edit (absolute or relative to cwd)",
        ));
        try properties.put(allocator, try allocator.dupe(u8, "oldText"), try schemaProperty(
            allocator,
            "string",
            "Exact text to replace. It must match exactly one location in the file.",
        ));
        try properties.put(allocator, try allocator.dupe(u8, "newText"), try schemaProperty(
            allocator,
            "string",
            "Replacement text for the matched block.",
        ));

        var required = std.json.Array.init(allocator);
        try required.append(.{ .string = try allocator.dupe(u8, "path") });
        try required.append(.{ .string = try allocator.dupe(u8, "oldText") });
        try required.append(.{ .string = try allocator.dupe(u8, "newText") });

        var root = try std.json.ObjectMap.init(allocator, &.{}, &.{});
        try root.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
        try root.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = properties });
        try root.put(allocator, try allocator.dupe(u8, "required"), .{ .array = required });
        return .{ .object = root };
    }

    pub fn execute(
        self: EditTool,
        allocator: std.mem.Allocator,
        args: EditArgs,
    ) !EditExecutionResult {
        if (args.old_text.len == 0) {
            return .{
                .content = try common.makeTextContent(allocator, "Search text must not be empty"),
                .is_error = true,
            };
        }

        const absolute_path = try common.resolvePath(allocator, self.cwd, args.path);
        defer allocator.free(absolute_path);

        const raw_content = std.Io.Dir.readFileAlloc(.cwd(), self.io, absolute_path, allocator, .unlimited) catch |err| {
            const message = switch (err) {
                error.FileNotFound => try std.fmt.allocPrint(allocator, "File not found: {s}", .{args.path}),
                else => try std.fmt.allocPrint(allocator, "Failed to read {s}: {s}", .{ args.path, @errorName(err) }),
            };
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        };
        defer allocator.free(raw_content);

        const stripped = stripBom(raw_content);
        const original_line_ending = detectLineEnding(stripped.text);

        const normalized_content = try normalizeToLf(allocator, stripped.text);
        defer allocator.free(normalized_content);
        const normalized_old = try normalizeToLf(allocator, args.old_text);
        defer allocator.free(normalized_old);
        const normalized_new = try normalizeToLf(allocator, args.new_text);
        defer allocator.free(normalized_new);

        const match_count = std.mem.count(u8, normalized_content, normalized_old);
        if (match_count == 0) {
            const message = try std.fmt.allocPrint(allocator, "Search text not found in {s}", .{args.path});
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        }
        if (match_count > 1) {
            const message = try std.fmt.allocPrint(allocator, "Search text matched multiple locations in {s}", .{args.path});
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        }

        const match_index = std.mem.indexOf(u8, normalized_content, normalized_old).?;
        const replaced = try std.mem.concat(allocator, u8, &[_][]const u8{
            normalized_content[0..match_index],
            normalized_new,
            normalized_content[match_index + normalized_old.len ..],
        });
        defer allocator.free(replaced);

        const restored = try restoreLineEndings(allocator, replaced, original_line_ending);
        defer allocator.free(restored);

        const final_content = if (stripped.bom.len == 0)
            try allocator.dupe(u8, restored)
        else
            try std.mem.concat(allocator, u8, &[_][]const u8{ stripped.bom, restored });
        defer allocator.free(final_content);

        common.writeFileAbsolute(self.io, absolute_path, final_content, false) catch |err| {
            const message = try std.fmt.allocPrint(allocator, "Failed to write {s}: {s}", .{ args.path, @errorName(err) });
            defer allocator.free(message);
            return .{
                .content = try common.makeTextContent(allocator, message),
                .is_error = true,
            };
        };

        const message = try std.fmt.allocPrint(allocator, "Successfully replaced text in {s}", .{args.path});
        defer allocator.free(message);
        return .{
            .content = try common.makeTextContent(allocator, message),
        };
    }
};

pub fn parseArguments(args: std.json.Value) !EditArgs {
    if (args != .object) return error.InvalidToolArguments;

    return .{
        .path = try parseRequiredString(args.object, "path"),
        .old_text = try parseRequiredStringEither(args.object, "oldText", "old_text"),
        .new_text = try parseRequiredStringEither(args.object, "newText", "new_text"),
    };
}

const StrippedBom = struct {
    bom: []const u8,
    text: []const u8,
};

const LineEnding = enum {
    lf,
    crlf,
    cr,
};

fn stripBom(text: []const u8) StrippedBom {
    if (std.mem.startsWith(u8, text, utf8_bom)) {
        return .{
            .bom = text[0..utf8_bom.len],
            .text = text[utf8_bom.len..],
        };
    }
    return .{
        .bom = "",
        .text = text,
    };
}

fn detectLineEnding(text: []const u8) LineEnding {
    if (std.mem.indexOf(u8, text, "\r\n") != null) return .crlf;
    if (std.mem.indexOfScalar(u8, text, '\r') != null) return .cr;
    return .lf;
}

fn normalizeToLf(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const without_crlf = try std.mem.replaceOwned(u8, allocator, text, "\r\n", "\n");
    errdefer allocator.free(without_crlf);
    const normalized = try std.mem.replaceOwned(u8, allocator, without_crlf, "\r", "\n");
    allocator.free(without_crlf);
    return normalized;
}

fn restoreLineEndings(
    allocator: std.mem.Allocator,
    text: []const u8,
    line_ending: LineEnding,
) ![]u8 {
    return switch (line_ending) {
        .lf => allocator.dupe(u8, text),
        .crlf => std.mem.replaceOwned(u8, allocator, text, "\n", "\r\n"),
        .cr => std.mem.replaceOwned(u8, allocator, text, "\n", "\r"),
    };
}

fn parseRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return (try parseOptionalString(object, key)) orelse error.InvalidToolArguments;
}

fn parseRequiredStringEither(object: std.json.ObjectMap, primary: []const u8, alternate: []const u8) ![]const u8 {
    if (try parseOptionalString(object, primary)) |value| return value;
    return (try parseOptionalString(object, alternate)) orelse error.InvalidToolArguments;
}

fn parseOptionalString(object: std.json.ObjectMap, key: []const u8) !?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return error.InvalidToolArguments;
    return value.string;
}

fn schemaProperty(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    description_text: []const u8,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, type_name) });
    try object.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, description_text) });
    return .{ .object = object };
}

fn makeAbsoluteTestPath(allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{ cwd, relative_path });
}

fn jsonObject(allocator: std.mem.Allocator) !std.json.ObjectMap {
    return try std.json.ObjectMap.init(allocator, &.{}, &.{});
}

test "edit tool replaces matching text in a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "editable.txt",
        .data = "before old text after",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "editable.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try EditTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
        .old_text = "old text",
        .new_text = "new text",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.is_error);

    const written = try std.Io.Dir.readFileAlloc(.cwd(), std.testing.io, absolute_path, std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(written);
    try std.testing.expectEqualStrings("before new text after", written);
}

test "edit tool returns an error when the search text is not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "editable.txt",
        .data = "before after",
    });

    const relative_path = try std.fs.path.join(std.testing.allocator, &[_][]const u8{
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "editable.txt",
    });
    defer std.testing.allocator.free(relative_path);
    const absolute_path = try makeAbsoluteTestPath(std.testing.allocator, relative_path);
    defer std.testing.allocator.free(absolute_path);

    var result = try EditTool.init(".", std.testing.io).execute(std.testing.allocator, .{
        .path = absolute_path,
        .old_text = "missing text",
        .new_text = "new text",
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.is_error);
    try std.testing.expect(std.mem.containsAtLeast(u8, result.content[0].text.text, 1, "Search text not found"));
}

test "edit tool validates required arguments" {
    const object = try jsonObject(std.testing.allocator);
    defer {
        const value = std.json.Value{ .object = object };
        common.deinitJsonValue(std.testing.allocator, value);
    }

    try std.testing.expectError(error.InvalidToolArguments, parseArguments(.{ .object = object }));
}
