const std = @import("std");

pub const common = @import("common.zig");
pub const truncate = @import("truncate.zig");
pub const read = @import("read.zig");
pub const bash = @import("bash.zig");
pub const write = @import("write.zig");
pub const edit = @import("edit.zig");

pub const deinitContentBlocks = common.deinitContentBlocks;
pub const makeTextContent = common.makeTextContent;
pub const resolvePath = common.resolvePath;
pub const writeFileAbsolute = common.writeFileAbsolute;

pub const DEFAULT_MAX_LINES = truncate.DEFAULT_MAX_LINES;
pub const DEFAULT_MAX_BYTES = truncate.DEFAULT_MAX_BYTES;
pub const TruncationOptions = truncate.TruncationOptions;
pub const TruncatedBy = truncate.TruncatedBy;
pub const TruncationResult = truncate.TruncationResult;
pub const truncateHead = truncate.truncateHead;
pub const truncateTail = truncate.truncateTail;

pub const ReadArgs = read.ReadArgs;
pub const ReadDetails = read.ReadDetails;
pub const ReadExecutionResult = read.ReadExecutionResult;
pub const ReadTool = read.ReadTool;

pub const BashArgs = bash.BashArgs;
pub const BashDetails = bash.BashDetails;
pub const BashExecutionResult = bash.BashExecutionResult;
pub const BashTool = bash.BashTool;

pub const WriteArgs = write.WriteArgs;
pub const WriteExecutionResult = write.WriteExecutionResult;
pub const WriteTool = write.WriteTool;

pub const EditArgs = edit.EditArgs;
pub const EditExecutionResult = edit.EditExecutionResult;
pub const EditTool = edit.EditTool;

test {
    _ = @import("common.zig");
    _ = @import("truncate.zig");
    _ = @import("read.zig");
    _ = @import("bash.zig");
    _ = @import("write.zig");
    _ = @import("edit.zig");
}
