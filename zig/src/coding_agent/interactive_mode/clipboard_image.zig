const builtin = @import("builtin");
const std = @import("std");
const ai = @import("ai");

const SUPPORTED_IMAGE_MIME_TYPES = [_][]const u8{
    "image/png",
    "image/jpeg",
    "image/webp",
    "image/gif",
};
const MAX_CLIPBOARD_BYTES = 50 * 1024 * 1024;

pub const ClipboardImage = struct {
    bytes: []u8,
    mime_type: []u8,

    pub fn deinit(self: *ClipboardImage, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.mime_type);
        self.* = undefined;
    }
};

pub const ClipboardImageReaderFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) anyerror!?ClipboardImage;

pub var clipboard_image_reader_context: ?*anyopaque = null;
pub var clipboard_image_reader_fn: ClipboardImageReaderFn = defaultReadClipboardImage;

pub fn readClipboardImage(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !?ClipboardImage {
    return clipboard_image_reader_fn(clipboard_image_reader_context, allocator, io, env_map);
}

pub fn encodeImageContent(allocator: std.mem.Allocator, image: ClipboardImage) !ai.ImageContent {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(image.bytes.len));
    _ = std.base64.standard.Encoder.encode(encoded, image.bytes);
    return .{
        .data = encoded,
        .mime_type = try allocator.dupe(u8, image.mime_type),
    };
}

pub fn deinitImageContent(allocator: std.mem.Allocator, image: *ai.ImageContent) void {
    allocator.free(image.data);
    allocator.free(image.mime_type);
    image.* = undefined;
}

fn defaultReadClipboardImage(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !?ClipboardImage {
    return switch (builtin.os.tag) {
        .macos => try readClipboardImageMacos(allocator, io, env_map),
        .windows => try readClipboardImageWindows(allocator, io, env_map),
        else => try readClipboardImageLinux(allocator, io, env_map),
    };
}

const CommandOutput = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    fn releaseStdout(self: *CommandOutput) []u8 {
        const stdout = self.stdout;
        self.stdout = &.{};
        return stdout;
    }

    fn deinit(self: *CommandOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }
};

fn runCommandCapture(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    argv: []const []const u8,
) !CommandOutput {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .environ_map = env_map,
        .stdout_limit = .limited(MAX_CLIPBOARD_BYTES),
        .stderr_limit = .limited(16 * 1024),
    });
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exitCodeFromTerm(result.term),
    };
}

fn exitCodeFromTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

fn readClipboardImageMacos(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !?ClipboardImage {
    const script =
        \\import AppKit
        \\import Foundation
        \\let pb = NSPasteboard.general
        \\func write(_ data: Data) {
        \\    FileHandle.standardOutput.write(data)
        \\    exit(0)
        \\}
        \\if let png = pb.data(forType: .png) { write(png) }
        \\if let tiff = pb.data(forType: .tiff),
        \\   let rep = NSBitmapImageRep(data: tiff),
        \\   let png = rep.representation(using: .png, properties: [:]) {
        \\    write(png)
        \\}
        \\for type in pb.types ?? [] {
        \\    let raw = type.rawValue.lowercased()
        \\    if raw.contains("png"), let data = pb.data(forType: type) { write(data) }
        \\    if raw.contains("jpeg") || raw.contains("jpg"), let data = pb.data(forType: type) { write(data) }
        \\    if raw.contains("gif"), let data = pb.data(forType: type) { write(data) }
        \\    if raw.contains("webp"), let data = pb.data(forType: type) { write(data) }
        \\}
        \\exit(1)
    ;

    var output = try runCommandCapture(allocator, io, env_map, &[_][]const u8{ "swift", "-e", script });
    errdefer output.deinit(allocator);
    if (output.exit_code != 0 or output.stdout.len == 0) {
        output.deinit(allocator);
        return null;
    }

    const mime_type = detectImageMime(output.stdout) orelse "image/png";
    return .{
        .bytes = output.releaseStdout(),
        .mime_type = try allocator.dupe(u8, mime_type),
    };
}

fn readClipboardImageWindows(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !?ClipboardImage {
    const script =
        \\Add-Type -AssemblyName System.Windows.Forms
        \\Add-Type -AssemblyName System.Drawing
        \\$img = [System.Windows.Forms.Clipboard]::GetImage()
        \\if (-not $img) { exit 1 }
        \\$stream = New-Object System.IO.MemoryStream
        \\$img.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
        \\$bytes = $stream.ToArray()
        \\[Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)
    ;

    var output = try runCommandCapture(allocator, io, env_map, &[_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-Sta",
        "-Command",
        script,
    });
    errdefer output.deinit(allocator);
    if (output.exit_code != 0 or output.stdout.len == 0) {
        output.deinit(allocator);
        return null;
    }

    return .{
        .bytes = output.releaseStdout(),
        .mime_type = try allocator.dupe(u8, "image/png"),
    };
}

fn readClipboardImageLinux(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !?ClipboardImage {
    if (isWaylandSession(env_map)) {
        if (try readClipboardImageViaWlPaste(allocator, io, env_map)) |image| return image;
    }
    return try readClipboardImageViaXclip(allocator, io, env_map);
}

fn isWaylandSession(env_map: *const std.process.Environ.Map) bool {
    if (env_map.get("WAYLAND_DISPLAY") != null) return true;
    const session_type = env_map.get("XDG_SESSION_TYPE") orelse return false;
    return std.ascii.eqlIgnoreCase(session_type, "wayland");
}

fn readClipboardImageViaWlPaste(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !?ClipboardImage {
    var listed = try runCommandCapture(allocator, io, env_map, &[_][]const u8{ "wl-paste", "--list-types" });
    defer listed.deinit(allocator);
    if (listed.exit_code != 0 or listed.stdout.len == 0) return null;

    const selected = selectPreferredImageMimeTypeFromLines(listed.stdout) orelse return null;

    var data = try runCommandCapture(allocator, io, env_map, &[_][]const u8{
        "wl-paste",
        "--type",
        selected,
        "--no-newline",
    });
    errdefer data.deinit(allocator);
    if (data.exit_code != 0 or data.stdout.len == 0) {
        data.deinit(allocator);
        return null;
    }

    return .{
        .bytes = data.releaseStdout(),
        .mime_type = try allocator.dupe(u8, baseMimeType(selected)),
    };
}

fn readClipboardImageViaXclip(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !?ClipboardImage {
    var selected: ?[]const u8 = null;

    var targets = runCommandCapture(allocator, io, env_map, &[_][]const u8{
        "xclip",
        "-selection",
        "clipboard",
        "-t",
        "TARGETS",
        "-o",
    }) catch null;
    if (targets) |*listed| {
        defer listed.deinit(allocator);
        if (listed.exit_code == 0 and listed.stdout.len > 0) {
            selected = selectPreferredImageMimeTypeFromLines(listed.stdout);
        }
    }

    if (selected) |mime_type| {
        if (try readClipboardImageViaXclipMime(allocator, io, env_map, mime_type)) |image| return image;
    }

    for (SUPPORTED_IMAGE_MIME_TYPES) |mime_type| {
        if (selected) |already_selected| {
            if (std.mem.eql(u8, baseMimeType(already_selected), mime_type)) continue;
        }
        if (try readClipboardImageViaXclipMime(allocator, io, env_map, mime_type)) |image| return image;
    }

    return null;
}

fn readClipboardImageViaXclipMime(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    mime_type: []const u8,
) !?ClipboardImage {
    var data = try runCommandCapture(allocator, io, env_map, &[_][]const u8{
        "xclip",
        "-selection",
        "clipboard",
        "-t",
        mime_type,
        "-o",
    });
    errdefer data.deinit(allocator);
    if (data.exit_code != 0 or data.stdout.len == 0) {
        data.deinit(allocator);
        return null;
    }

    return .{
        .bytes = data.releaseStdout(),
        .mime_type = try allocator.dupe(u8, baseMimeType(mime_type)),
    };
}

fn baseMimeType(mime_type: []const u8) []const u8 {
    const separator = std.mem.indexOfScalar(u8, mime_type, ';') orelse mime_type.len;
    return std.mem.trim(u8, mime_type[0..separator], " \t\r\n");
}

fn selectPreferredImageMimeTypeFromLines(text: []const u8) ?[]const u8 {
    var fallback: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r\n");
        if (line.len == 0) continue;

        const base = baseMimeType(line);
        for (SUPPORTED_IMAGE_MIME_TYPES) |preferred| {
            if (std.mem.eql(u8, base, preferred)) return line;
        }

        if (fallback == null and std.mem.startsWith(u8, base, "image/")) {
            fallback = line;
        }
    }
    return fallback;
}

fn detectImageMime(bytes: []const u8) ?[]const u8 {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return "image/png";
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return "image/jpeg";
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) {
        return "image/gif";
    }
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        return "image/webp";
    }
    return null;
}

test "selectPreferredImageMimeTypeFromLines prefers supported formats and strips parameters" {
    const selected = selectPreferredImageMimeTypeFromLines(
        \\image/bmp
        \\image/png;charset=utf-8
        \\image/jpeg
    ) orelse return error.ExpectedMimeType;

    try std.testing.expectEqualStrings("image/png;charset=utf-8", selected);
    try std.testing.expectEqualStrings("image/png", baseMimeType(selected));
}

test "encodeImageContent base64 encodes clipboard bytes" {
    const allocator = std.testing.allocator;

    var image = ClipboardImage{
        .bytes = try allocator.dupe(u8, &[_]u8{ 0x01, 0x02, 0x03 }),
        .mime_type = try allocator.dupe(u8, "image/png"),
    };
    defer image.deinit(allocator);

    var encoded = try encodeImageContent(allocator, image);
    defer deinitImageContent(allocator, &encoded);

    try std.testing.expectEqualStrings("AQID", encoded.data);
    try std.testing.expectEqualStrings("image/png", encoded.mime_type);
}
