const std = @import("std");
const ai = @import("ai");
const common = @import("tools/common.zig");

const DEFAULT_ANTHROPIC_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";

const ANTHROPIC_AUTHORIZE_URL = "https://claude.ai/oauth/authorize";
const ANTHROPIC_TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
const ANTHROPIC_REDIRECT_URI = "http://localhost:53692/callback";
const ANTHROPIC_SCOPES =
    "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

const GOOGLE_AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token";
const GOOGLE_REDIRECT_URI = "http://localhost:8085/oauth2callback";
const GOOGLE_SCOPES = [_][]const u8{
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
};

const GITHUB_DEVICE_CODE_URL = "https://github.com/login/device/code";
const GITHUB_ACCESS_TOKEN_URL = "https://github.com/login/oauth/access_token";
const GITHUB_COPILOT_TOKEN_URL = "https://api.github.com/copilot_internal/v2/token";

const COPILOT_USER_AGENT = "GitHubCopilotChat/0.35.0";
const COPILOT_EDITOR_VERSION = "vscode/1.107.0";
const COPILOT_PLUGIN_VERSION = "copilot-chat/0.35.0";
const COPILOT_INTEGRATION_ID = "vscode-chat";
const OAUTH_CONFIG_FILE_NAME = "oauth.json";
const AUTH_FILE_PERMISSIONS: std.Io.File.Permissions = if (@hasDecl(std.Io.File.Permissions, "fromMode"))
    std.Io.File.Permissions.fromMode(0o600)
else
    .default_file;

pub const OAuthClientCredentials = struct {
    client_id: []u8,
    client_secret: ?[]u8 = null,

    pub fn deinit(self: *OAuthClientCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        if (self.client_secret) |client_secret| allocator.free(client_secret);
        self.* = undefined;
    }
};

pub const ProviderInfo = struct {
    id: []const u8,
    name: []const u8,
};

pub const SUPPORTED_PROVIDERS = [_]ProviderInfo{
    .{ .id = "anthropic", .name = "Anthropic (Claude Pro/Max)" },
    .{ .id = "github-copilot", .name = "GitHub Copilot" },
    .{ .id = "google-gemini-cli", .name = "Google Cloud Code Assist (Gemini CLI)" },
};

pub const OAuthCredential = struct {
    access: []u8,
    refresh: []u8,
    expires: i64,
    project_id: ?[]u8 = null,

    pub fn deinit(self: *OAuthCredential, allocator: std.mem.Allocator) void {
        allocator.free(self.access);
        allocator.free(self.refresh);
        if (self.project_id) |project_id| allocator.free(project_id);
        self.* = undefined;
    }
};

pub const StoredCredential = union(enum) {
    api_key: []u8,
    oauth: OAuthCredential,

    pub fn deinit(self: *StoredCredential, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .api_key => |value| allocator.free(value),
            .oauth => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const BrowserLoginKind = enum {
    anthropic,
    google_gemini_cli,
};

pub const BrowserLoginSession = struct {
    kind: BrowserLoginKind,
    provider_id: []const u8,
    provider_name: []const u8,
    oauth_client: OAuthClientCredentials,
    auth_url: []u8,
    verifier: []u8,

    pub fn deinit(self: *BrowserLoginSession, allocator: std.mem.Allocator) void {
        self.oauth_client.deinit(allocator);
        allocator.free(self.auth_url);
        allocator.free(self.verifier);
        self.* = undefined;
    }
};

pub const CopilotDeviceLogin = struct {
    provider_id: []const u8 = "github-copilot",
    provider_name: []const u8 = "GitHub Copilot",
    oauth_client: OAuthClientCredentials,
    device_code: []u8,
    user_code: []u8,
    verification_uri: []u8,
    interval_seconds: u32,
    expires_at_ms: i64,

    pub fn deinit(self: *CopilotDeviceLogin, allocator: std.mem.Allocator) void {
        self.oauth_client.deinit(allocator);
        allocator.free(self.device_code);
        allocator.free(self.user_code);
        allocator.free(self.verification_uri);
        self.* = undefined;
    }
};

pub const CopilotPollResult = union(enum) {
    pending: []u8,
    completed: OAuthCredential,

    pub fn deinit(self: *CopilotPollResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .pending => |value| allocator.free(value),
            .completed => |*value| value.deinit(allocator),
        }
        self.* = undefined;
    }
};

pub const GoogleExchangeResult = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires: i64,

    pub fn deinit(self: *GoogleExchangeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.access_token);
        allocator.free(self.refresh_token);
        self.* = undefined;
    }
};

pub fn findSupportedProvider(provider_id: []const u8) ?ProviderInfo {
    for (SUPPORTED_PROVIDERS) |provider| {
        if (std.mem.eql(u8, provider.id, provider_id)) return provider;
    }
    return null;
}

pub fn startBrowserLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider_id: []const u8,
) !BrowserLoginSession {
    // Check if OAuth config exists before starting the flow
    const oauth_path = try resolveOAuthConfigPath(allocator, env_map);
    defer allocator.free(oauth_path);

    const content = std.Io.Dir.readFileAlloc(.cwd(), io, oauth_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => {
            return error.MissingOAuthConfigFile;
        },
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.InvalidOAuthConfigFile;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOAuthConfigFile;

    const provider_object = findOAuthProviderObject(parsed.value.object, provider_id);
    if (provider_object == null) {
        return error.MissingOAuthClientConfig;
    }

    if (std.mem.eql(u8, provider_id, "anthropic")) return startAnthropicBrowserLogin(allocator, io, env_map);
    if (std.mem.eql(u8, provider_id, "google-gemini-cli")) return startGoogleBrowserLogin(allocator, io, env_map);
    return error.UnsupportedProvider;
}

pub fn startAnthropicBrowserLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !BrowserLoginSession {
    const provider = findSupportedProvider("anthropic").?;
    const verifier = try generatePkceVerifier(allocator, io);
    errdefer allocator.free(verifier);
    const challenge = try generatePkceChallenge(allocator, verifier);
    defer allocator.free(challenge);
    var oauth_client = try loadOAuthClientCredentials(allocator, io, env_map, provider.id, false);
    errdefer oauth_client.deinit(allocator);
    const encoded_client_id = try formEncode(allocator, oauth_client.client_id);
    defer allocator.free(encoded_client_id);
    const encoded_redirect_uri = try formEncode(allocator, ANTHROPIC_REDIRECT_URI);
    defer allocator.free(encoded_redirect_uri);
    const encoded_scope = try formEncode(allocator, ANTHROPIC_SCOPES);
    defer allocator.free(encoded_scope);
    const encoded_challenge = try formEncode(allocator, challenge);
    defer allocator.free(encoded_challenge);
    const encoded_state = try formEncode(allocator, verifier);
    defer allocator.free(encoded_state);

    const auth_url = try std.fmt.allocPrint(
        allocator,
        "{s}?code=true&client_id={s}&response_type=code&redirect_uri={s}&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}",
        .{
            ANTHROPIC_AUTHORIZE_URL,
            encoded_client_id,
            encoded_redirect_uri,
            encoded_scope,
            encoded_challenge,
            encoded_state,
        },
    );

    return .{
        .kind = .anthropic,
        .provider_id = provider.id,
        .provider_name = provider.name,
        .oauth_client = oauth_client,
        .auth_url = auth_url,
        .verifier = verifier,
    };
}

pub fn startGoogleBrowserLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !BrowserLoginSession {
    const provider = findSupportedProvider("google-gemini-cli").?;
    const verifier = try generatePkceVerifier(allocator, io);
    errdefer allocator.free(verifier);
    const challenge = try generatePkceChallenge(allocator, verifier);
    defer allocator.free(challenge);
    var oauth_client = try loadOAuthClientCredentials(allocator, io, env_map, provider.id, true);
    errdefer oauth_client.deinit(allocator);
    const encoded_client_id = try formEncode(allocator, oauth_client.client_id);
    defer allocator.free(encoded_client_id);
    const encoded_redirect_uri = try formEncode(allocator, GOOGLE_REDIRECT_URI);
    defer allocator.free(encoded_redirect_uri);
    const joined_scope = try std.mem.join(allocator, " ", &GOOGLE_SCOPES);
    defer allocator.free(joined_scope);
    const encoded_scope = try formEncode(allocator, joined_scope);
    defer allocator.free(encoded_scope);
    const encoded_challenge = try formEncode(allocator, challenge);
    defer allocator.free(encoded_challenge);
    const encoded_state = try formEncode(allocator, verifier);
    defer allocator.free(encoded_state);

    const auth_url = try std.fmt.allocPrint(
        allocator,
        "{s}?client_id={s}&response_type=code&redirect_uri={s}&scope={s}&code_challenge={s}&code_challenge_method=S256&state={s}&access_type=offline&prompt=consent",
        .{
            GOOGLE_AUTHORIZE_URL,
            encoded_client_id,
            encoded_redirect_uri,
            encoded_scope,
            encoded_challenge,
            encoded_state,
        },
    );

    return .{
        .kind = .google_gemini_cli,
        .provider_id = provider.id,
        .provider_name = provider.name,
        .oauth_client = oauth_client,
        .auth_url = auth_url,
        .verifier = verifier,
    };
}

pub fn completeBrowserLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const BrowserLoginSession,
    input: []const u8,
) !StoredCredential {
    return switch (session.kind) {
        .anthropic => .{ .oauth = try exchangeAnthropicAuthorizationCode(allocator, io, session, input) },
        .google_gemini_cli => return error.MissingProjectId,
    };
}

pub fn exchangeGoogleAuthorizationCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const BrowserLoginSession,
    input: []const u8,
) !GoogleExchangeResult {
    if (session.kind != .google_gemini_cli) return error.UnsupportedProvider;
    const parsed = try parseAuthorizationInput(allocator, input);
    defer parsed.deinit(allocator);

    if (parsed.state) |state| {
        if (!std.mem.eql(u8, state, session.verifier)) return error.InvalidOAuthState;
    }

    const code = parsed.code orelse return error.MissingAuthorizationCode;
    const body = try buildFormBody(allocator, &.{
        .{ .name = "client_id", .value = session.oauth_client.client_id },
        .{ .name = "client_secret", .value = session.oauth_client.client_secret orelse return error.MissingOAuthClientSecret },
        .{ .name = "code", .value = code },
        .{ .name = "grant_type", .value = "authorization_code" },
        .{ .name = "redirect_uri", .value = GOOGLE_REDIRECT_URI },
        .{ .name = "code_verifier", .value = session.verifier },
    });
    defer allocator.free(body);

    const response_body = try postForm(allocator, io, GOOGLE_TOKEN_URL, body, null);
    defer allocator.free(response_body);

    var parsed_response = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed_response.deinit();
    if (parsed_response.value != .object) return error.InvalidAuthResponse;

    const access_token = getObjectString(parsed_response.value.object, "access_token") orelse return error.MissingAccessToken;
    const refresh_token = getObjectString(parsed_response.value.object, "refresh_token") orelse return error.MissingRefreshToken;
    const expires_in = getObjectInt(parsed_response.value.object, "expires_in") orelse return error.InvalidAuthResponse;

    return .{
        .access_token = try allocator.dupe(u8, access_token),
        .refresh_token = try allocator.dupe(u8, refresh_token),
        .expires = computeExpiresAtMs(expires_in, io),
    };
}

pub fn finalizeGoogleCredential(
    allocator: std.mem.Allocator,
    exchange: *const GoogleExchangeResult,
    project_id: []const u8,
) !StoredCredential {
    if (std.mem.trim(u8, project_id, &std.ascii.whitespace).len == 0) return error.MissingProjectId;
    return .{
        .oauth = .{
            .access = try allocator.dupe(u8, exchange.access_token),
            .refresh = try allocator.dupe(u8, exchange.refresh_token),
            .expires = exchange.expires,
            .project_id = try allocator.dupe(u8, std.mem.trim(u8, project_id, &std.ascii.whitespace)),
        },
    };
}

pub fn startGitHubCopilotLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) !CopilotDeviceLogin {
    const provider = findSupportedProvider("github-copilot").?;
    var oauth_client = try loadOAuthClientCredentials(allocator, io, env_map, provider.id, false);
    errdefer oauth_client.deinit(allocator);
    const body = try buildFormBody(allocator, &.{
        .{ .name = "client_id", .value = oauth_client.client_id },
        .{ .name = "scope", .value = "read:user" },
    });
    defer allocator.free(body);

    var headers = try initHeaders(allocator, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "User-Agent", .value = COPILOT_USER_AGENT },
    });
    defer deinitHeaders(allocator, &headers);

    const response_body = try postForm(allocator, io, GITHUB_DEVICE_CODE_URL, body, &headers);
    defer allocator.free(response_body);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthResponse;

    const device_code = getObjectString(parsed.value.object, "device_code") orelse return error.InvalidAuthResponse;
    const user_code = getObjectString(parsed.value.object, "user_code") orelse return error.InvalidAuthResponse;
    const verification_uri = getObjectString(parsed.value.object, "verification_uri") orelse return error.InvalidAuthResponse;
    const interval = getObjectInt(parsed.value.object, "interval") orelse return error.InvalidAuthResponse;
    const expires_in = getObjectInt(parsed.value.object, "expires_in") orelse return error.InvalidAuthResponse;

    return .{
        .provider_id = provider.id,
        .provider_name = provider.name,
        .oauth_client = oauth_client,
        .device_code = try allocator.dupe(u8, device_code),
        .user_code = try allocator.dupe(u8, user_code),
        .verification_uri = try allocator.dupe(u8, verification_uri),
        .interval_seconds = @intCast(interval),
        .expires_at_ms = currentTimeMs(io) + expires_in * std.time.ms_per_s,
    };
}

pub fn pollGitHubCopilotLogin(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const CopilotDeviceLogin,
) !CopilotPollResult {
    if (currentTimeMs(io) >= session.expires_at_ms) return error.AuthenticationExpired;

    const body = try buildFormBody(allocator, &.{
        .{ .name = "client_id", .value = session.oauth_client.client_id },
        .{ .name = "device_code", .value = session.device_code },
        .{ .name = "grant_type", .value = "urn:ietf:params:oauth:grant-type:device_code" },
    });
    defer allocator.free(body);

    var headers = try initHeaders(allocator, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "User-Agent", .value = COPILOT_USER_AGENT },
    });
    defer deinitHeaders(allocator, &headers);

    const response_body = try postForm(allocator, io, GITHUB_ACCESS_TOKEN_URL, body, &headers);
    defer allocator.free(response_body);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthResponse;

    if (getObjectString(parsed.value.object, "access_token")) |github_access_token| {
        return .{
            .completed = try refreshGitHubCopilotToken(allocator, io, github_access_token),
        };
    }

    const error_name = getObjectString(parsed.value.object, "error") orelse return error.InvalidAuthResponse;
    if (std.mem.eql(u8, error_name, "authorization_pending")) {
        return .{ .pending = try allocator.dupe(u8, "Authorization still pending. Finish login in the browser, then press Enter again.") };
    }
    if (std.mem.eql(u8, error_name, "slow_down")) {
        return .{ .pending = try allocator.dupe(u8, "GitHub asked to slow down polling. Wait a few seconds, then press Enter again.") };
    }
    if (std.mem.eql(u8, error_name, "expired_token")) return error.AuthenticationExpired;
    if (std.mem.eql(u8, error_name, "access_denied")) return error.AuthenticationDenied;
    return error.InvalidAuthResponse;
}

pub fn buildApiKeyFromStoredEntry(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    object: std.json.ObjectMap,
) !?[]u8 {
    const type_value = getObjectString(object, "type");
    if (type_value) |value| {
        if (std.mem.eql(u8, value, "api_key")) {
            const key = getObjectString(object, "key") orelse return null;
            return try allocator.dupe(u8, key);
        }
        if (std.mem.eql(u8, value, "oauth")) {
            const access = getObjectString(object, "access") orelse getObjectString(object, "access_token") orelse return null;
            if (std.mem.eql(u8, provider_id, "google-gemini-cli")) {
                const project_id = getObjectString(object, "projectId") orelse getObjectString(object, "project_id") orelse return null;
                return try buildGoogleStoredApiKey(allocator, access, project_id);
            }
            return try allocator.dupe(u8, access);
        }
    }

    if (getObjectString(object, "key")) |key| return try allocator.dupe(u8, key);
    return null;
}

pub fn listStoredProviders(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
) ![]ProviderInfo {
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, auth_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(ProviderInfo, 0),
        else => return allocator.alloc(ProviderInfo, 0),
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return allocator.alloc(ProviderInfo, 0);
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.alloc(ProviderInfo, 0);

    var providers = std.ArrayList(ProviderInfo).empty;
    errdefer providers.deinit(allocator);

    for (SUPPORTED_PROVIDERS) |provider| {
        if (parsed.value.object.get(provider.id)) |entry| {
            if (entry == .object) try providers.append(allocator, provider);
        }
    }

    return try providers.toOwnedSlice(allocator);
}

pub fn upsertStoredCredential(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
    provider_id: []const u8,
    credential: *const StoredCredential,
) !void {
    const existing = try readAuthFileObject(allocator, io, auth_path);
    defer common.deinitJsonValue(allocator, existing);

    var next_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    if (existing == .object) {
        var iterator = existing.object.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, provider_id)) continue;
            try next_object.put(
                allocator,
                try allocator.dupe(u8, entry.key_ptr.*),
                try common.cloneJsonValue(allocator, entry.value_ptr.*),
            );
        }
    }

    try next_object.put(allocator, try allocator.dupe(u8, provider_id), try credentialToJson(allocator, credential));
    try writeAuthObject(allocator, io, auth_path, next_object);
}

pub fn removeStoredCredential(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
    provider_id: []const u8,
) !bool {
    const existing = try readAuthFileObject(allocator, io, auth_path);
    defer common.deinitJsonValue(allocator, existing);
    if (existing != .object) return false;

    var next_object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    var removed = false;
    var iterator = existing.object.iterator();
    while (iterator.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, provider_id)) {
            removed = true;
            continue;
        }
        try next_object.put(
            allocator,
            try allocator.dupe(u8, entry.key_ptr.*),
            try common.cloneJsonValue(allocator, entry.value_ptr.*),
        );
    }

    if (!removed) {
        const cleanup_value: std.json.Value = .{ .object = next_object };
        common.deinitJsonValue(allocator, cleanup_value);
        return false;
    }

    try writeAuthObject(allocator, io, auth_path, next_object);
    return true;
}

const EncodedField = struct {
    name: []const u8,
    value: []const u8,
};

const AuthorizationInput = struct {
    code: ?[]u8 = null,
    state: ?[]u8 = null,

    fn deinit(self: *const AuthorizationInput, allocator: std.mem.Allocator) void {
        if (self.code) |value| allocator.free(value);
        if (self.state) |value| allocator.free(value);
    }
};

fn credentialToJson(allocator: std.mem.Allocator, credential: *const StoredCredential) !std.json.Value {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    errdefer {
        const cleanup_value: std.json.Value = .{ .object = object };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    switch (credential.*) {
        .api_key => |key| {
            try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "api_key") });
            try object.put(allocator, try allocator.dupe(u8, "key"), .{ .string = try allocator.dupe(u8, key) });
        },
        .oauth => |oauth| {
            try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "oauth") });
            try object.put(allocator, try allocator.dupe(u8, "access"), .{ .string = try allocator.dupe(u8, oauth.access) });
            try object.put(allocator, try allocator.dupe(u8, "refresh"), .{ .string = try allocator.dupe(u8, oauth.refresh) });
            try object.put(allocator, try allocator.dupe(u8, "expires"), .{ .integer = oauth.expires });
            if (oauth.project_id) |project_id| {
                try object.put(allocator, try allocator.dupe(u8, "projectId"), .{ .string = try allocator.dupe(u8, project_id) });
            }
        },
    }

    return .{ .object = object };
}

fn readAuthFileObject(allocator: std.mem.Allocator, io: std.Io, auth_path: []const u8) !std.json.Value {
    const content = std.Io.Dir.readFileAlloc(.cwd(), io, auth_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) },
        else => return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) },
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return .{ .object = try std.json.ObjectMap.init(allocator, &.{}, &.{}) };
    }

    return try common.cloneJsonValue(allocator, parsed.value);
}

fn writeAuthObject(
    allocator: std.mem.Allocator,
    io: std.Io,
    auth_path: []const u8,
    object: std.json.ObjectMap,
) !void {
    const value: std.json.Value = .{ .object = object };
    defer common.deinitJsonValue(allocator, value);

    const serialized = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);

    var atomic_file = try std.Io.Dir.createFileAtomic(.cwd(), io, auth_path, .{
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

pub fn formatOAuthClientConfigError(
    allocator: std.mem.Allocator,
    env_map: *const std.process.Environ.Map,
    provider_id: []const u8,
    err: anyerror,
) !?[]u8 {
    const handled = switch (err) {
        error.MissingOAuthConfigFile, error.InvalidOAuthConfigFile, error.MissingOAuthClientConfig, error.MissingOAuthClientId, error.MissingOAuthClientSecret => true,
        else => false,
    };
    if (!handled) return null;

    const provider = findSupportedProvider(provider_id) orelse return null;
    const oauth_path = try resolveOAuthConfigPath(allocator, env_map);
    defer allocator.free(oauth_path);
    const snippet = oauthConfigSnippet(provider_id);

    const reason = switch (err) {
        error.MissingOAuthConfigFile => "OAuth client credentials are not configured.",
        error.InvalidOAuthConfigFile => "The OAuth client config file is not valid JSON.",
        error.MissingOAuthClientConfig => "This provider is missing from the OAuth client config file.",
        error.MissingOAuthClientId => "The provider config is missing client_id.",
        error.MissingOAuthClientSecret => "The provider config is missing client_secret.",
        else => unreachable,
    };

    return try std.fmt.allocPrint(
        allocator,
        "{s} Create {s} with an entry for {s}, for example:\n{s}",
        .{ reason, oauth_path, provider.name, snippet },
    );
}

pub fn formatAuthenticationError(allocator: std.mem.Allocator, err: anyerror) !?[]u8 {
    const message = switch (err) {
        error.InvalidAuthorizationInput => "Paste the full redirect URL or authorization code from the browser callback.",
        error.MissingAuthorizationCode => "The callback URL is missing the `code` parameter. Paste the full redirect URL.",
        error.InvalidOAuthState => "The callback URL belongs to a different login attempt. Run /login again and paste the newest redirect URL.",
        error.MissingProjectId => "Enter a Google Cloud project ID after the redirect URL is accepted.",
        error.InvalidAuthResponse => "OAuth token exchange returned an unexpected response.",
        error.MissingAccessToken => "OAuth token exchange succeeded but did not return an access token.",
        error.MissingRefreshToken => "OAuth token exchange succeeded but did not return a refresh token.",
        error.HttpRequestFailed => "OAuth token exchange failed. Verify the client credentials and try /login again.",
        error.Timeout => "OAuth token exchange timed out. Try /login again.",
        error.ConnectionRefused, error.ConnectionReset, error.NetworkUnreachable, error.UnknownHost, error.TlsFailure => "Could not reach the OAuth provider during token exchange.",
        else => return null,
    };
    return try allocator.dupe(u8, message);
}

fn loadOAuthClientCredentials(
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    provider_id: []const u8,
    require_client_secret: bool,
) !OAuthClientCredentials {
    const oauth_path = try resolveOAuthConfigPath(allocator, env_map);
    defer allocator.free(oauth_path);

    const content = std.Io.Dir.readFileAlloc(.cwd(), io, oauth_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.MissingOAuthConfigFile,
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return error.InvalidOAuthConfigFile;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOAuthConfigFile;

    const provider_object = findOAuthProviderObject(parsed.value.object, provider_id) orelse return error.MissingOAuthClientConfig;
    const configured_client_id = getObjectStringAny(provider_object, &.{ "client_id", "clientId" });
    const client_secret = getObjectStringAny(provider_object, &.{ "client_secret", "clientSecret" });
    if (require_client_secret and client_secret == null) return error.MissingOAuthClientSecret;

    return .{
        .client_id = try resolveOAuthClientId(allocator, provider_id, configured_client_id),
        .client_secret = if (client_secret) |value| try allocator.dupe(u8, value) else null,
    };
}

fn resolveOAuthClientId(
    allocator: std.mem.Allocator,
    provider_id: []const u8,
    configured_client_id: ?[]const u8,
) ![]u8 {
    const trimmed = std.mem.trim(u8, configured_client_id orelse "", &std.ascii.whitespace);
    if (trimmed.len == 0) return error.MissingOAuthClientId;

    if (std.mem.eql(u8, provider_id, "anthropic") and !isValidAnthropicClientId(trimmed)) {
        return allocator.dupe(u8, DEFAULT_ANTHROPIC_CLIENT_ID);
    }

    return allocator.dupe(u8, trimmed);
}

fn isValidAnthropicClientId(value: []const u8) bool {
    const uuid = if (std.mem.startsWith(u8, value, "urn:uuid:")) value["urn:uuid:".len..] else value;
    if (uuid.len != 36) return false;

    for (uuid, 0..) |char, index| {
        switch (index) {
            8, 13, 18, 23 => {
                if (char != '-') return false;
            },
            else => {
                if (!std.ascii.isHex(char)) return false;
            },
        }
    }

    return true;
}

fn resolveOAuthConfigPath(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    const agent_dir = try resolveAgentDir(allocator, env_map);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &[_][]const u8{ agent_dir, OAUTH_CONFIG_FILE_NAME });
}

fn resolveAgentDir(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map) ![]u8 {
    if (env_map.get("PI_CODING_AGENT_DIR")) |value| {
        return expandLeadingHome(allocator, env_map, value);
    }

    const base_dir = if (env_map.get("PI_CONFIG_DIR")) |value|
        try expandLeadingHome(allocator, env_map, value)
    else if (env_map.get("HOME")) |home|
        try std.fs.path.join(allocator, &[_][]const u8{ home, ".pi" })
    else
        try allocator.dupe(u8, ".pi");
    defer allocator.free(base_dir);

    return std.fs.path.join(allocator, &[_][]const u8{ base_dir, "agent" });
}

fn expandLeadingHome(allocator: std.mem.Allocator, env_map: *const std.process.Environ.Map, value: []const u8) ![]u8 {
    const home = env_map.get("HOME") orelse return allocator.dupe(u8, value);
    if (std.mem.eql(u8, value, "~")) return allocator.dupe(u8, home);
    if (std.mem.startsWith(u8, value, "~/")) return std.fs.path.join(allocator, &[_][]const u8{ home, value[2..] });
    return allocator.dupe(u8, value);
}

fn findOAuthProviderObject(root: std.json.ObjectMap, provider_id: []const u8) ?std.json.ObjectMap {
    if (root.get(provider_id)) |value| {
        if (value == .object) return value.object;
    }

    if (std.mem.eql(u8, provider_id, "google-gemini-cli")) {
        if (root.get("google")) |value| {
            if (value == .object) return value.object;
        }
    }
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        if (root.get("github")) |value| {
            if (value == .object) return value.object;
        }
    }

    return null;
}

fn oauthConfigSnippet(provider_id: []const u8) []const u8 {
    if (std.mem.eql(u8, provider_id, "google-gemini-cli")) {
        return
        \\{
        \\  "google-gemini-cli": {
        \\    "client_id": "YOUR_GOOGLE_CLIENT_ID",
        \\    "client_secret": "YOUR_GOOGLE_CLIENT_SECRET"
        \\  }
        \\}
        ;
    }
    if (std.mem.eql(u8, provider_id, "github-copilot")) {
        return
        \\{
        \\  "github-copilot": {
        \\    "client_id": "YOUR_GITHUB_CLIENT_ID"
        \\  }
        \\}
        ;
    }
    return
    \\{
    \\  "anthropic": {
    \\    "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    \\  }
    \\}
    ;
}

fn exchangeAnthropicAuthorizationCode(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *const BrowserLoginSession,
    input: []const u8,
) !OAuthCredential {
    const parsed = try parseAuthorizationInput(allocator, input);
    defer parsed.deinit(allocator);

    if (parsed.state) |state| {
        if (!std.mem.eql(u8, state, session.verifier)) return error.InvalidOAuthState;
    }

    const code = parsed.code orelse return error.MissingAuthorizationCode;

    var payload = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer {
        const cleanup_value: std.json.Value = .{ .object = payload };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    try payload.put(allocator, try allocator.dupe(u8, "grant_type"), .{ .string = try allocator.dupe(u8, "authorization_code") });
    try payload.put(allocator, try allocator.dupe(u8, "client_id"), .{ .string = try allocator.dupe(u8, session.oauth_client.client_id) });
    try payload.put(allocator, try allocator.dupe(u8, "code"), .{ .string = try allocator.dupe(u8, code) });
    try payload.put(allocator, try allocator.dupe(u8, "state"), .{ .string = try allocator.dupe(u8, session.verifier) });
    try payload.put(allocator, try allocator.dupe(u8, "redirect_uri"), .{ .string = try allocator.dupe(u8, ANTHROPIC_REDIRECT_URI) });
    try payload.put(allocator, try allocator.dupe(u8, "code_verifier"), .{ .string = try allocator.dupe(u8, session.verifier) });

    const payload_value: std.json.Value = .{ .object = payload };
    const json_body = try std.json.Stringify.valueAlloc(allocator, payload_value, .{});
    defer allocator.free(json_body);

    const response_body = try postJson(allocator, io, ANTHROPIC_TOKEN_URL, json_body, null);
    defer allocator.free(response_body);

    var parsed_response = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed_response.deinit();
    if (parsed_response.value != .object) return error.InvalidAuthResponse;

    const access_token = getObjectString(parsed_response.value.object, "access_token") orelse return error.MissingAccessToken;
    const refresh_token = getObjectString(parsed_response.value.object, "refresh_token") orelse return error.MissingRefreshToken;
    const expires_in = getObjectInt(parsed_response.value.object, "expires_in") orelse return error.InvalidAuthResponse;

    return .{
        .access = try allocator.dupe(u8, access_token),
        .refresh = try allocator.dupe(u8, refresh_token),
        .expires = computeExpiresAtMs(expires_in, io),
    };
}

fn refreshGitHubCopilotToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    github_access_token: []const u8,
) !OAuthCredential {
    const authorization = try std.fmt.allocPrint(allocator, "Bearer {s}", .{github_access_token});
    defer allocator.free(authorization);

    var headers = try initHeaders(allocator, &.{
        .{ .name = "Accept", .value = "application/json" },
        .{ .name = "Authorization", .value = authorization },
        .{ .name = "User-Agent", .value = COPILOT_USER_AGENT },
        .{ .name = "Editor-Version", .value = COPILOT_EDITOR_VERSION },
        .{ .name = "Editor-Plugin-Version", .value = COPILOT_PLUGIN_VERSION },
        .{ .name = "Copilot-Integration-Id", .value = COPILOT_INTEGRATION_ID },
    });
    defer deinitHeaders(allocator, &headers);

    const response_body = try getRequest(allocator, io, GITHUB_COPILOT_TOKEN_URL, &headers);
    defer allocator.free(response_body);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response_body, .{}) catch return error.InvalidAuthResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthResponse;

    const token = getObjectString(parsed.value.object, "token") orelse return error.MissingAccessToken;
    const expires_at = getObjectInt(parsed.value.object, "expires_at") orelse return error.InvalidAuthResponse;

    return .{
        .access = try allocator.dupe(u8, token),
        .refresh = try allocator.dupe(u8, github_access_token),
        .expires = expires_at * std.time.ms_per_s - 5 * std.time.ms_per_min,
    };
}

fn parseAuthorizationInput(allocator: std.mem.Allocator, input: []const u8) !AuthorizationInput {
    const trimmed = std.mem.trim(u8, input, " \t\r\n\"'");
    if (trimmed.len == 0) return error.InvalidAuthorizationInput;

    if (std.mem.indexOfScalar(u8, trimmed, '?')) |query_index| {
        return extractAuthorizationFromQuery(allocator, trimmed[query_index + 1 ..]);
    }

    if (std.mem.indexOf(u8, trimmed, "code=")) |_| {
        return extractAuthorizationFromQuery(allocator, trimmed);
    }

    return .{ .code = try allocator.dupe(u8, trimmed) };
}

fn extractAuthorizationFromQuery(allocator: std.mem.Allocator, query: ?[]const u8) !AuthorizationInput {
    const query_text = query orelse return error.InvalidAuthorizationInput;
    const fragment_trimmed = if (std.mem.indexOfScalar(u8, query_text, '#')) |fragment_index|
        query_text[0..fragment_index]
    else
        query_text;
    var result = AuthorizationInput{};
    errdefer result.deinit(allocator);

    var iterator = std.mem.splitScalar(u8, fragment_trimmed, '&');
    while (iterator.next()) |part| {
        const equals_index = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        const name = part[0..equals_index];
        const value = try percentDecodeAlloc(allocator, part[equals_index + 1 ..]);
        errdefer allocator.free(value);
        if (std.mem.eql(u8, name, "code")) {
            if (result.code) |existing| allocator.free(existing);
            result.code = value;
        } else if (std.mem.eql(u8, name, "state")) {
            if (result.state) |existing| allocator.free(existing);
            result.state = value;
        } else {
            allocator.free(value);
        }
    }

    if (result.code == null) return error.MissingAuthorizationCode;
    return result;
}

fn getRequest(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: ?*std.StringHashMap([]const u8),
) ![]u8 {
    var client = try ai.http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const response = client.request(.{
        .method = .GET,
        .url = url,
        .headers = if (headers) |value| value.* else null,
    }) catch |err| return mapHttpError(err);
    defer response.deinit();
    return try allocator.dupe(u8, response.body);
}

fn postJson(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body: []const u8,
    extra_headers: ?*std.StringHashMap([]const u8),
) ![]u8 {
    var headers = try initHeaders(allocator, &.{
        .{ .name = "Content-Type", .value = "application/json" },
        .{ .name = "Accept", .value = "application/json" },
    });
    defer deinitHeaders(allocator, &headers);
    if (extra_headers) |value| try cloneHeadersInto(allocator, &headers, value);

    var client = try ai.http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const response = client.request(.{
        .method = .POST,
        .url = url,
        .headers = headers,
        .body = body,
    }) catch |err| return mapHttpError(err);
    defer response.deinit();

    return try allocator.dupe(u8, response.body);
}

fn postForm(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    body: []const u8,
    extra_headers: ?*std.StringHashMap([]const u8),
) ![]u8 {
    var headers = try initHeaders(allocator, &.{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Accept", .value = "application/json" },
    });
    defer deinitHeaders(allocator, &headers);
    if (extra_headers) |value| try cloneHeadersInto(allocator, &headers, value);

    var client = try ai.http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const response = client.request(.{
        .method = .POST,
        .url = url,
        .headers = headers,
        .body = body,
    }) catch |err| return mapHttpError(err);
    defer response.deinit();

    return try allocator.dupe(u8, response.body);
}

fn initHeaders(allocator: std.mem.Allocator, pairs: []const struct { name: []const u8, value: []const u8 }) !std.StringHashMap([]const u8) {
    var headers = std.StringHashMap([]const u8).init(allocator);
    errdefer deinitHeaders(allocator, &headers);
    for (pairs) |pair| {
        try headers.put(try allocator.dupe(u8, pair.name), try allocator.dupe(u8, pair.value));
    }
    return headers;
}

fn cloneHeadersInto(
    allocator: std.mem.Allocator,
    dest: *std.StringHashMap([]const u8),
    source: *std.StringHashMap([]const u8),
) !void {
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        try dest.put(try allocator.dupe(u8, entry.key_ptr.*), try allocator.dupe(u8, entry.value_ptr.*));
    }
}

fn deinitHeaders(allocator: std.mem.Allocator, headers: *std.StringHashMap([]const u8)) void {
    var iterator = headers.iterator();
    while (iterator.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    headers.deinit();
}

fn buildFormBody(allocator: std.mem.Allocator, fields: []const EncodedField) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);

    for (fields, 0..) |field, index| {
        if (index > 0) try list.append(allocator, '&');
        const encoded_name = try formEncode(allocator, field.name);
        defer allocator.free(encoded_name);
        const encoded_value = try formEncode(allocator, field.value);
        defer allocator.free(encoded_value);
        try list.appendSlice(allocator, encoded_name);
        try list.append(allocator, '=');
        try list.appendSlice(allocator, encoded_value);
    }

    return try list.toOwnedSlice(allocator);
}

fn generatePkceVerifier(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var bytes: [32]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(@intCast(currentTimeMs(io)));
    prng.random().bytes(&bytes);
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &bytes);
    return encoded;
}

fn generatePkceChallenge(allocator: std.mem.Allocator, verifier: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(digest.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, &digest);
    return encoded;
}

fn computeExpiresAtMs(expires_in_seconds: i64, io: std.Io) i64 {
    return currentTimeMs(io) + expires_in_seconds * std.time.ms_per_s - 5 * std.time.ms_per_min;
}

fn currentTimeMs(io: std.Io) i64 {
    return @intCast(@divFloor(std.Io.Clock.now(.awake, io).nanoseconds, std.time.ns_per_ms));
}

fn buildGoogleStoredApiKey(allocator: std.mem.Allocator, access: []const u8, project_id: []const u8) ![]u8 {
    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer {
        const cleanup_value: std.json.Value = .{ .object = object };
        common.deinitJsonValue(allocator, cleanup_value);
    }

    try object.put(allocator, try allocator.dupe(u8, "token"), .{ .string = try allocator.dupe(u8, access) });
    try object.put(allocator, try allocator.dupe(u8, "projectId"), .{ .string = try allocator.dupe(u8, project_id) });
    const value: std.json.Value = .{ .object = object };
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn getObjectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    if (value != .string) return null;
    return value.string;
}

fn getObjectStringAny(object: std.json.ObjectMap, keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (getObjectString(object, key)) |value| return value;
    }
    return null;
}

fn getObjectInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => value.integer,
        else => null,
    };
}

fn percentDecodeAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var index: usize = 0;
    while (index < encoded.len) : (index += 1) {
        const char = encoded[index];
        if (char == '%' and index + 2 < encoded.len) {
            const hi = try parseHexNibble(encoded[index + 1]);
            const lo = try parseHexNibble(encoded[index + 2]);
            try output.append(allocator, (hi << 4) | lo);
            index += 2;
            continue;
        }
        if (char == '+') {
            try output.append(allocator, ' ');
            continue;
        }
        try output.append(allocator, char);
    }

    return try output.toOwnedSlice(allocator);
}

fn parseHexNibble(char: u8) !u8 {
    return switch (char) {
        '0'...'9' => char - '0',
        'a'...'f' => char - 'a' + 10,
        'A'...'F' => char - 'A' + 10,
        else => error.InvalidAuthorizationInput,
    };
}

fn formEncode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var list = std.ArrayList(u8).empty;
    defer list.deinit(allocator);
    for (raw) |char| {
        if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.' or char == '~') {
            try list.append(allocator, char);
        } else {
            try list.append(allocator, '%');
            try list.append(allocator, std.fmt.digitToChar(@intCast(char >> 4), .upper));
            try list.append(allocator, std.fmt.digitToChar(@intCast(char & 0x0f), .upper));
        }
    }
    return try list.toOwnedSlice(allocator);
}

fn mapHttpError(err: anyerror) anyerror {
    return switch (err) {
        ai.http_client.HttpError.ConnectionRefused => error.ConnectionRefused,
        ai.http_client.HttpError.ConnectionReset => error.ConnectionReset,
        ai.http_client.HttpError.Timeout => error.Timeout,
        ai.http_client.HttpError.RequestAborted => error.RequestAborted,
        ai.http_client.HttpError.InvalidUrl => error.InvalidUrl,
        ai.http_client.HttpError.UnknownHost => error.UnknownHost,
        ai.http_client.HttpError.TlsFailure => error.TlsFailure,
        ai.http_client.HttpError.TooManyRedirects => error.TooManyRedirects,
        ai.http_client.HttpError.NetworkUnreachable => error.NetworkUnreachable,
        ai.http_client.HttpError.ServerError => error.HttpRequestFailed,
        ai.http_client.HttpError.ClientError => error.HttpRequestFailed,
        ai.http_client.HttpError.UnexpectedRedirect => error.HttpRequestFailed,
        else => error.HttpRequestFailed,
    };
}

test "startAnthropicBrowserLogin builds a Claude OAuth URL" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const oauth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "oauth.json" });
    defer allocator.free(oauth_path);
    try common.writeFileAbsolute(
        std.testing.io,
        oauth_path,
        \\{
        \\  "anthropic": {
        \\    "client_id": "anthropic-client-id"
        \\  }
        \\}
    ,
        true,
    );

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var session = try startAnthropicBrowserLogin(allocator, std.testing.io, &env_map);
    defer session.deinit(allocator);

    try std.testing.expectEqual(BrowserLoginKind.anthropic, session.kind);
    try std.testing.expect(std.mem.startsWith(u8, session.auth_url, ANTHROPIC_AUTHORIZE_URL));
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "code_challenge=") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.auth_url, "redirect_uri=http%3A%2F%2Flocalhost%3A53692%2Fcallback") != null);
}

test "loadOAuthClientCredentials falls back to public Anthropic client id for invalid configured values" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);
    const oauth_path = try std.fs.path.join(allocator, &[_][]const u8{ agent_dir, "oauth.json" });
    defer allocator.free(oauth_path);
    try common.writeFileAbsolute(
        std.testing.io,
        oauth_path,
        \\{
        \\  "anthropic": {
        \\    "client_id": "not-a-valid-uuid"
        \\  }
        \\}
    ,
        true,
    );

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    var credentials = try loadOAuthClientCredentials(allocator, std.testing.io, &env_map, "anthropic", false);
    defer credentials.deinit(allocator);

    try std.testing.expectEqualStrings(DEFAULT_ANTHROPIC_CLIENT_ID, credentials.client_id);
}

test "parseAuthorizationInput accepts full callback URLs with fragments and quotes" {
    const allocator = std.testing.allocator;

    var parsed = try parseAuthorizationInput(
        allocator,
        "\"http://localhost:53692/callback?code=4ujivk7vnGi64Hqicga0DG96C9YglzNJFgfYjrLHndQRK8gn&state=9geviroXK7Sa3j6MjojixMzGOWHRCvszOAKSbWCulSg#_=_\"",
    );
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("4ujivk7vnGi64Hqicga0DG96C9YglzNJFgfYjrLHndQRK8gn", parsed.code.?);
    try std.testing.expectEqualStrings("9geviroXK7Sa3j6MjojixMzGOWHRCvszOAKSbWCulSg", parsed.state.?);
}

test "formatOAuthClientConfigError references oauth.json guidance" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const agent_dir = try makeAuthTestPath(allocator, tmp, "agent-home");
    defer allocator.free(agent_dir);

    var env_map = std.process.Environ.Map.init(allocator);
    defer env_map.deinit();
    try env_map.put("PI_CODING_AGENT_DIR", agent_dir);

    const message = (try formatOAuthClientConfigError(
        allocator,
        &env_map,
        "google-gemini-cli",
        error.MissingOAuthClientSecret,
    )).?;
    defer allocator.free(message);

    try std.testing.expect(std.mem.indexOf(u8, message, "oauth.json") != null);
    try std.testing.expect(std.mem.indexOf(u8, message, "\"client_secret\"") != null);
}

test "buildApiKeyFromStoredEntry encodes google oauth credentials as provider json" {
    const allocator = std.testing.allocator;

    var object = try std.json.ObjectMap.init(allocator, &.{}, &.{});
    defer {
        const cleanup_value: std.json.Value = .{ .object = object };
        common.deinitJsonValue(allocator, cleanup_value);
    }
    try object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "oauth") });
    try object.put(allocator, try allocator.dupe(u8, "access"), .{ .string = try allocator.dupe(u8, "access-token") });
    try object.put(allocator, try allocator.dupe(u8, "projectId"), .{ .string = try allocator.dupe(u8, "project-123") });

    const api_key = (try buildApiKeyFromStoredEntry(allocator, "google-gemini-cli", object)).?;
    defer allocator.free(api_key);

    try std.testing.expect(std.mem.indexOf(u8, api_key, "\"token\":\"access-token\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, api_key, "\"projectId\":\"project-123\"") != null);
}

test "upsertStoredCredential and listStoredProviders persist oauth state" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd = try std.process.currentPathAlloc(std.testing.io, allocator);
    defer allocator.free(cwd);
    const auth_path = try std.fs.path.resolve(allocator, &[_][]const u8{
        cwd,
        ".zig-cache",
        "tmp",
        &tmp.sub_path,
        "agent",
        "auth.json",
    });
    defer allocator.free(auth_path);

    var credential = StoredCredential{
        .oauth = .{
            .access = try allocator.dupe(u8, "access-token"),
            .refresh = try allocator.dupe(u8, "refresh-token"),
            .expires = 1234,
            .project_id = try allocator.dupe(u8, "project-1"),
        },
    };
    defer credential.deinit(allocator);

    try upsertStoredCredential(allocator, std.testing.io, auth_path, "google-gemini-cli", &credential);
    const providers = try listStoredProviders(allocator, std.testing.io, auth_path);
    defer allocator.free(providers);

    try std.testing.expectEqual(@as(usize, 1), providers.len);
    try std.testing.expectEqualStrings("google-gemini-cli", providers[0].id);

    const stat = try std.Io.Dir.statFile(.cwd(), std.testing.io, auth_path, .{});
    if (@hasDecl(@TypeOf(stat.permissions), "toMode")) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
}

fn makeAuthTestPath(allocator: std.mem.Allocator, tmp: anytype, name: []const u8) ![]u8 {
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
