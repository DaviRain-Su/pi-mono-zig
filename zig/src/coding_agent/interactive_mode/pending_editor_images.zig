const std = @import("std");
const ai = @import("ai");
const tui = @import("tui");

pub const PendingEditorImage = struct {
    data: []const u8,
    mime_type: []const u8,
    kitty_image: ?tui.components.image.KittyImage = null,

    pub fn content(self: PendingEditorImage) ai.ImageContent {
        return .{
            .data = self.data,
            .mime_type = self.mime_type,
        };
    }
};

pub fn deinit(allocator: std.mem.Allocator, image: *PendingEditorImage) void {
    allocator.free(image.data);
    allocator.free(image.mime_type);
    image.* = undefined;
}

pub fn cloneForRender(allocator: std.mem.Allocator, images: []const PendingEditorImage) ![]PendingEditorImage {
    if (images.len == 0) return &.{};

    const cloned = try allocator.alloc(PendingEditorImage, images.len);
    var initialized: usize = 0;
    errdefer {
        for (cloned[0..initialized]) |*image| deinit(allocator, image);
        allocator.free(cloned);
    }

    for (images, 0..) |image, index| {
        cloned[index] = .{
            .data = try allocator.dupe(u8, image.data),
            .mime_type = try allocator.dupe(u8, image.mime_type),
            .kitty_image = image.kitty_image,
        };
        initialized += 1;
    }
    return cloned;
}

pub fn deinitForRender(allocator: std.mem.Allocator, images: []PendingEditorImage) void {
    for (images) |*image| deinit(allocator, image);
    if (images.len > 0) allocator.free(images);
}
