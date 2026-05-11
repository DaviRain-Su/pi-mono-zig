const std = @import("std");

pub fn detectSupportedImageMimeTypeFromFile(allocator: std.mem.Allocator, io: std.Io, file_path: []const u8) !?[]u8 {
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), io, file_path, allocator, .limited(4100));
    defer allocator.free(bytes);
    const mime = detectSupportedImageMimeType(bytes) orelse return null;
    return try allocator.dupe(u8, mime);
}

pub fn detectSupportedImageMimeType(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return "image/gif";
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return "image/webp";
    return null;
}

test "mime detects supported image types" {
    try std.testing.expectEqualStrings("image/png", detectSupportedImageMimeType("\x89PNG\r\n\x1a\nabc").?);
    try std.testing.expectEqualStrings("image/jpeg", detectSupportedImageMimeType("\xff\xd8\xffabc").?);
    try std.testing.expectEqualStrings("image/gif", detectSupportedImageMimeType("GIF89aabc").?);
    try std.testing.expectEqualStrings("image/webp", detectSupportedImageMimeType("RIFFxxxxWEBP").?);
    try std.testing.expect(detectSupportedImageMimeType("text") == null);
}
