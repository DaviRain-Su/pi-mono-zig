const common = @import("../common.zig");
pub const descriptor = common.descriptor("attachment-utils", "utils/attachment-utils.ts", .util);

const std = @import("std");

pub const AttachmentType = enum {
    image,
    document,
};

pub const AttachmentKind = enum {
    pdf,
    docx,
    pptx,
    excel,
    image,
    text,
    unsupported,
};

pub const AttachmentMetadata = struct {
    kind: AttachmentKind,
    attachment_type: AttachmentType,
    mime_type: []const u8,
};

pub fn isDataUrl(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "data:");
}

pub fn detectAttachmentKind(file_name: []const u8, mime_type: []const u8) AttachmentKind {
    var lower_buffer: [512]u8 = undefined;
    const lower_name = asciiLowerBounded(file_name, &lower_buffer);
    if (std.mem.eql(u8, mime_type, "application/pdf") or std.mem.endsWith(u8, lower_name, ".pdf")) return .pdf;
    if (std.mem.eql(u8, mime_type, "application/vnd.openxmlformats-officedocument.wordprocessingml.document") or std.mem.endsWith(u8, lower_name, ".docx")) return .docx;
    if (std.mem.eql(u8, mime_type, "application/vnd.openxmlformats-officedocument.presentationml.presentation") or std.mem.endsWith(u8, lower_name, ".pptx")) return .pptx;
    if (isExcelMime(mime_type) or std.mem.endsWith(u8, lower_name, ".xlsx") or std.mem.endsWith(u8, lower_name, ".xls")) return .excel;
    if (std.mem.startsWith(u8, mime_type, "image/")) return .image;
    if (std.mem.startsWith(u8, mime_type, "text/") or hasTextExtension(lower_name)) return .text;
    return .unsupported;
}

pub fn metadataForAttachment(file_name: []const u8, mime_type: []const u8) ?AttachmentMetadata {
    const kind = detectAttachmentKind(file_name, mime_type);
    return switch (kind) {
        .pdf => .{ .kind = .pdf, .attachment_type = .document, .mime_type = "application/pdf" },
        .docx => .{ .kind = .docx, .attachment_type = .document, .mime_type = "application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
        .pptx => .{ .kind = .pptx, .attachment_type = .document, .mime_type = "application/vnd.openxmlformats-officedocument.presentationml.presentation" },
        .excel => .{ .kind = .excel, .attachment_type = .document, .mime_type = if (std.mem.startsWith(u8, mime_type, "application/vnd")) mime_type else "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" },
        .image => .{ .kind = .image, .attachment_type = .image, .mime_type = mime_type },
        .text => .{ .kind = .text, .attachment_type = .document, .mime_type = if (std.mem.startsWith(u8, mime_type, "text/")) mime_type else "text/plain" },
        .unsupported => null,
    };
}

pub fn wrapTextDocument(allocator: std.mem.Allocator, file_name: []const u8, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "<text filename=\"{s}\">\n{s}\n</text>", .{ file_name, text });
}

fn isExcelMime(mime_type: []const u8) bool {
    return std.mem.eql(u8, mime_type, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet") or
        std.mem.eql(u8, mime_type, "application/vnd.ms-excel");
}

fn hasTextExtension(lower_name: []const u8) bool {
    const extensions = [_][]const u8{ ".txt", ".md", ".json", ".xml", ".html", ".css", ".js", ".ts", ".jsx", ".tsx", ".yml", ".yaml" };
    for (extensions) |extension| {
        if (std.mem.endsWith(u8, lower_name, extension)) return true;
    }
    return false;
}

fn asciiLowerBounded(value: []const u8, buffer: []u8) []const u8 {
    const len = @min(value.len, buffer.len);
    for (value[0..len], 0..) |byte, index| buffer[index] = std.ascii.toLower(byte);
    return buffer[0..len];
}

test "web-ui attachment metadata classifies TS-supported file types" {
    try std.testing.expectEqual(AttachmentKind.pdf, detectAttachmentKind("Report.PDF", "application/octet-stream"));
    try std.testing.expectEqual(AttachmentKind.excel, detectAttachmentKind("sheet.xlsx", "application/octet-stream"));
    try std.testing.expectEqual(AttachmentKind.text, detectAttachmentKind("notes.md", "application/octet-stream"));
    try std.testing.expectEqual(AttachmentType.image, metadataForAttachment("x.png", "image/png").?.attachment_type);
}
