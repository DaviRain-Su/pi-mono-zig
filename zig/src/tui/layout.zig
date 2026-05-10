const std = @import("std");
const ansi = @import("ansi.zig");

pub const Axis = enum {
    row,
    column,
};

pub const JustifyContent = enum {
    start,
    center,
    end,
    space_between,
    space_around,
    space_evenly,
};

pub const AlignItems = enum {
    start,
    center,
    end,
    stretch,
};

pub const ViewportAnchor = enum {
    top,
    bottom,
};

pub const Insets = struct {
    top: usize = 0,
    right: usize = 0,
    bottom: usize = 0,
    left: usize = 0,

    pub fn uniform(value: usize) Insets {
        return .{
            .top = value,
            .right = value,
            .bottom = value,
            .left = value,
        };
    }

    pub fn symmetric(vertical_padding: usize, horizontal_padding: usize) Insets {
        return .{
            .top = vertical_padding,
            .right = horizontal_padding,
            .bottom = vertical_padding,
            .left = horizontal_padding,
        };
    }

    pub fn horizontal(self: Insets) usize {
        return self.left + self.right;
    }

    pub fn vertical(self: Insets) usize {
        return self.top + self.bottom;
    }
};


