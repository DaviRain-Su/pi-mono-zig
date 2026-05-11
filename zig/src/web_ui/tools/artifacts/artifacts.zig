const common = @import("../../common.zig");
pub const descriptor = common.descriptor("artifacts", "tools/artifacts/artifacts.ts", .tool);

const std = @import("std");

pub const ArtifactKind = enum {
    text,
    markdown,
    html,
    svg,
    image,
    pdf,
    docx,
    excel,
    console,
    generic,
};

pub const ArtifactCommand = enum {
    create,
    update,
    rewrite,
    get,
    delete,
    logs,
};

pub const ArtifactParams = struct {
    command: ArtifactCommand,
    filename: []const u8,
    content: ?[]const u8 = null,
    old_str: ?[]const u8 = null,
    new_str: ?[]const u8 = null,
};

pub const Artifact = struct {
    filename: []u8,
    content: []u8,
};

pub const ArtifactStore = struct {
    allocator: std.mem.Allocator,
    artifacts: std.StringHashMap(Artifact),
    active_filename: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator) ArtifactStore {
        return .{ .allocator = allocator, .artifacts = .init(allocator) };
    }

    pub fn deinit(self: *ArtifactStore) void {
        var iterator = self.artifacts.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.filename);
            self.allocator.free(entry.value_ptr.content);
        }
        self.artifacts.deinit();
        if (self.active_filename) |value| self.allocator.free(value);
        self.* = undefined;
    }

    pub fn executeCommand(self: *ArtifactStore, params: ArtifactParams) ![]u8 {
        return switch (params.command) {
            .create => self.createArtifact(params),
            .update => self.updateArtifact(params),
            .rewrite => self.rewriteArtifact(params),
            .get => self.getArtifact(params),
            .delete => self.deleteArtifact(params),
            .logs => self.getLogs(params),
        };
    }

    fn createArtifact(self: *ArtifactStore, params: ArtifactParams) ![]u8 {
        const content = params.content orelse return self.allocator.dupe(u8, "Error: create command requires filename and content");
        if (self.artifacts.contains(params.filename)) {
            return std.fmt.allocPrint(self.allocator, "Error: File {s} already exists", .{params.filename});
        }
        const filename = try self.allocator.dupe(u8, params.filename);
        errdefer self.allocator.free(filename);
        const owned_content = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(owned_content);
        try self.artifacts.put(filename, .{ .filename = filename, .content = owned_content });
        try self.setActive(params.filename);
        return std.fmt.allocPrint(self.allocator, "Created file {s}", .{params.filename});
    }

    fn updateArtifact(self: *ArtifactStore, params: ArtifactParams) ![]u8 {
        const artifact = self.artifacts.getPtr(params.filename) orelse return self.missingFileError(params.filename);
        const old = params.old_str orelse return self.allocator.dupe(u8, "Error: update command requires old_str and new_str");
        const new = params.new_str orelse return self.allocator.dupe(u8, "Error: update command requires old_str and new_str");
        const index = std.mem.indexOf(u8, artifact.content, old) orelse {
            return std.fmt.allocPrint(self.allocator, "Error: String not found in file. Here is the full content:\n\n{s}", .{artifact.content});
        };
        const updated = try replaceRange(self.allocator, artifact.content, index, index + old.len, new);
        self.allocator.free(artifact.content);
        artifact.content = updated;
        try self.setActive(params.filename);
        return std.fmt.allocPrint(self.allocator, "Updated file {s}", .{params.filename});
    }

    fn rewriteArtifact(self: *ArtifactStore, params: ArtifactParams) ![]u8 {
        const artifact = self.artifacts.getPtr(params.filename) orelse return self.missingFileError(params.filename);
        const content = params.content orelse return self.allocator.dupe(u8, "Error: rewrite command requires content");
        const owned = try self.allocator.dupe(u8, content);
        self.allocator.free(artifact.content);
        artifact.content = owned;
        try self.setActive(params.filename);
        return self.allocator.dupe(u8, "");
    }

    fn getArtifact(self: *ArtifactStore, params: ArtifactParams) ![]u8 {
        const artifact = self.artifacts.get(params.filename) orelse return self.missingFileError(params.filename);
        return self.allocator.dupe(u8, artifact.content);
    }

    fn deleteArtifact(self: *ArtifactStore, params: ArtifactParams) ![]u8 {
        const removed = self.artifacts.fetchRemove(params.filename) orelse return self.missingFileError(params.filename);
        self.allocator.free(removed.value.filename);
        self.allocator.free(removed.value.content);
        if (self.active_filename) |active| {
            if (std.mem.eql(u8, active, params.filename)) {
                self.allocator.free(active);
                self.active_filename = null;
            }
        }
        return std.fmt.allocPrint(self.allocator, "Deleted file {s}", .{params.filename});
    }

    fn getLogs(self: *ArtifactStore, params: ArtifactParams) ![]u8 {
        if (!self.artifacts.contains(params.filename)) return self.missingFileError(params.filename);
        if (getFileType(params.filename) != .html) {
            return std.fmt.allocPrint(self.allocator, "Error: File {s} is not an HTML file. Logs are only available for HTML files.", .{params.filename});
        }
        return self.allocator.dupe(u8, "");
    }

    fn missingFileError(self: *ArtifactStore, filename: []const u8) ![]u8 {
        if (self.artifacts.count() == 0) {
            return std.fmt.allocPrint(self.allocator, "Error: File {s} not found. No files have been created yet.", .{filename});
        }
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer out.deinit();
        try out.writer.print("Error: File {s} not found. Available files: ", .{filename});
        var iterator = self.artifacts.keyIterator();
        var first = true;
        while (iterator.next()) |key| {
            if (!first) try out.writer.writeAll(", ");
            try out.writer.writeAll(key.*);
            first = false;
        }
        return out.toOwnedSlice();
    }

    fn setActive(self: *ArtifactStore, filename: []const u8) !void {
        if (self.active_filename) |active| self.allocator.free(active);
        self.active_filename = try self.allocator.dupe(u8, filename);
    }
};

pub fn extensionForKind(kind: ArtifactKind) []const u8 {
    return switch (kind) {
        .text => "txt",
        .markdown => "md",
        .html => "html",
        .svg => "svg",
        .image => "png",
        .pdf => "pdf",
        .docx => "docx",
        .excel => "xlsx",
        .console => "log",
        .generic => "bin",
    };
}

pub fn getFileType(filename: []const u8) ArtifactKind {
    const extension = rawExtension(filename);
    if (extensionEquals(extension, "html")) return .html;
    if (extensionEquals(extension, "svg")) return .svg;
    if (extensionEquals(extension, "md") or extensionEquals(extension, "markdown")) return .markdown;
    if (extensionEquals(extension, "pdf")) return .pdf;
    if (extensionEquals(extension, "xlsx") or extensionEquals(extension, "xls")) return .excel;
    if (extensionEquals(extension, "docx")) return .docx;
    if (isImageExtension(extension)) return .image;
    if (isTextExtension(extension)) return .text;
    return .generic;
}

pub fn parseArtifactCommand(value: []const u8) ?ArtifactCommand {
    if (std.mem.eql(u8, value, "create")) return .create;
    if (std.mem.eql(u8, value, "update")) return .update;
    if (std.mem.eql(u8, value, "rewrite")) return .rewrite;
    if (std.mem.eql(u8, value, "get")) return .get;
    if (std.mem.eql(u8, value, "delete")) return .delete;
    if (std.mem.eql(u8, value, "logs")) return .logs;
    return null;
}

fn replaceRange(allocator: std.mem.Allocator, source: []const u8, start: usize, end: usize, replacement: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll(source[0..start]);
    try out.writer.writeAll(replacement);
    try out.writer.writeAll(source[end..]);
    return out.toOwnedSlice();
}

fn rawExtension(filename: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, filename, '.') orelse return "";
    return filename[dot + 1 ..];
}

/// Case-insensitive ASCII compare against a lowercase literal. The
/// previous implementation lowercased into a stack buffer and returned
/// the slice, which was use-after-return UB; comparing in place avoids
/// any allocation while still accepting mixed-case extensions like
/// `JPG` or `MARKDOWN`.
fn extensionEquals(extension: []const u8, comptime lowercase_literal: []const u8) bool {
    if (extension.len != lowercase_literal.len) return false;
    for (extension, lowercase_literal) |byte, expected| {
        if (std.ascii.toLower(byte) != expected) return false;
    }
    return true;
}

fn isImageExtension(extension: []const u8) bool {
    const values = [_][]const u8{ "png", "jpg", "jpeg", "gif", "webp", "bmp", "ico" };
    for (values) |value| if (extensionEqualsRuntime(extension, value)) return true;
    return false;
}

fn isTextExtension(extension: []const u8) bool {
    const values = [_][]const u8{ "txt", "json", "xml", "yaml", "yml", "csv", "js", "ts", "jsx", "tsx", "py", "java", "c", "cpp", "h", "css", "scss", "sass", "less", "sh" };
    for (values) |value| if (extensionEqualsRuntime(extension, value)) return true;
    return false;
}

fn extensionEqualsRuntime(extension: []const u8, lowercase_literal: []const u8) bool {
    if (extension.len != lowercase_literal.len) return false;
    for (extension, lowercase_literal) |byte, expected| {
        if (std.ascii.toLower(byte) != expected) return false;
    }
    return true;
}

test "artifact kinds map to file extensions" {
    try std.testing.expectEqualStrings("html", extensionForKind(.html));
}

test "web-ui artifact file type follows TS extension mapping" {
    try std.testing.expectEqual(ArtifactKind.markdown, getFileType("README.markdown"));
    try std.testing.expectEqual(ArtifactKind.image, getFileType("photo.JPG"));
    try std.testing.expectEqual(ArtifactKind.text, getFileType("script.tsx"));
    try std.testing.expectEqual(ArtifactKind.generic, getFileType("archive.zip"));
}

test "web-ui artifact store executes create update get delete" {
    var store = ArtifactStore.init(std.testing.allocator);
    defer store.deinit();
    const created = try store.executeCommand(.{ .command = .create, .filename = "index.html", .content = "hello" });
    defer std.testing.allocator.free(created);
    try std.testing.expectEqualStrings("Created file index.html", created);
    const updated = try store.executeCommand(.{ .command = .update, .filename = "index.html", .old_str = "hello", .new_str = "hi" });
    defer std.testing.allocator.free(updated);
    try std.testing.expectEqualStrings("Updated file index.html", updated);
    const content = try store.executeCommand(.{ .command = .get, .filename = "index.html" });
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("hi", content);
    const deleted = try store.executeCommand(.{ .command = .delete, .filename = "index.html" });
    defer std.testing.allocator.free(deleted);
    try std.testing.expectEqualStrings("Deleted file index.html", deleted);
}
