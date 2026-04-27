const theme_mod = @import("../theme.zig");

pub fn palette() theme_mod.PaletteTemplate {
    return .{
        .primary = "#7aa2f7",
        .secondary = "#bb9af7",
        .success = "#9ece6a",
        .warning = "#e0af68",
        .@"error" = "#f7768e",
        .background = "#1a1b26",
        .foreground = "#c0caf5",
        .border = "#414868",
        .muted = "#7f849c",
    };
}
