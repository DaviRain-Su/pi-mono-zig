const std = @import("std");

const queue_allocator = std.heap.page_allocator;

const QueueEntry = struct {
    key: []u8,
    next_ticket: usize,
    serving_ticket: usize,
};

const GlobalQueue = struct {
    mutex: std.Io.Mutex = .init,
    condition: std.Io.Condition = .init,
    entries: std.ArrayListUnmanaged(QueueEntry) = .empty,
};

var global_queue = GlobalQueue{};

pub const FileMutationGuard = struct {
    io: std.Io,
    key: []const u8,
    released: bool = false,

    pub fn release(self: *FileMutationGuard) void {
        if (self.released) return;
        releaseUnlocked(self.io, self.key);
        self.released = true;
    }
};

pub fn acquire(io: std.Io, absolute_path: []const u8) !FileMutationGuard {
    const lookup_key = try canonicalizeKey(io, absolute_path);
    errdefer queue_allocator.free(lookup_key);

    global_queue.mutex.lockUncancelable(io);
    defer global_queue.mutex.unlock(io);

    var ticket: usize = 0;
    var queue_owns_lookup_key = false;

    if (findEntryIndexLocked(lookup_key)) |index| {
        const entry = &global_queue.entries.items[index];
        ticket = entry.next_ticket;
        entry.next_ticket += 1;
    } else {
        try global_queue.entries.append(queue_allocator, .{
            .key = lookup_key,
            .next_ticket = 1,
            .serving_ticket = 0,
        });
        queue_owns_lookup_key = true;
    }

    while (true) {
        const index = findEntryIndexLocked(lookup_key) orelse unreachable;
        const entry = &global_queue.entries.items[index];
        if (entry.serving_ticket == ticket) {
            if (!queue_owns_lookup_key) queue_allocator.free(lookup_key);
            return .{
                .io = io,
                .key = entry.key,
            };
        }
        global_queue.condition.waitUncancelable(io, &global_queue.mutex);
    }
}

fn releaseUnlocked(io: std.Io, key: []const u8) void {
    global_queue.mutex.lockUncancelable(io);
    defer global_queue.mutex.unlock(io);

    const index = findEntryIndexLocked(key) orelse return;
    const entry = &global_queue.entries.items[index];
    entry.serving_ticket += 1;

    if (entry.serving_ticket == entry.next_ticket) {
        const removed = global_queue.entries.swapRemove(index);
        queue_allocator.free(removed.key);
    }

    global_queue.condition.broadcast(io);
}

fn findEntryIndexLocked(key: []const u8) ?usize {
    for (global_queue.entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.key, key)) return index;
    }
    return null;
}

fn canonicalizeKey(io: std.Io, absolute_path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(io, absolute_path, queue_allocator) catch
        try queue_allocator.dupe(u8, absolute_path);
}

const QueueEvent = enum(u8) {
    first_start,
    first_end,
    second_start,
    second_end,
};

const QueueOrderRecorder = struct {
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    events: [4]QueueEvent = undefined,

    fn record(self: *QueueOrderRecorder, event: QueueEvent) void {
        const index = self.next_index.fetchAdd(1, .seq_cst);
        self.events[index] = event;
    }
};

const QueueThreadContext = struct {
    io: std.Io = std.testing.io,
    path: []const u8,
    start_event: QueueEvent,
    end_event: QueueEvent,
    hold_ms: i64 = 0,
    recorder: *QueueOrderRecorder,
};

fn runQueuedThread(context: *QueueThreadContext) void {
    var guard = acquire(context.io, context.path) catch unreachable;
    defer guard.release();

    context.recorder.record(context.start_event);
    if (context.hold_ms > 0) {
        std.Io.sleep(context.io, .fromMilliseconds(context.hold_ms), .awake) catch unreachable;
    }
    context.recorder.record(context.end_event);
}

fn eventIndex(events: [4]QueueEvent, target: QueueEvent) usize {
    for (events, 0..) |event, index| {
        if (event == target) return index;
    }
    unreachable;
}

fn makeAbsoluteTestPath(
    allocator: std.mem.Allocator,
    tmp: anytype,
    relative_path: []const u8,
) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    return std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        relative_path,
    });
}

test "file mutation queue serializes operations for the same file" {
    var recorder = QueueOrderRecorder{};
    var first = QueueThreadContext{
        .path = "/tmp/pi-file-mutation-queue-same",
        .start_event = .first_start,
        .end_event = .first_end,
        .hold_ms = 30,
        .recorder = &recorder,
    };
    var second = QueueThreadContext{
        .path = "/tmp/pi-file-mutation-queue-same",
        .start_event = .second_start,
        .end_event = .second_end,
        .recorder = &recorder,
    };

    const first_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&first});
    try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    const second_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&second});

    first_thread.join();
    second_thread.join();

    try std.testing.expectEqualSlices(
        QueueEvent,
        &[_]QueueEvent{ .first_start, .first_end, .second_start, .second_end },
        recorder.events[0..],
    );
}

test "file mutation queue allows different files to proceed in parallel" {
    var recorder = QueueOrderRecorder{};
    var first = QueueThreadContext{
        .path = "/tmp/pi-file-mutation-queue-a",
        .start_event = .first_start,
        .end_event = .first_end,
        .hold_ms = 30,
        .recorder = &recorder,
    };
    var second = QueueThreadContext{
        .path = "/tmp/pi-file-mutation-queue-b",
        .start_event = .second_start,
        .end_event = .second_end,
        .hold_ms = 30,
        .recorder = &recorder,
    };

    const first_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&first});
    try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    const second_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&second});

    first_thread.join();
    second_thread.join();

    const first_start = eventIndex(recorder.events, .first_start);
    const first_end = eventIndex(recorder.events, .first_end);
    const second_start = eventIndex(recorder.events, .second_start);
    const second_end = eventIndex(recorder.events, .second_end);

    try std.testing.expect(first_start < first_end);
    try std.testing.expect(second_start < second_end);
    try std.testing.expect(second_start < first_end);
}

test "file mutation queue uses the same key for symlink aliases" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "target.txt",
        .data = "hello\n",
    });

    const target_path = try makeAbsoluteTestPath(std.testing.allocator, tmp, "target.txt");
    defer std.testing.allocator.free(target_path);
    const symlink_path = try makeAbsoluteTestPath(std.testing.allocator, tmp, "alias.txt");
    defer std.testing.allocator.free(symlink_path);

    try std.Io.Dir.symLinkAbsolute(std.testing.io, target_path, symlink_path, .{});

    var recorder = QueueOrderRecorder{};
    var first = QueueThreadContext{
        .path = target_path,
        .start_event = .first_start,
        .end_event = .first_end,
        .hold_ms = 30,
        .recorder = &recorder,
    };
    var second = QueueThreadContext{
        .path = symlink_path,
        .start_event = .second_start,
        .end_event = .second_end,
        .recorder = &recorder,
    };

    const first_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&first});
    try std.Io.sleep(std.testing.io, .fromMilliseconds(5), .awake);
    const second_thread = try std.Thread.spawn(.{}, runQueuedThread, .{&second});

    first_thread.join();
    second_thread.join();

    try std.testing.expectEqualSlices(
        QueueEvent,
        &[_]QueueEvent{ .first_start, .first_end, .second_start, .second_end },
        recorder.events[0..],
    );
}
