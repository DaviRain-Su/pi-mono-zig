const std = @import("std");

pub const ScrollRange = struct {
    start: usize,
    end: usize,
};

pub const ScrollThumb = struct {
    start: usize,
    length: usize,
};

pub fn visibleRange(content_length: usize, viewport_length: usize, offset: usize) ScrollRange {
    if (content_length == 0 or viewport_length == 0) return .{ .start = 0, .end = 0 };
    if (content_length <= viewport_length) return .{ .start = 0, .end = content_length };

    const start = clampOffset(content_length, viewport_length, offset);
    return .{ .start = start, .end = start + viewport_length };
}

pub fn clampOffset(content_length: usize, viewport_length: usize, offset: usize) usize {
    if (content_length == 0 or viewport_length == 0 or content_length <= viewport_length) return 0;
    return @min(offset, content_length - viewport_length);
}

pub fn thumb(track_length: usize, content_length: usize, viewport_length: usize, offset: usize) ScrollThumb {
    if (track_length == 0 or content_length == 0) return .{ .start = 0, .length = 0 };
    if (viewport_length == 0 or viewport_length >= content_length) return .{ .start = 0, .length = track_length };

    const length = @min(track_length, @max(@as(usize, 1), roundingDivide(viewport_length * track_length, content_length)));
    const travel = track_length - length;
    const max_offset = content_length - viewport_length;
    const start = if (max_offset == 0) 0 else @min(roundingDivide(clampOffset(content_length, viewport_length, offset) * travel, max_offset), travel);
    return .{ .start = start, .length = length };
}

fn roundingDivide(numerator: usize, denominator: usize) usize {
    if (denominator == 0) return 0;
    return (numerator + denominator / 2) / denominator;
}

test "scroll clamps ranges and computes proportional thumbs" {
    try std.testing.expectEqual(ScrollRange{ .start = 2, .end = 5 }, visibleRange(10, 3, 2));
    try std.testing.expectEqual(ScrollRange{ .start = 7, .end = 10 }, visibleRange(10, 3, 99));
    try std.testing.expectEqual(ScrollThumb{ .start = 5, .length = 3 }, thumb(10, 10, 3, 5));
}
