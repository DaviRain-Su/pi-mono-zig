const std = @import("std");
const auth = @import("auth.zig");
const session_manager = @import("session_manager.zig");
const common = @import("tools/common.zig");

const AUTH_FILE_PERMISSIONS: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
    std.Io.File.Permissions.fromMode(0o600)
else
    .default_file;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_dir: []const u8,
) !void {
    const absolute_agent_dir = if (std.fs.path.isAbsolute(agent_dir))
        try allocator.dupe(u8, agent_dir)
    else blk: {
        const cwd = try std.process.currentPathAlloc(io, allocator);
        defer allocator.free(cwd);
        break :blk try std.fs.path.resolve(allocator, &[_][]const u8{ cwd, agent_dir });
    };
    defer allocator.free(absolute_agent_dir);

    try migrateAuthStorage(allocator, io, absolute_agent_dir);
    _ = try migrateLegacySessionPaths(allocator, io, absolute_agent_dir);
}

fn migrateAuthStorage(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_dir: []const u8,
) !void {
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);
    if (try pathExists(io, auth_path)) return;

    const oauth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "oauth.json" });
    defer allocator.free(oauth_path);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);

    const oauth_content = try readOptionalFile(allocator, io, oauth_path);
    defer if (oauth_content) |value| allocator.free(value);

    var migrated_auth = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    var migrated_auth_count: usize = 0;
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = migrated_auth };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    var migrated_oauth = false;
    if (oauth_content) |content| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
        if (parsed) |*parsed_value| {
            defer parsed_value.deinit();
            if (parsed_value.value == .object) {
                var iterator = parsed_value.value.object.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    try migrated_auth.put(
                        allocator,
                        try allocator.dupe(u8, entry.key_ptr.*),
                        try cloneStoredCredentialObject(allocator, entry.value_ptr.object, "oauth"),
                    );
                    migrated_auth_count += 1;
                    migrated_oauth = true;
                }
            }
        }
    }

    const settings_content = try readOptionalFile(allocator, io, settings_path);
    defer if (settings_content) |value| allocator.free(value);

    var rewritten_settings: ?[]u8 = null;
    defer if (rewritten_settings) |value| allocator.free(value);

    if (settings_content) |content| {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch null;
        if (parsed) |*parsed_value| {
            defer parsed_value.deinit();
            if (parsed_value.value == .object) {
                const next_settings = try cloneObjectWithoutKey(allocator, parsed_value.value.object, "apiKeys");
                errdefer {
                    const cleanup_value: std.json.Value = .{ .object = next_settings };
                    common.deinitJsonValue(allocator, cleanup_value);
                }

                var removed_api_keys = false;
                if (parsed_value.value.object.get("apiKeys")) |api_keys_value| {
                    if (api_keys_value == .object) {
                        removed_api_keys = true;
                        var iterator = api_keys_value.object.iterator();
                        while (iterator.next()) |entry| {
                            if (entry.value_ptr.* != .string) continue;
                            if (migrated_auth.contains(entry.key_ptr.*)) continue;
                            try migrated_auth.put(
                                allocator,
                                try allocator.dupe(u8, entry.key_ptr.*),
                                try makeApiKeyCredentialObject(allocator, entry.value_ptr.string),
                            );
                            migrated_auth_count += 1;
                        }
                    }
                }

                if (removed_api_keys) {
                    const settings_value: std.json.Value = .{ .object = next_settings };
                    rewritten_settings = try std.json.Stringify.valueAlloc(allocator, settings_value, .{ .whitespace = .indent_2 });
                    common.deinitJsonValue(allocator, settings_value);
                } else {
                    const cleanup_value: std.json.Value = .{ .object = next_settings };
                    common.deinitJsonValue(allocator, cleanup_value);
                }
            }
        }
    }

    if (migrated_auth_count > 0) {
        try writeJsonObjectFileWithPermissions(allocator, io, auth_path, migrated_auth);
    } else {
        const cleanup_value: std.json.Value = .{ .object = migrated_auth };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    if (rewritten_settings) |serialized| {
        try common.writeFileAbsolute(io, settings_path, serialized, true);
    }

    if (migrated_oauth) {
        const migrated_path = try std.fmt.allocPrint(allocator, "{s}.migrated", .{oauth_path});
        defer allocator.free(migrated_path);

        if (oauth_content) |content| {
            if (!(try pathExists(io, migrated_path))) {
                try common.writeFileAbsolute(io, migrated_path, content, true);
            }
        }
        try deleteFileIfExists(io, oauth_path);
    }
}

fn migrateLegacySessionPaths(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_dir: []const u8,
) !usize {
    var migrated_count: usize = 0;
    migrated_count += try migrateLegacyJsonlFilesInDir(allocator, io, agent_dir);

    const sessions_root = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "sessions" });
    defer allocator.free(sessions_root);

    var dir = std.Io.Dir.openDirAbsolute(io, sessions_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return migrated_count,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!isLegacySessionDirectory(entry.name)) continue;

        const child_dir = try std.fs.path.join(allocator, &[_][]const u8{ sessions_root, entry.name });
        defer allocator.free(child_dir);
        migrated_count += try migrateLegacyJsonlFilesInDir(allocator, io, child_dir);
    }

    return migrated_count;
}

fn migrateLegacyJsonlFilesInDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
) !usize {
    var dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer dir.close(io);

    var migrated_count: usize = 0;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const source_path = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, entry.name });
        defer allocator.free(source_path);

        if (try migrateLegacySessionFile(allocator, io, source_path)) {
            migrated_count += 1;
        }
    }

    return migrated_count;
}

fn migrateLegacySessionFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    source_path: []const u8,
) !bool {
    const source_bytes = try readOptionalFile(allocator, io, source_path) orelse return false;
    defer allocator.free(source_bytes);

    var header = parseSessionHeader(allocator, source_bytes) catch return false;
    defer header.deinit(allocator);

    if (!std.fs.path.isAbsolute(header.cwd)) return false;

    const file_name = std.fs.path.basename(source_path);
    const target_dir = try std.fs.path.join(allocator, &[_][]const u8{ header.cwd, ".pi", "sessions" });
    defer allocator.free(target_dir);
    const target_path = try std.fs.path.join(allocator, &[_][]const u8{ target_dir, file_name });
    defer allocator.free(target_path);

    if (std.mem.eql(u8, target_path, source_path)) return false;

    if (try readOptionalFile(allocator, io, target_path)) |existing_target| {
        defer allocator.free(existing_target);
        if (std.mem.eql(u8, existing_target, source_bytes)) {
            try deleteFileIfExists(io, source_path);
            return true;
        }
        return false;
    }

    try common.writeFileAbsolute(io, target_path, source_bytes, true);

    const verified_target = try readOptionalFile(allocator, io, target_path) orelse return error.MigrationVerificationFailed;
    defer allocator.free(verified_target);
    if (!std.mem.eql(u8, verified_target, source_bytes)) {
        return error.MigrationVerificationFailed;
    }

    try deleteFileIfExists(io, source_path);
    return true;
}

const ParsedSessionHeader = struct {
    cwd: []u8,

    fn deinit(self: *ParsedSessionHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.cwd);
        self.* = undefined;
    }
};

fn parseSessionHeader(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !ParsedSessionHeader {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const header_line = lines.next() orelse return error.InvalidSessionFile;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, header_line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSessionFile;

    const entry_type = parsed.value.object.get("type") orelse return error.InvalidSessionFile;
    if (entry_type != .string or !std.mem.eql(u8, entry_type.string, "session")) {
        return error.InvalidSessionFile;
    }

    const cwd_value = parsed.value.object.get("cwd") orelse return error.InvalidSessionFile;
    if (cwd_value != .string) return error.InvalidSessionFile;

    return .{
        .cwd = try allocator.dupe(u8, cwd_value.string),
    };
}

fn cloneStoredCredentialObject(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    auth_type: []const u8,
) !std.json.Value {
    var cloned = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = cloned };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "type")) continue;
        try cloned.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            try common.cloneJsonValue(allocator, entry.value_ptr.*),
        );
    }
    try cloned.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, auth_type) });
    return .{ .object = cloned };
}

fn makeApiKeyCredentialObject(
    allocator: std.mem.Allocator,
    key: []const u8,
) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = object };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "api_key") });
    try object.put(allocator, try allocator.dupe(u8, "key"), .{ .string = try allocator.dupe(u8, key) });
    return .{ .object = object };
}

fn cloneObjectWithoutKey(
    allocator: std.mem.Allocator,
    object: std.json.ObjectMap,
    omitted_key: []const u8,
) !std.json.ObjectMap {
    var cloned = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = cloned };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, omitted_key)) continue;
        try cloned.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            try common.cloneJsonValue(allocator, entry.value_ptr.*),
        );
    }

    return cloned;
}

fn writeJsonObjectFileWithPermissions(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    object: std.json.ObjectMap,
) !void {
    const value: std.json.Value = .{ .object = object };
    defer common.deinitJsonValue(allocator, value);

    const serialized = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);

    var atomic_file = try std.Io.Dir.createFileAtomic(.cwd(), io, path, .{
        .permissions = AUTH_FILE_PERMISSIONS,
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [1024]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buffer);
    try writer.interface.writeAll(serialized);
    try writer.flush();
    try atomic_file.replace(io);
}

fn readOptionalFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) !?[]u8 {
    return std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    _ = std.Io.Dir.statFile(.cwd(), io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn deleteFileIfExists(io: std.Io, path: []const u8) !void {
    std.Io.Dir.deleteFile(.cwd(), io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn isLegacySessionDirectory(name: []const u8) bool {
    return name.len >= 4 and std.mem.startsWith(u8, name, "--") and std.mem.endsWith(u8, name, "--");
}

fn makeTmpPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);

    if (name.len == 0) {
        return std.fs.path.resolve(allocator, &[_][]const u8{
            cwd,
            ".zig-cache",
            "tmp",
            &tmp.sub_path,
        });
    }

    return std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        name,
    });
}

fn writeLegacySessionFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    file_path: []const u8,
    cwd: []const u8,
    session_id: []const u8,
    text: []const u8,
) !void {
    const bytes = try std.fmt.allocPrint(
        allocator,
        "{{\"type\":\"session\",\"id\":\"{s}\",\"timestamp\":\"1\",\"cwd\":\"{s}\"}}\n" ++
            "{{\"type\":\"message\",\"id\":\"00000001\",\"parentId\":null,\"timestamp\":\"2\",\"message\":{{\"role\":\"user\",\"content\":\"{s}\",\"timestamp\":1}}}}\n",
        .{ session_id, cwd, text },
    );
    defer allocator.free(bytes);
    try common.writeFileAbsolute(io, file_path, bytes, true);
}

test "run migrates oauth credentials and settings api keys into auth.json" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const oauth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "oauth.json" });
    defer allocator.free(oauth_path);
    const settings_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "settings.json" });
    defer allocator.free(settings_path);
    const auth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "auth.json" });
    defer allocator.free(auth_path);
    const migrated_oauth_path = try std.fmt.allocPrint(allocator, "{s}.migrated", .{oauth_path});
    defer allocator.free(migrated_oauth_path);

    try common.writeFileAbsolute(
        std.testing.io,
        oauth_path,
        \\{
        \\  "anthropic": {
        \\    "access": "oauth-access",
        \\    "refresh": "oauth-refresh",
        \\    "expires": 42
        \\  }
        \\}
    ,
        true,
    );
    try common.writeFileAbsolute(
        std.testing.io,
        settings_path,
        \\{
        \\  "defaultProvider": "openai",
        \\  "apiKeys": {
        \\    "openai": "settings-openai-key"
        \\  }
        \\}
    ,
        true,
    );

    try run(allocator, std.testing.io, agent_dir);

    try std.testing.expect(try pathExists(std.testing.io, auth_path));
    try std.testing.expect(!(try pathExists(std.testing.io, oauth_path)));
    try std.testing.expect(try pathExists(std.testing.io, migrated_oauth_path));

    const auth_value = try auth.readStoredCredentialsObject(allocator, std.testing.io, auth_path);
    defer common.deinitJsonValue(allocator, auth_value);

    try std.testing.expect(auth_value == .object);
    const anthropic_entry = auth_value.object.get("anthropic").?;
    try std.testing.expect(anthropic_entry == .object);
    try std.testing.expectEqualStrings("oauth", anthropic_entry.object.get("type").?.string);
    try std.testing.expectEqualStrings("oauth-access", anthropic_entry.object.get("access").?.string);

    const openai_entry = auth_value.object.get("openai").?;
    try std.testing.expect(openai_entry == .object);
    try std.testing.expectEqualStrings("api_key", openai_entry.object.get("type").?.string);
    try std.testing.expectEqualStrings("settings-openai-key", openai_entry.object.get("key").?.string);

    const settings_bytes = (try readOptionalFile(allocator, std.testing.io, settings_path)).?;
    defer allocator.free(settings_bytes);
    try std.testing.expect(std.mem.indexOf(u8, settings_bytes, "\"defaultProvider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, settings_bytes, "\"apiKeys\"") == null);
}

test "run migrates legacy session files into project session directories and preserves content" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeTmpPath(allocator, tmp, "home/.pi/agent");
    defer allocator.free(agent_dir);
    const project_a = try makeTmpPath(allocator, tmp, "workspace/project-a");
    defer allocator.free(project_a);
    const project_b = try makeTmpPath(allocator, tmp, "workspace/project-b");
    defer allocator.free(project_b);

    const root_legacy = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "legacy-root.jsonl" });
    defer allocator.free(root_legacy);
    const nested_legacy = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "sessions", "--project-b--", "legacy-nested.jsonl" });
    defer allocator.free(nested_legacy);

    try writeLegacySessionFile(allocator, std.testing.io, root_legacy, project_a, "session-root", "root legacy text");
    try writeLegacySessionFile(allocator, std.testing.io, nested_legacy, project_b, "session-nested", "nested legacy text");

    try run(allocator, std.testing.io, agent_dir);

    try std.testing.expect(!(try pathExists(std.testing.io, root_legacy)));
    try std.testing.expect(!(try pathExists(std.testing.io, nested_legacy)));

    const migrated_root = try std.fs.path.join(allocator, &[_][]const u8{ project_a, ".pi", "sessions", "legacy-root.jsonl" });
    defer allocator.free(migrated_root);
    const migrated_nested = try std.fs.path.join(allocator, &[_][]const u8{ project_b, ".pi", "sessions", "legacy-nested.jsonl" });
    defer allocator.free(migrated_nested);

    try std.testing.expect(try pathExists(std.testing.io, migrated_root));
    try std.testing.expect(try pathExists(std.testing.io, migrated_nested));

    var reopened_root = try session_manager.SessionManager.open(allocator, std.testing.io, migrated_root, null);
    defer reopened_root.deinit();
    var root_context = try reopened_root.buildSessionContext(allocator);
    defer root_context.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), root_context.messages.len);
    try std.testing.expectEqualStrings("root legacy text", root_context.messages[0].user.content[0].text.text);

    var reopened_nested = try session_manager.SessionManager.open(allocator, std.testing.io, migrated_nested, null);
    defer reopened_nested.deinit();
    var nested_context = try reopened_nested.buildSessionContext(allocator);
    defer nested_context.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), nested_context.messages.len);
    try std.testing.expectEqualStrings("nested legacy text", nested_context.messages[0].user.content[0].text.text);
}
