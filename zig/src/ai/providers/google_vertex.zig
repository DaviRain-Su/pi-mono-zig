const std = @import("std");
const types = @import("../types.zig");
const http_client = @import("../http_client.zig");
const json_parse = @import("../json_parse.zig");
const env_api_keys = @import("../env_api_keys.zig");
const event_stream = @import("../event_stream.zig");
const provider_error = @import("../shared/provider_error.zig");
const asn1 = std.crypto.codecs.asn1;

const DEFAULT_SCOPE = "https://www.googleapis.com/auth/cloud-platform";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";
const DEFAULT_VERTEX_ROOT = "https://{location}-aiplatform.googleapis.com/v1";
const DEFAULT_TOKEN_LIFETIME_SECS: i64 = 3600;
const AUTHENTICATED_SENTINEL = "<authenticated>";
const SHA256_DIGEST_INFO_PREFIX = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65,
    0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
};

const VertexProviderError = error{
    MissingGoogleVertexCredentials,
    MissingVertexProject,
    MissingVertexLocation,
    InvalidGoogleCredentials,
    UnsupportedGoogleCredentialsType,
    MissingGoogleRefreshToken,
    MissingGoogleClientId,
    MissingGoogleClientSecret,
    MissingGoogleClientEmail,
    MissingGooglePrivateKey,
    MissingGoogleTokenUri,
    InvalidPrivateKeyPem,
    InvalidPrivateKeyDer,
    InvalidTokenResponse,
    MissingAccessToken,
    OAuthTokenRequestFailed,
};

const OwnedHeader = struct {
    name: []const u8,
    value: []const u8,

    fn deinit(self: OwnedHeader, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

const AuthorizedUserCredentials = struct {
    client_id: []const u8,
    client_secret: []const u8,
    refresh_token: []const u8,
    token_uri: []const u8,

    fn deinit(self: AuthorizedUserCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.client_id);
        allocator.free(self.client_secret);
        allocator.free(self.refresh_token);
        allocator.free(self.token_uri);
    }
};

const ServiceAccountCredentials = struct {
    client_email: []const u8,
    private_key_pem: []const u8,
    token_uri: []const u8,
    project_id: ?[]const u8 = null,

    fn deinit(self: ServiceAccountCredentials, allocator: std.mem.Allocator) void {
        allocator.free(self.client_email);
        allocator.free(self.private_key_pem);
        allocator.free(self.token_uri);
        if (self.project_id) |project_id| allocator.free(project_id);
    }
};

const VertexAuth = union(enum) {
    api_key: []const u8,
    bearer_token: []const u8,
    authorized_user: AuthorizedUserCredentials,
    service_account: ServiceAccountCredentials,

    fn deinit(self: VertexAuth, allocator: std.mem.Allocator) void {
        switch (self) {
            .api_key => |value| allocator.free(value),
            .bearer_token => |value| allocator.free(value),
            .authorized_user => |value| value.deinit(allocator),
            .service_account => |value| value.deinit(allocator),
        }
    }
};

const CurrentBlock = union(enum) {
    text: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
    thinking: struct {
        text: std.ArrayList(u8),
        signature: ?[]const u8,
    },
};

pub const GoogleVertexProvider = struct {
    pub const api = "google-vertex";

    pub fn stream(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
        errdefer stream_instance.deinit();

        const auth_header = resolveVertexAuthHeader(allocator, io, options) catch |err| {
            try emitAuthError(allocator, &stream_instance, model, authErrorMessage(err));
            return stream_instance;
        };
        defer auth_header.deinit(allocator);

        var payload = try buildRequestPayload(allocator, model, context, options);
        defer freeJsonValue(allocator, payload);

        if (options) |stream_options| {
            if (stream_options.on_payload) |callback| {
                if (try callback(allocator, payload, model)) |replacement| {
                    freeJsonValue(allocator, payload);
                    payload = replacement;
                }
            }
        }

        const json_body = try std.json.Stringify.valueAlloc(allocator, payload, .{});
        defer allocator.free(json_body);

        const url = try buildRequestUrl(allocator, model);
        defer allocator.free(url);

        var headers = std.StringHashMap([]const u8).init(allocator);
        defer headers.deinit();
        try putOwnedHeader(allocator, &headers, "Content-Type", "application/json");
        try putOwnedHeader(allocator, &headers, "Accept", "text/event-stream");
        try headers.put(try allocator.dupe(u8, auth_header.name), try allocator.dupe(u8, auth_header.value));
        try mergeHeaders(allocator, &headers, model.headers);
        if (options) |stream_options| {
            try mergeHeaders(allocator, &headers, stream_options.headers);
        }

        var client = try http_client.HttpClient.init(allocator, io);
        defer client.deinit();

        var response = try client.requestStreaming(.{
            .method = .POST,
            .url = url,
            .headers = headers,
            .body = json_body,
            .aborted = if (options) |stream_options| stream_options.signal else null,
        });
        defer response.deinit();

        if (options) |stream_options| {
            if (stream_options.on_response) |callback| {
                if (response.response_headers) |response_headers| {
                    try callback(response.status, response_headers, model);
                } else {
                    var response_headers = std.StringHashMap([]const u8).init(allocator);
                    defer response_headers.deinit();
                    try callback(response.status, response_headers, model);
                }
            }
        }

        if (response.status != 200) {
            const response_body = try response.readAllBounded(allocator, provider_error.MAX_PROVIDER_ERROR_BODY_READ_BYTES);
            defer allocator.free(response_body);
            try provider_error.pushHttpStatusError(allocator, &stream_instance, model, response.status, response_body);
            return stream_instance;
        }

        try parseSseStreamLines(allocator, &stream_instance, &response, model, options);
        return stream_instance;
    }

    pub fn streamSimple(
        allocator: std.mem.Allocator,
        io: std.Io,
        model: types.Model,
        context: types.Context,
        options: ?types.StreamOptions,
    ) !event_stream.AssistantMessageEventStream {
        return stream(allocator, io, model, context, options);
    }
};

pub fn buildRequestPayload(
    allocator: std.mem.Allocator,
    model: types.Model,
    context: types.Context,
    options: ?types.StreamOptions,
) !std.json.Value {
    var payload = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer payload.deinit(allocator);

    try payload.put(allocator, try allocator.dupe(u8, "contents"), try buildContentsValue(allocator, model, context.messages));

    if (context.system_prompt) |system_prompt| {
        try payload.put(allocator, try allocator.dupe(u8, "systemInstruction"), try buildSystemInstructionValue(allocator, system_prompt));
    }

    try payload.put(allocator, try allocator.dupe(u8, "generationConfig"), try buildGenerationConfigValue(allocator, model, options));

    if (context.tools) |tools| {
        if (tools.len > 0) {
            try payload.put(allocator, try allocator.dupe(u8, "tools"), try buildToolsValue(allocator, tools));
            if (options) |stream_options| {
                if (stream_options.google_tool_choice) |tool_choice| {
                    try payload.put(allocator, try allocator.dupe(u8, "toolConfig"), try buildToolConfigValue(allocator, tool_choice));
                }
            }
        }
    }

    return .{ .object = payload };
}

fn buildRequestUrl(allocator: std.mem.Allocator, model: types.Model) ![]const u8 {
    const trimmed_base = std.mem.trim(u8, model.base_url, " \t\r\n");
    if (trimmed_base.len == 0) {
        const project = try resolveVertexProject(allocator, null);
        defer allocator.free(project);
        const location = try resolveVertexLocation(allocator, null);
        defer allocator.free(location);
        return try buildPublisherUrlFromRoot(allocator, DEFAULT_VERTEX_ROOT, project, location, model.id);
    }

    const resolved_base = try resolveLocationPlaceholder(allocator, trimmed_base);
    defer allocator.free(resolved_base);

    const base = trimTrailingSlash(resolved_base);
    if (std.mem.indexOf(u8, base, "/publishers/") != null) {
        if (std.mem.endsWith(u8, base, "/models")) {
            return try std.fmt.allocPrint(allocator, "{s}/{s}:streamGenerateContent?alt=sse", .{ base, model.id });
        }
        return try std.fmt.allocPrint(allocator, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ base, model.id });
    }

    const project = try resolveVertexProject(allocator, base);
    defer allocator.free(project);
    const location = try resolveVertexLocation(allocator, base);
    defer allocator.free(location);
    return try buildPublisherUrlFromRoot(allocator, base, project, location, model.id);
}

fn buildPublisherUrlFromRoot(
    allocator: std.mem.Allocator,
    root: []const u8,
    project: []const u8,
    location: []const u8,
    model_id: []const u8,
) ![]const u8 {
    const normalized_root = trimTrailingSlash(root);
    const with_location = if (std.mem.indexOf(u8, normalized_root, "{location}") != null)
        try std.mem.replaceOwned(u8, allocator, normalized_root, "{location}", location)
    else
        try allocator.dupe(u8, normalized_root);
    defer allocator.free(with_location);

    const effective_root = if (pathHasApiVersion(with_location))
        with_location
    else
        try std.fmt.allocPrint(allocator, "{s}/v1", .{with_location});
    defer if (effective_root.ptr != with_location.ptr) allocator.free(effective_root);

    return try std.fmt.allocPrint(
        allocator,
        "{s}/projects/{s}/locations/{s}/publishers/google/models/{s}:streamGenerateContent?alt=sse",
        .{ trimTrailingSlash(effective_root), project, location, model_id },
    );
}

fn resolveVertexAuthHeader(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: ?types.StreamOptions,
) !OwnedHeader {
    const provided = if (options) |stream_options| stream_options.api_key else null;

    var env_auth: ?[]u8 = null;
    defer if (env_auth) |value| allocator.free(value);
    if (provided == null) {
        env_auth = try env_api_keys.getEnvApiKey(allocator, "google-vertex");
    }

    const adc_json: ?[]u8 = try loadApplicationDefaultCredentials(allocator, io);
    defer if (adc_json) |value| allocator.free(value);

    const auth = try resolveCredentialsFromInputs(allocator, io, provided, env_auth, adc_json);
    defer auth.deinit(allocator);

    return switch (auth) {
        .api_key => |api_key| .{
            .name = try allocator.dupe(u8, "x-goog-api-key"),
            .value = try allocator.dupe(u8, api_key),
        },
        .bearer_token => |token| .{
            .name = try allocator.dupe(u8, "Authorization"),
            .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}),
        },
        .authorized_user => |credentials| blk: {
            const token = try fetchAuthorizedUserAccessToken(allocator, io, credentials);
            defer allocator.free(token);
            break :blk .{
                .name = try allocator.dupe(u8, "Authorization"),
                .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}),
            };
        },
        .service_account => |credentials| blk: {
            const token = try fetchServiceAccountAccessToken(allocator, io, credentials);
            defer allocator.free(token);
            break :blk .{
                .name = try allocator.dupe(u8, "Authorization"),
                .value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token}),
            };
        },
    };
}

fn resolveCredentialsFromInputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    provided_auth: ?[]const u8,
    env_auth: ?[]const u8,
    adc_json: ?[]const u8,
) !VertexAuth {
    if (provided_auth) |value| {
        if (try parseProvidedCredentialSpec(allocator, io, value, adc_json)) |auth| return auth;
    }

    if (env_auth) |value| {
        if (try parseProvidedCredentialSpec(allocator, io, value, adc_json)) |auth| return auth;
    }

    if (adc_json) |json| return try parseCredentialJson(allocator, json);
    return VertexProviderError.MissingGoogleVertexCredentials;
}

fn parseProvidedCredentialSpec(
    allocator: std.mem.Allocator,
    io: std.Io,
    raw_value: []const u8,
    adc_json: ?[]const u8,
) !?VertexAuth {
    const trimmed = std.mem.trim(u8, raw_value, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, AUTHENTICATED_SENTINEL)) {
        if (adc_json) |json| return try parseCredentialJson(allocator, json);
        return VertexProviderError.MissingGoogleVertexCredentials;
    }
    if (std.mem.startsWith(u8, trimmed, "Bearer ")) {
        return .{ .bearer_token = try allocator.dupe(u8, std.mem.trim(u8, trimmed["Bearer ".len..], " \t\r\n")) };
    }
    if (trimmed[0] == '{') return try parseCredentialJson(allocator, trimmed);
    if (try maybeReadCredentialFile(allocator, io, trimmed)) |contents| {
        defer allocator.free(contents);
        return try parseCredentialJson(allocator, contents);
    }
    return .{ .api_key = try allocator.dupe(u8, trimmed) };
}

fn parseCredentialJson(allocator: std.mem.Allocator, json_text: []const u8) !VertexAuth {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return VertexProviderError.InvalidGoogleCredentials;
    defer parsed.deinit();

    const value = parsed.value;
    if (value != .object) return VertexProviderError.InvalidGoogleCredentials;

    const type_value = if (value.object.get("type")) |field|
        if (field == .string) field.string else null
    else
        null;

    if (std.mem.eql(u8, type_value orelse "", "authorized_user") or
        (value.object.get("refresh_token") != null and value.object.get("client_id") != null))
    {
        return .{ .authorized_user = .{
            .client_id = try duplicateRequiredJsonString(allocator, value, "client_id", VertexProviderError.MissingGoogleClientId),
            .client_secret = try duplicateRequiredJsonString(allocator, value, "client_secret", VertexProviderError.MissingGoogleClientSecret),
            .refresh_token = try duplicateRequiredJsonString(allocator, value, "refresh_token", VertexProviderError.MissingGoogleRefreshToken),
            .token_uri = try duplicateOptionalJsonStringOrDefault(allocator, value, "token_uri", DEFAULT_TOKEN_URI),
        } };
    }

    if (std.mem.eql(u8, type_value orelse "", "service_account") or
        (value.object.get("client_email") != null and value.object.get("private_key") != null))
    {
        return .{ .service_account = .{
            .client_email = try duplicateRequiredJsonString(allocator, value, "client_email", VertexProviderError.MissingGoogleClientEmail),
            .private_key_pem = try duplicateRequiredJsonString(allocator, value, "private_key", VertexProviderError.MissingGooglePrivateKey),
            .token_uri = try duplicateOptionalJsonStringOrDefault(allocator, value, "token_uri", DEFAULT_TOKEN_URI),
            .project_id = if (value.object.get("project_id")) |project_id|
                if (project_id == .string and project_id.string.len > 0) try allocator.dupe(u8, project_id.string) else null
            else
                null,
        } };
    }

    return VertexProviderError.UnsupportedGoogleCredentialsType;
}

fn duplicateRequiredJsonString(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
    comptime err: anytype,
) ![]const u8 {
    const field = value.object.get(key) orelse return err;
    if (field != .string or std.mem.trim(u8, field.string, " \t\r\n").len == 0) return err;
    return try allocator.dupe(u8, field.string);
}

fn duplicateOptionalJsonStringOrDefault(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    key: []const u8,
    default_value: []const u8,
) ![]const u8 {
    if (value.object.get(key)) |field| {
        if (field == .string and field.string.len > 0) return try allocator.dupe(u8, field.string);
    }
    return try allocator.dupe(u8, default_value);
}

fn fetchAuthorizedUserAccessToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    credentials: AuthorizedUserCredentials,
) ![]const u8 {
    const body = try buildAuthorizedUserTokenRequestBody(allocator, credentials);
    defer allocator.free(body);
    return try fetchOAuthAccessToken(allocator, io, credentials.token_uri, body);
}

fn fetchServiceAccountAccessToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    credentials: ServiceAccountCredentials,
) ![]const u8 {
    var now: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&now, null);
    const issued_at: i64 = @intCast(now.sec);
    const assertion = try buildServiceAccountAssertion(allocator, credentials, issued_at);
    defer allocator.free(assertion);

    const body = try buildServiceAccountTokenRequestBody(allocator, assertion);
    defer allocator.free(body);
    return try fetchOAuthAccessToken(allocator, io, credentials.token_uri, body);
}

fn fetchOAuthAccessToken(
    allocator: std.mem.Allocator,
    io: std.Io,
    token_uri: []const u8,
    body: []const u8,
) ![]const u8 {
    var headers = std.StringHashMap([]const u8).init(allocator);
    defer headers.deinit();
    try putOwnedHeader(allocator, &headers, "Content-Type", "application/x-www-form-urlencoded");
    try putOwnedHeader(allocator, &headers, "Accept", "application/json");

    var client = try http_client.HttpClient.init(allocator, io);
    defer client.deinit();

    const response = try client.request(.{
        .method = .POST,
        .url = token_uri,
        .headers = headers,
        .body = body,
    });
    defer response.deinit();

    if (response.status != 200) return VertexProviderError.OAuthTokenRequestFailed;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response.body, .{}) catch return VertexProviderError.InvalidTokenResponse;
    defer parsed.deinit();
    const value = parsed.value;
    if (value != .object) return VertexProviderError.InvalidTokenResponse;
    const access_token = value.object.get("access_token") orelse return VertexProviderError.MissingAccessToken;
    if (access_token != .string or access_token.string.len == 0) return VertexProviderError.MissingAccessToken;
    return try allocator.dupe(u8, access_token.string);
}

fn buildAuthorizedUserTokenRequestBody(
    allocator: std.mem.Allocator,
    credentials: AuthorizedUserCredentials,
) ![]const u8 {
    const client_id = try formEncode(allocator, credentials.client_id);
    defer allocator.free(client_id);
    const client_secret = try formEncode(allocator, credentials.client_secret);
    defer allocator.free(client_secret);
    const refresh_token = try formEncode(allocator, credentials.refresh_token);
    defer allocator.free(refresh_token);

    return try std.fmt.allocPrint(
        allocator,
        "client_id={s}&client_secret={s}&refresh_token={s}&grant_type=refresh_token",
        .{ client_id, client_secret, refresh_token },
    );
}

fn buildServiceAccountTokenRequestBody(allocator: std.mem.Allocator, assertion: []const u8) ![]const u8 {
    const encoded_assertion = try formEncode(allocator, assertion);
    defer allocator.free(encoded_assertion);

    return try std.fmt.allocPrint(
        allocator,
        "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion={s}",
        .{encoded_assertion},
    );
}

fn buildServiceAccountAssertion(
    allocator: std.mem.Allocator,
    credentials: ServiceAccountCredentials,
    issued_at: i64,
) ![]const u8 {
    const header_json = "{\"alg\":\"RS256\",\"typ\":\"JWT\"}";
    const expires_at = issued_at + DEFAULT_TOKEN_LIFETIME_SECS;
    const payload_json = try std.fmt.allocPrint(
        allocator,
        "{{\"iss\":\"{s}\",\"sub\":\"{s}\",\"scope\":\"{s}\",\"aud\":\"{s}\",\"iat\":{d},\"exp\":{d}}}",
        .{ credentials.client_email, credentials.client_email, DEFAULT_SCOPE, credentials.token_uri, issued_at, expires_at },
    );
    defer allocator.free(payload_json);

    const encoded_header = try base64UrlEncodeAlloc(allocator, header_json);
    defer allocator.free(encoded_header);
    const encoded_payload = try base64UrlEncodeAlloc(allocator, payload_json);
    defer allocator.free(encoded_payload);

    const signing_input = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ encoded_header, encoded_payload });
    defer allocator.free(signing_input);

    const signature = try signRs256(allocator, credentials.private_key_pem, signing_input);
    defer allocator.free(signature);
    const encoded_signature = try base64UrlEncodeAlloc(allocator, signature);
    defer allocator.free(encoded_signature);

    return try std.fmt.allocPrint(allocator, "{s}.{s}", .{ signing_input, encoded_signature });
}

fn signRs256(
    allocator: std.mem.Allocator,
    private_key_pem: []const u8,
    message: []const u8,
) ![]u8 {
    const private_key_der = try decodePemPrivateKey(allocator, private_key_pem);
    defer allocator.free(private_key_der);

    const key = try parsePkcs8RsaPrivateKey(private_key_der);
    const modulus_len = key.modulus.len;
    if (modulus_len < SHA256_DIGEST_INFO_PREFIX.len + std.crypto.hash.sha2.Sha256.digest_length + 11) {
        return VertexProviderError.InvalidPrivateKeyDer;
    }

    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(message, &digest, .{});

    const encoded = try allocator.alloc(u8, modulus_len);
    defer allocator.free(encoded);
    try encodePkcs1DigestInfo(encoded, &digest);

    const Uint = std.crypto.ff.Uint(4096);
    const Modulus = std.crypto.ff.Modulus(4096);
    const Fe = Modulus.Fe;

    const modulus_uint = try Uint.fromBytes(key.modulus, .big);
    const modulus = try Modulus.fromUint(modulus_uint);
    const message_fe = try Fe.fromBytes(modulus, encoded, .big);
    const private_exponent = try Fe.fromBytes(modulus, key.private_exponent, .big);
    const signature_fe = try modulus.pow(message_fe, private_exponent);

    const signature = try allocator.alloc(u8, modulus_len);
    try signature_fe.toBytes(signature, .big);
    return signature;
}

fn encodePkcs1DigestInfo(buffer: []u8, digest: *const [std.crypto.hash.sha2.Sha256.digest_length]u8) !void {
    const digest_info_len = SHA256_DIGEST_INFO_PREFIX.len + digest.len;
    const padding_len = buffer.len - digest_info_len - 3;
    buffer[0] = 0x00;
    buffer[1] = 0x01;
    @memset(buffer[2 .. 2 + padding_len], 0xff);
    buffer[2 + padding_len] = 0x00;
    @memcpy(buffer[3 + padding_len .. 3 + padding_len + SHA256_DIGEST_INFO_PREFIX.len], &SHA256_DIGEST_INFO_PREFIX);
    @memcpy(buffer[3 + padding_len + SHA256_DIGEST_INFO_PREFIX.len ..], digest);
}

fn decodePemPrivateKey(allocator: std.mem.Allocator, pem: []const u8) ![]u8 {
    const begin_marker = "-----BEGIN PRIVATE KEY-----";
    const end_marker = "-----END PRIVATE KEY-----";
    const begin = std.mem.indexOf(u8, pem, begin_marker) orelse return VertexProviderError.InvalidPrivateKeyPem;
    const end = std.mem.indexOf(u8, pem, end_marker) orelse return VertexProviderError.InvalidPrivateKeyPem;
    if (end <= begin) return VertexProviderError.InvalidPrivateKeyPem;

    var base64_data = std.ArrayList(u8).empty;
    defer base64_data.deinit(allocator);

    const body = pem[begin + begin_marker.len .. end];
    for (body) |char| {
        switch (char) {
            '\n', '\r', ' ', '\t' => {},
            else => try base64_data.append(allocator, char),
        }
    }

    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(base64_data.items) catch return VertexProviderError.InvalidPrivateKeyPem;
    const decoded = try allocator.alloc(u8, decoded_len);
    errdefer allocator.free(decoded);
    try std.base64.standard.Decoder.decode(decoded, base64_data.items);
    return decoded;
}

fn parsePkcs8RsaPrivateKey(private_key_der: []const u8) !struct { modulus: []const u8, private_exponent: []const u8 } {
    const private_key_info = try asn1.Element.decode(private_key_der, 0);
    if (private_key_info.tag.number != .sequence) return VertexProviderError.InvalidPrivateKeyDer;

    var index = private_key_info.slice.start;
    const version = try asn1.Element.decode(private_key_der, index);
    if (version.tag.number != .integer) return VertexProviderError.InvalidPrivateKeyDer;
    index = version.slice.end;

    const algorithm = try asn1.Element.decode(private_key_der, index);
    if (algorithm.tag.number != .sequence) return VertexProviderError.InvalidPrivateKeyDer;
    index = algorithm.slice.end;

    const private_key = try asn1.Element.decode(private_key_der, index);
    if (private_key.tag.number != .octetstring) return VertexProviderError.InvalidPrivateKeyDer;

    const rsa_private_key = private_key.slice.view(private_key_der);
    const rsa_sequence = try asn1.Element.decode(rsa_private_key, 0);
    if (rsa_sequence.tag.number != .sequence) return VertexProviderError.InvalidPrivateKeyDer;

    var rsa_index = rsa_sequence.slice.start;
    const rsa_version = try asn1.Element.decode(rsa_private_key, rsa_index);
    if (rsa_version.tag.number != .integer) return VertexProviderError.InvalidPrivateKeyDer;
    rsa_index = rsa_version.slice.end;

    const modulus = try asn1.Element.decode(rsa_private_key, rsa_index);
    if (modulus.tag.number != .integer) return VertexProviderError.InvalidPrivateKeyDer;
    rsa_index = modulus.slice.end;

    const public_exponent = try asn1.Element.decode(rsa_private_key, rsa_index);
    if (public_exponent.tag.number != .integer) return VertexProviderError.InvalidPrivateKeyDer;
    rsa_index = public_exponent.slice.end;

    const private_exponent = try asn1.Element.decode(rsa_private_key, rsa_index);
    if (private_exponent.tag.number != .integer) return VertexProviderError.InvalidPrivateKeyDer;

    return .{
        .modulus = trimLeadingZeroBytes(modulus.slice.view(rsa_private_key)),
        .private_exponent = trimLeadingZeroBytes(private_exponent.slice.view(rsa_private_key)),
    };
}

fn trimLeadingZeroBytes(bytes: []const u8) []const u8 {
    var index: usize = 0;
    while (index + 1 < bytes.len and bytes[index] == 0) : (index += 1) {}
    return bytes[index..];
}

fn base64UrlEncodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes);
    return encoded;
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

fn loadApplicationDefaultCredentials(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (try loadEnvOptional(allocator, "GOOGLE_APPLICATION_CREDENTIALS")) |path| {
        defer allocator.free(path);
        return try readFileAllocMaybe(allocator, io, path);
    }

    if (try loadEnvOptional(allocator, "HOME")) |home| {
        defer allocator.free(home);
        const candidates = [_][]const u8{
            try std.fs.path.join(allocator, &[_][]const u8{ home, ".config", "gcloud", "application_default_credentials.json" }),
            try std.fs.path.join(allocator, &[_][]const u8{ home, "Library", "Application Support", "gcloud", "application_default_credentials.json" }),
        };
        defer {
            for (candidates) |candidate| allocator.free(candidate);
        }

        for (candidates) |candidate| {
            if (try readFileAllocMaybe(allocator, io, candidate)) |contents| return contents;
        }
    }

    return null;
}

fn maybeReadCredentialFile(allocator: std.mem.Allocator, io: std.Io, spec: []const u8) !?[]u8 {
    if (std.mem.indexOfScalar(u8, spec, '/') == null and
        std.mem.indexOfScalar(u8, spec, '\\') == null and
        !std.mem.endsWith(u8, spec, ".json"))
    {
        return null;
    }
    return try readFileAllocMaybe(allocator, io, spec);
}

fn readFileAllocMaybe(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn loadEnvOptional(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    const value = std.c.getenv(name_z) orelse return null;
    return try allocator.dupe(u8, std.mem.span(value));
}

fn resolveVertexProject(allocator: std.mem.Allocator, base_url: ?[]const u8) ![]u8 {
    if (try loadEnvOptional(allocator, "GOOGLE_CLOUD_PROJECT")) |project| return project;
    if (try loadEnvOptional(allocator, "GCLOUD_PROJECT")) |project| return project;
    if (base_url) |url| {
        if (extractPathSegment(url, "/projects/")) |project| return try allocator.dupe(u8, project);
    }
    return VertexProviderError.MissingVertexProject;
}

fn resolveVertexLocation(allocator: std.mem.Allocator, base_url: ?[]const u8) ![]u8 {
    if (try loadEnvOptional(allocator, "GOOGLE_CLOUD_LOCATION")) |location| return location;
    if (base_url) |url| {
        if (extractPathSegment(url, "/locations/")) |location| return try allocator.dupe(u8, location);
        if (extractHostPrefix(url, "-aiplatform.googleapis.com")) |location| return try allocator.dupe(u8, location);
    }
    return VertexProviderError.MissingVertexLocation;
}

fn resolveLocationPlaceholder(allocator: std.mem.Allocator, base_url: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, base_url, "{location}") == null) return try allocator.dupe(u8, base_url);
    const location = try resolveVertexLocation(allocator, base_url);
    defer allocator.free(location);
    return try std.mem.replaceOwned(u8, allocator, base_url, "{location}", location);
}

fn extractPathSegment(value: []const u8, marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, value, marker) orelse return null;
    const rest = value[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

fn extractHostPrefix(value: []const u8, suffix: []const u8) ?[]const u8 {
    const scheme_index = std.mem.indexOf(u8, value, "://") orelse return null;
    const host_start = scheme_index + 3;
    const host_and_path = value[host_start..];
    const host_end = std.mem.indexOfScalar(u8, host_and_path, '/') orelse host_and_path.len;
    const host = host_and_path[0..host_end];
    if (!std.mem.endsWith(u8, host, suffix)) return null;
    return host[0 .. host.len - suffix.len];
}

fn trimTrailingSlash(value: []const u8) []const u8 {
    var end = value.len;
    while (end > 0 and value[end - 1] == '/') : (end -= 1) {}
    return value[0..end];
}

fn pathHasApiVersion(base_url: []const u8) bool {
    if (std.mem.indexOf(u8, base_url, "/v1/") != null) return true;
    if (std.mem.endsWith(u8, base_url, "/v1")) return true;
    if (std.mem.indexOf(u8, base_url, "/v1beta") != null) return true;
    return false;
}

fn parseSseStreamLines(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    streaming: *http_client.StreamingResponse,
    model: types.Model,
    options: ?types.StreamOptions,
) !void {
    var output = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .stop,
        .timestamp = 0,
    };

    var content_blocks = std.ArrayList(types.ContentBlock).empty;
    defer content_blocks.deinit(allocator);

    var tool_calls = std.ArrayList(types.ToolCall).empty;
    defer tool_calls.deinit(allocator);

    var current_block: ?CurrentBlock = null;
    defer if (current_block) |*block| deinitCurrentBlock(allocator, block);

    var generated_tool_call_count: usize = 0;

    stream_ptr.push(.{ .event_type = .start });

    while (true) {
        const maybe_line = streaming.readLine() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, model, err);
                return;
            },
        };
        const line = maybe_line orelse break;
        if (isAbortRequested(options)) {
            try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, model, error.RequestAborted);
            return;
        }

        const data = parseSseLine(std.mem.trim(u8, line, " \t\r")) orelse continue;
        if (std.mem.eql(u8, data, "[DONE]")) break;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, data, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                try emitRuntimeFailure(allocator, stream_ptr, &output, &current_block, &content_blocks, &tool_calls, model, err);
                return;
            },
        };
        defer parsed.deinit();
        const value = parsed.value;
        if (value != .object) continue;

        if (value.object.get("responseId")) |response_id| {
            if (response_id == .string and output.response_id == null) {
                output.response_id = try allocator.dupe(u8, response_id.string);
            }
        }

        if (value.object.get("usageMetadata")) |usage_metadata| {
            updateUsage(&output.usage, usage_metadata);
            calculateCost(model, &output.usage);
        }

        const candidates_value = value.object.get("candidates") orelse continue;
        if (candidates_value != .array or candidates_value.array.items.len == 0) continue;

        const candidate = candidates_value.array.items[0];
        if (candidate != .object) continue;

        if (candidate.object.get("content")) |content_value| {
            if (content_value == .object) {
                if (content_value.object.get("parts")) |parts_value| {
                    if (parts_value == .array) {
                        for (parts_value.array.items) |part| {
                            if (part != .object) continue;

                            if (part.object.get("text")) |text_value| {
                                if (text_value == .string and text_value.string.len > 0) {
                                    const is_thinking = if (part.object.get("thought")) |thought_value|
                                        thought_value == .bool and thought_value.bool
                                    else
                                        false;

                                    if (current_block == null or !matchesCurrentBlock(current_block.?, is_thinking)) {
                                        try finishCurrentBlock(allocator, &current_block, &content_blocks, stream_ptr);
                                        current_block = if (is_thinking)
                                            .{ .thinking = .{ .text = std.ArrayList(u8).empty, .signature = null } }
                                        else
                                            .{ .text = .{ .text = std.ArrayList(u8).empty, .signature = null } };
                                        stream_ptr.push(.{
                                            .event_type = if (is_thinking) .thinking_start else .text_start,
                                            .content_index = @intCast(content_blocks.items.len),
                                        });
                                    }

                                    if (current_block) |*block| {
                                        switch (block.*) {
                                            .text => |*text| {
                                                try text.text.appendSlice(allocator, text_value.string);
                                                if (part.object.get("thoughtSignature")) |signature_value| {
                                                    if (signature_value == .string and signature_value.string.len > 0) {
                                                        if (text.signature) |existing| allocator.free(existing);
                                                        text.signature = try allocator.dupe(u8, signature_value.string);
                                                    }
                                                }
                                            },
                                            .thinking => |*thinking| {
                                                try thinking.text.appendSlice(allocator, text_value.string);
                                                if (part.object.get("thoughtSignature")) |signature_value| {
                                                    if (signature_value == .string and signature_value.string.len > 0) {
                                                        if (thinking.signature) |existing| allocator.free(existing);
                                                        thinking.signature = try allocator.dupe(u8, signature_value.string);
                                                    }
                                                }
                                            },
                                        }
                                    }

                                    stream_ptr.push(.{
                                        .event_type = if (is_thinking) .thinking_delta else .text_delta,
                                        .content_index = @intCast(content_blocks.items.len),
                                        .delta = try allocator.dupe(u8, text_value.string),
                                        .owns_delta = true,
                                    });
                                }
                            }

                            if (part.object.get("functionCall")) |function_call_value| {
                                if (function_call_value == .object) {
                                    try finishCurrentBlock(allocator, &current_block, &content_blocks, stream_ptr);
                                    const name_value = function_call_value.object.get("name");
                                    if (name_value == null or name_value.? != .string) continue;

                                    const args = if (function_call_value.object.get("args")) |args_value|
                                        try cloneJsonValue(allocator, args_value)
                                    else
                                        try emptyJsonObject(allocator);

                                    const tool_call_id = if (function_call_value.object.get("id")) |id_value|
                                        if (id_value == .string and id_value.string.len > 0) try allocator.dupe(u8, id_value.string) else try generateToolCallId(allocator, &generated_tool_call_count)
                                    else
                                        try generateToolCallId(allocator, &generated_tool_call_count);

                                    const thought_signature = if (part.object.get("thoughtSignature")) |signature_value|
                                        if (signature_value == .string and signature_value.string.len > 0) try allocator.dupe(u8, signature_value.string) else null
                                    else
                                        null;

                                    const tool_call = types.ToolCall{
                                        .id = tool_call_id,
                                        .name = try allocator.dupe(u8, name_value.?.string),
                                        .arguments = args,
                                        .thought_signature = thought_signature,
                                    };
                                    try tool_calls.append(allocator, tool_call);
                                    try content_blocks.append(allocator, .{ .tool_call = .{
                                        .id = try allocator.dupe(u8, tool_call.id),
                                        .name = try allocator.dupe(u8, tool_call.name),
                                        .arguments = try cloneJsonValue(allocator, tool_call.arguments),
                                        .thought_signature = if (tool_call.thought_signature) |signature| try allocator.dupe(u8, signature) else null,
                                    } });

                                    stream_ptr.push(.{
                                        .event_type = .toolcall_start,
                                        .content_index = @intCast(content_blocks.items.len - 1),
                                    });

                                    const args_json = try std.json.Stringify.valueAlloc(allocator, args, .{});
                                    defer allocator.free(args_json);
                                    stream_ptr.push(.{
                                        .event_type = .toolcall_delta,
                                        .content_index = @intCast(content_blocks.items.len - 1),
                                        .delta = try allocator.dupe(u8, args_json),
                                        .owns_delta = true,
                                    });
                                    stream_ptr.push(.{
                                        .event_type = .toolcall_end,
                                        .content_index = @intCast(content_blocks.items.len - 1),
                                        .tool_call = tool_call,
                                    });
                                }
                            }
                        }
                    }
                }
            }
        }

        if (candidate.object.get("finishReason")) |finish_reason| {
            if (finish_reason == .string) {
                output.stop_reason = if (tool_calls.items.len > 0) .tool_use else mapStopReason(finish_reason.string);
            }
        }
    }

    try finishCurrentBlock(allocator, &current_block, &content_blocks, stream_ptr);
    calculateCost(model, &output.usage);
    output.content = try content_blocks.toOwnedSlice(allocator);
    output.tool_calls = if (tool_calls.items.len > 0) try tool_calls.toOwnedSlice(allocator) else null;

    stream_ptr.push(.{
        .event_type = .done,
        .message = output,
    });
    stream_ptr.end(output);
}

fn emitAuthError(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
    message_text: []const u8,
) !void {
    const error_message = try allocator.dupe(u8, message_text);
    const message = types.AssistantMessage{
        .content = &[_]types.ContentBlock{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = types.Usage.init(),
        .stop_reason = .error_reason,
        .error_message = error_message,
        .timestamp = 0,
    };
    stream_ptr.push(.{
        .event_type = .error_event,
        .error_message = error_message,
        .message = message,
    });
    stream_ptr.end(message);
}

fn authErrorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.MissingGoogleVertexCredentials => "Vertex AI requires GOOGLE_CLOUD_API_KEY or Application Default Credentials.",
        error.MissingVertexProject => "Vertex AI requires a project ID. Set GOOGLE_CLOUD_PROJECT or GCLOUD_PROJECT.",
        error.MissingVertexLocation => "Vertex AI requires a location. Set GOOGLE_CLOUD_LOCATION or encode it in the endpoint.",
        error.InvalidGoogleCredentials => "Vertex AI credentials are not valid JSON or use an unsupported schema.",
        error.UnsupportedGoogleCredentialsType => "Vertex AI credentials must be an authorized_user or service_account JSON file.",
        error.MissingGoogleRefreshToken => "Vertex AI authorized_user credentials are missing refresh_token.",
        error.MissingGoogleClientId => "Vertex AI authorized_user credentials are missing client_id.",
        error.MissingGoogleClientSecret => "Vertex AI authorized_user credentials are missing client_secret.",
        error.MissingGoogleClientEmail => "Vertex AI service account credentials are missing client_email.",
        error.MissingGooglePrivateKey => "Vertex AI service account credentials are missing private_key.",
        error.InvalidPrivateKeyPem, error.InvalidPrivateKeyDer => "Vertex AI service account private key could not be parsed.",
        error.OAuthTokenRequestFailed, error.InvalidTokenResponse, error.MissingAccessToken => "Vertex AI OAuth token exchange failed.",
        else => "Vertex AI authentication failed.",
    };
}

fn buildContentsValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    messages: []const types.Message,
) !std.json.Value {
    var contents = std.json.Array.init(allocator);
    errdefer contents.deinit();

    var index: usize = 0;
    while (index < messages.len) : (index += 1) {
        switch (messages[index]) {
            .user => |user| try contents.append(try buildUserMessageValue(allocator, model, user)),
            .assistant => |assistant| {
                if (types.shouldReplayAssistantInProviderContext(assistant)) {
                    if (try buildAssistantMessageValue(allocator, assistant)) |assistant_value| {
                        try contents.append(assistant_value);
                    }
                }
            },
            .tool_result => {
                const grouped = try buildToolResultMessageValue(allocator, model, messages[index..]);
                try contents.append(grouped.value);
                index += grouped.consumed - 1;
            },
        }
    }

    return .{ .array = contents };
}

fn buildSystemInstructionValue(allocator: std.mem.Allocator, system_prompt: []const u8) !std.json.Value {
    var parts = std.json.Array.init(allocator);
    try parts.append(try buildTextPartValue(allocator, system_prompt));

    var object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try object.put(allocator, try allocator.dupe(u8, "parts"), .{ .array = parts });
    return .{ .object = object };
}

fn buildGenerationConfigValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    options: ?types.StreamOptions,
) !std.json.Value {
    var generation_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    errdefer generation_config.deinit(allocator);

    if (options) |stream_options| {
        if (stream_options.temperature) |temperature| {
            try generation_config.put(allocator, try allocator.dupe(u8, "temperature"), .{ .float = temperature });
        }
        if (stream_options.max_tokens) |max_tokens| {
            try generation_config.put(allocator, try allocator.dupe(u8, "maxOutputTokens"), .{ .integer = @intCast(max_tokens) });
        }
        if (stream_options.google_thinking) |thinking| {
            if (model.reasoning) {
                var thinking_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                if (thinking.enabled) {
                    try thinking_config.put(allocator, try allocator.dupe(u8, "includeThoughts"), .{ .bool = true });
                    if (thinking.budget_tokens) |budget_tokens| {
                        try thinking_config.put(allocator, try allocator.dupe(u8, "thinkingBudget"), .{ .integer = @intCast(budget_tokens) });
                    }
                    if (thinking.level) |level| {
                        try thinking_config.put(allocator, try allocator.dupe(u8, "thinkingLevel"), .{ .string = try allocator.dupe(u8, level) });
                    }
                } else {
                    try thinking_config.put(allocator, try allocator.dupe(u8, "thinkingBudget"), .{ .integer = 0 });
                }
                try generation_config.put(allocator, try allocator.dupe(u8, "thinkingConfig"), .{ .object = thinking_config });
            }
        }
    }

    return .{ .object = generation_config };
}

fn buildToolsValue(allocator: std.mem.Allocator, tools: []const types.Tool) !std.json.Value {
    var function_declarations = std.json.Array.init(allocator);
    errdefer function_declarations.deinit();

    for (tools) |tool| {
        var declaration = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
        try declaration.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool.name) });
        try declaration.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
        try declaration.put(allocator, try allocator.dupe(u8, "parametersJsonSchema"), try cloneJsonValue(allocator, tool.parameters));
        try function_declarations.append(.{ .object = declaration });
    }

    var tool_entry = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_entry.put(allocator, try allocator.dupe(u8, "functionDeclarations"), .{ .array = function_declarations });

    var tools_array = std.json.Array.init(allocator);
    try tools_array.append(.{ .object = tool_entry });
    return .{ .array = tools_array };
}

fn buildToolConfigValue(allocator: std.mem.Allocator, tool_choice: []const u8) !std.json.Value {
    var function_calling_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try function_calling_config.put(allocator, try allocator.dupe(u8, "mode"), .{ .string = try allocator.dupe(u8, mapToolChoice(tool_choice)) });

    var tool_config = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_config.put(allocator, try allocator.dupe(u8, "functionCallingConfig"), .{ .object = function_calling_config });
    return .{ .object = tool_config };
}

fn buildUserMessageValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    user: types.UserMessage,
) !std.json.Value {
    const parts = try buildPartsArray(allocator, user.content, modelSupportsImages(model));
    return try buildRoleMessageValue(allocator, "user", .{ .array = parts });
}

fn buildAssistantMessageValue(
    allocator: std.mem.Allocator,
    assistant: types.AssistantMessage,
) !?std.json.Value {
    var parts = std.json.Array.init(allocator);
    errdefer parts.deinit();

    for (assistant.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, " \t\r\n").len == 0) continue;
                try parts.append(try buildTextPartWithSignatureValue(allocator, text.text, text.text_signature));
            },
            .thinking => |thinking| {
                if (std.mem.trim(u8, thinking.thinking, " \t\r\n").len == 0) continue;
                var thought_part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try thought_part.put(allocator, try allocator.dupe(u8, "thought"), .{ .bool = true });
                try thought_part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, thinking.thinking) });
                if (types.thinkingSignature(thinking)) |signature| {
                    try thought_part.put(allocator, try allocator.dupe(u8, "thoughtSignature"), .{ .string = try allocator.dupe(u8, signature) });
                }
                try parts.append(.{ .object = thought_part });
            },
            .image => {},
            .tool_call => |tool_call| {
                var function_call = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try function_call.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_call.name) });
                try function_call.put(allocator, try allocator.dupe(u8, "args"), try cloneJsonValue(allocator, tool_call.arguments));

                var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                if (tool_call.thought_signature) |signature| {
                    try part.put(allocator, try allocator.dupe(u8, "thoughtSignature"), .{ .string = try allocator.dupe(u8, signature) });
                }
                try part.put(allocator, try allocator.dupe(u8, "functionCall"), .{ .object = function_call });
                try parts.append(.{ .object = part });
            },
        }
    }

    if (!types.hasInlineToolCalls(assistant)) {
        if (assistant.tool_calls) |tool_calls| {
            for (tool_calls) |tool_call| {
                var function_call = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try function_call.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_call.name) });
                try function_call.put(allocator, try allocator.dupe(u8, "args"), try cloneJsonValue(allocator, tool_call.arguments));

                var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                if (tool_call.thought_signature) |signature| {
                    try part.put(allocator, try allocator.dupe(u8, "thoughtSignature"), .{ .string = try allocator.dupe(u8, signature) });
                }
                try part.put(allocator, try allocator.dupe(u8, "functionCall"), .{ .object = function_call });
                try parts.append(.{ .object = part });
            }
        }
    }

    if (parts.items.len == 0) return null;
    return try buildRoleMessageValue(allocator, "model", .{ .array = parts });
}

fn buildToolResultMessageValue(
    allocator: std.mem.Allocator,
    model: types.Model,
    messages: []const types.Message,
) !struct { value: std.json.Value, consumed: usize } {
    var parts = std.json.Array.init(allocator);
    errdefer parts.deinit();

    var consumed: usize = 0;
    while (consumed < messages.len) : (consumed += 1) {
        switch (messages[consumed]) {
            .tool_result => |tool_result| {
                var function_response = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try function_response.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool_result.tool_name) });

                var response = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                const text_response = try buildToolResultText(allocator, model, tool_result.content);
                defer allocator.free(text_response);
                try response.put(
                    allocator,
                    try allocator.dupe(u8, if (tool_result.is_error) "error" else "output"),
                    .{ .string = try allocator.dupe(u8, text_response) },
                );
                try function_response.put(allocator, try allocator.dupe(u8, "response"), .{ .object = response });

                if (modelSupportsImages(model)) {
                    if (try buildToolResultImageParts(allocator, tool_result.content)) |image_parts| {
                        try function_response.put(allocator, try allocator.dupe(u8, "parts"), .{ .array = image_parts });
                    }
                }

                var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
                try part.put(allocator, try allocator.dupe(u8, "functionResponse"), .{ .object = function_response });
                try parts.append(.{ .object = part });
            },
            else => break,
        }
    }

    return .{
        .value = try buildRoleMessageValue(allocator, "user", .{ .array = parts }),
        .consumed = consumed,
    };
}

fn buildPartsArray(
    allocator: std.mem.Allocator,
    content: []const types.ContentBlock,
    supports_images: bool,
) !std.json.Array {
    var parts = std.json.Array.init(allocator);
    errdefer parts.deinit();

    var inserted_placeholder = false;
    for (content) |block| {
        switch (block) {
            .text => |text| {
                try parts.append(try buildTextPartValue(allocator, text.text));
                inserted_placeholder = false;
            },
            .image => |image| {
                if (supports_images) {
                    try parts.append(try buildImagePartValue(allocator, image.mime_type, image.data));
                } else if (!inserted_placeholder) {
                    try parts.append(try buildTextPartValue(allocator, "(image omitted: model does not support images)"));
                    inserted_placeholder = true;
                }
            },
            .thinking, .tool_call => {},
        }
    }

    if (parts.items.len == 0) {
        try parts.append(try buildTextPartValue(allocator, ""));
    }
    return parts;
}

fn buildTextPartValue(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return buildTextPartWithSignatureValue(allocator, text, null);
}

fn buildTextPartWithSignatureValue(allocator: std.mem.Allocator, text: []const u8, signature: ?[]const u8) !std.json.Value {
    var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try part.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
    if (signature) |thought_signature| {
        if (thought_signature.len > 0) {
            try part.put(allocator, try allocator.dupe(u8, "thoughtSignature"), .{ .string = try allocator.dupe(u8, thought_signature) });
        }
    }
    return .{ .object = part };
}

fn buildImagePartValue(allocator: std.mem.Allocator, mime_type: []const u8, data: []const u8) !std.json.Value {
    var inline_data = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try inline_data.put(allocator, try allocator.dupe(u8, "mimeType"), .{ .string = try allocator.dupe(u8, mime_type) });
    try inline_data.put(allocator, try allocator.dupe(u8, "data"), .{ .string = try allocator.dupe(u8, data) });

    var part = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try part.put(allocator, try allocator.dupe(u8, "inlineData"), .{ .object = inline_data });
    return .{ .object = part };
}

fn buildRoleMessageValue(allocator: std.mem.Allocator, role: []const u8, parts: std.json.Value) !std.json.Value {
    var message = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try message.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role) });
    try message.put(allocator, try allocator.dupe(u8, "parts"), parts);
    return .{ .object = message };
}

fn buildToolResultText(
    allocator: std.mem.Allocator,
    model: types.Model,
    content: []const types.ContentBlock,
) ![]const u8 {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);

    var has_images = false;
    var has_text = false;
    for (content) |block| {
        switch (block) {
            .text => |text_block| {
                if (has_text) try text.append(allocator, '\n');
                try text.appendSlice(allocator, text_block.text);
                has_text = true;
            },
            .image => has_images = true,
            .thinking => |thinking| {
                if (has_text) try text.append(allocator, '\n');
                try text.appendSlice(allocator, thinking.thinking);
                has_text = true;
            },
            .tool_call => {},
        }
    }

    if (!has_text and has_images and modelSupportsImages(model)) {
        try text.appendSlice(allocator, "(see attached image)");
    }

    return try allocator.dupe(u8, text.items);
}

fn buildToolResultImageParts(allocator: std.mem.Allocator, content: []const types.ContentBlock) !?std.json.Array {
    var parts = std.json.Array.init(allocator);
    errdefer parts.deinit();

    for (content) |block| {
        switch (block) {
            .image => |image| try parts.append(try buildImagePartValue(allocator, image.mime_type, image.data)),
            else => {},
        }
    }

    if (parts.items.len == 0) return null;
    return parts;
}

fn finalizeOutputFromPartials(
    allocator: std.mem.Allocator,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    stream_ptr: *event_stream.AssistantMessageEventStream,
    model: types.Model,
) !void {
    try finishCurrentBlock(allocator, current_block, content_blocks, stream_ptr);
    calculateCost(model, &output.usage);
    if (output.content.len == 0 and content_blocks.items.len > 0) {
        output.content = try content_blocks.toOwnedSlice(allocator);
    }
    if (output.tool_calls == null and tool_calls.items.len > 0) {
        output.tool_calls = try tool_calls.toOwnedSlice(allocator);
    }
}

fn emitRuntimeFailure(
    allocator: std.mem.Allocator,
    stream_ptr: *event_stream.AssistantMessageEventStream,
    output: *types.AssistantMessage,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    tool_calls: *std.ArrayList(types.ToolCall),
    model: types.Model,
    err: anyerror,
) !void {
    try finalizeOutputFromPartials(allocator, output, current_block, content_blocks, tool_calls, stream_ptr, model);
    output.stop_reason = provider_error.runtimeStopReason(err);
    output.error_message = provider_error.runtimeErrorMessage(err);
    provider_error.pushTerminalRuntimeError(stream_ptr, output.*);
}

fn matchesCurrentBlock(block: CurrentBlock, is_thinking: bool) bool {
    return switch (block) {
        .text => !is_thinking,
        .thinking => is_thinking,
    };
}

fn finishCurrentBlock(
    allocator: std.mem.Allocator,
    current_block: *?CurrentBlock,
    content_blocks: *std.ArrayList(types.ContentBlock),
    stream_ptr: *event_stream.AssistantMessageEventStream,
) !void {
    if (current_block.*) |*block| {
        switch (block.*) {
            .text => |text| {
                const owned = try allocator.dupe(u8, text.text.items);
                const signature = if (text.signature) |value| try allocator.dupe(u8, value) else null;
                try content_blocks.append(allocator, .{ .text = .{
                    .text = owned,
                    .text_signature = signature,
                } });
                stream_ptr.push(.{
                    .event_type = .text_end,
                    .content_index = @intCast(content_blocks.items.len - 1),
                    .content = owned,
                });
            },
            .thinking => |thinking| {
                const owned = try allocator.dupe(u8, thinking.text.items);
                const signature = if (thinking.signature) |value| try allocator.dupe(u8, value) else null;
                try content_blocks.append(allocator, .{ .thinking = .{
                    .thinking = owned,
                    .signature = signature,
                    .redacted = false,
                } });
                stream_ptr.push(.{
                    .event_type = .thinking_end,
                    .content_index = @intCast(content_blocks.items.len - 1),
                    .content = owned,
                });
            },
        }
        deinitCurrentBlock(allocator, block);
        current_block.* = null;
    }
}

fn deinitCurrentBlock(allocator: std.mem.Allocator, block: *CurrentBlock) void {
    switch (block.*) {
        .text => |*text| {
            text.text.deinit(allocator);
            if (text.signature) |signature| allocator.free(signature);
        },
        .thinking => |*thinking| {
            thinking.text.deinit(allocator);
            if (thinking.signature) |signature| allocator.free(signature);
        },
    }
}

fn parseSseLine(line: []const u8) ?[]const u8 {
    const prefix = "data: ";
    if (std.mem.startsWith(u8, line, prefix)) return line[prefix.len..];
    return null;
}

fn mapToolChoice(tool_choice: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(tool_choice, "none")) return "NONE";
    if (std.ascii.eqlIgnoreCase(tool_choice, "any")) return "ANY";
    return "AUTO";
}

fn mapStopReason(reason: []const u8) types.StopReason {
    if (std.mem.eql(u8, reason, "STOP")) return .stop;
    if (std.mem.eql(u8, reason, "MAX_TOKENS")) return .length;
    return .error_reason;
}

fn generateToolCallId(allocator: std.mem.Allocator, counter: *usize) ![]const u8 {
    counter.* += 1;
    return try std.fmt.allocPrint(allocator, "vertex-call-{d}", .{counter.*});
}

fn modelSupportsImages(model: types.Model) bool {
    for (model.input_types) |input_type| {
        if (std.mem.eql(u8, input_type, "image")) return true;
    }
    return false;
}

fn emptyJsonObject(allocator: std.mem.Allocator) !std.json.Value {
    return .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) };
}

fn updateUsage(usage: *types.Usage, usage_value: std.json.Value) void {
    if (usage_value != .object) return;

    const prompt_tokens = getJsonU32(usage_value.object.get("promptTokenCount"));
    const cached_tokens = getJsonU32(usage_value.object.get("cachedContentTokenCount"));
    const candidate_tokens = getJsonU32(usage_value.object.get("candidatesTokenCount"));
    const thought_tokens = getJsonU32(usage_value.object.get("thoughtsTokenCount"));
    const total_tokens = getJsonU32(usage_value.object.get("totalTokenCount"));

    usage.input = prompt_tokens -| cached_tokens;
    usage.output = candidate_tokens + thought_tokens;
    usage.cache_read = cached_tokens;
    usage.cache_write = 0;
    usage.total_tokens = if (total_tokens > 0) total_tokens else usage.input + usage.output + usage.cache_read;
}

fn getJsonU32(value: ?std.json.Value) u32 {
    if (value) |json_value| {
        if (json_value == .integer and json_value.integer >= 0) {
            return @intCast(json_value.integer);
        }
    }
    return 0;
}

fn calculateCost(model: types.Model, usage: *types.Usage) void {
    usage.cost.input = (@as(f64, @floatFromInt(usage.input)) / 1_000_000.0) * model.cost.input;
    usage.cost.output = (@as(f64, @floatFromInt(usage.output)) / 1_000_000.0) * model.cost.output;
    usage.cost.cache_read = (@as(f64, @floatFromInt(usage.cache_read)) / 1_000_000.0) * model.cost.cache_read;
    usage.cost.cache_write = (@as(f64, @floatFromInt(usage.cache_write)) / 1_000_000.0) * model.cost.cache_write;
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
}

fn putOwnedHeader(
    allocator: std.mem.Allocator,
    headers: *std.StringHashMap([]const u8),
    name: []const u8,
    value: []const u8,
) !void {
    try headers.put(try allocator.dupe(u8, name), try allocator.dupe(u8, value));
}

fn mergeHeaders(
    allocator: std.mem.Allocator,
    target: *std.StringHashMap([]const u8),
    source: ?std.StringHashMap([]const u8),
) !void {
    if (source) |headers| {
        var iterator = headers.iterator();
        while (iterator.next()) |entry| {
            try putOwnedHeader(allocator, target, entry.key_ptr.*, entry.value_ptr.*);
        }
    }
}

fn isAbortRequested(options: ?types.StreamOptions) bool {
    if (options) |stream_options| {
        if (stream_options.signal) |signal| return signal.load(.seq_cst);
    }
    return false;
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |boolean| return .{ .bool = boolean },
        .integer => |integer| return .{ .integer = integer },
        .float => |float| return .{ .float = float },
        .number_string => |number_string| return .{ .number_string = try allocator.dupe(u8, number_string) },
        .string => |string| return .{ .string = try allocator.dupe(u8, string) },
        .array => |array| {
            var clone = std.json.Array.init(allocator);
            for (array.items) |item| try clone.append(try cloneJsonValue(allocator, item));
            return .{ .array = clone };
        },
        .object => |object| {
            var clone = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
            var iterator = object.iterator();
            while (iterator.next()) |entry| {
                try clone.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            return .{ .object = clone };
        },
    }
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string => |s| allocator.free(s),
        .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var owned = arr;
            owned.deinit();
        },
        .object => |obj| {
            var iterator = obj.iterator();
            while (iterator.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var owned = obj;
            owned.deinit(allocator);
        },
        else => {},
    }
}

fn extractErrorMessage(body: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    return if (trimmed.len == 0) body else trimmed;
}

test "buildRequestPayload includes Vertex contents, tools, and thinking config" {
    const allocator = std.testing.allocator;

    var tool_schema = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{});
    try tool_schema.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "object") });
    try tool_schema.put(allocator, try allocator.dupe(u8, "properties"), .{ .object = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]std.json.Value{}) });
    const tool_schema_value = std.json.Value{ .object = tool_schema };
    defer freeJsonValue(allocator, tool_schema_value);

    const tools = &[_]types.Tool{.{
        .name = "get_weather",
        .description = "Get the weather",
        .parameters = tool_schema_value,
    }};

    const context = types.Context{
        .system_prompt = "You are helpful.",
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{
                    .{ .text = .{ .text = "Describe this image" } },
                    .{ .image = .{ .data = "aGVsbG8=", .mime_type = "image/png" } },
                },
                .timestamp = 1,
            } },
        },
        .tools = tools,
    };

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google",
        .reasoning = true,
        .input_types = &[_][]const u8{ "text", "image" },
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const payload = try buildRequestPayload(allocator, model, context, .{
        .temperature = 0.5,
        .max_tokens = 2048,
        .google_tool_choice = "any",
        .google_thinking = .{
            .enabled = true,
            .budget_tokens = 8192,
        },
    });
    defer freeJsonValue(allocator, payload);

    try std.testing.expect(payload.object.get("contents") != null);
    try std.testing.expect(payload.object.get("systemInstruction") != null);
    try std.testing.expect(payload.object.get("tools") != null);
    try std.testing.expect(payload.object.get("toolConfig") != null);
    try std.testing.expect(payload.object.get("generationConfig") != null);
}

test "buildRequestUrl formats Vertex publisher endpoint" {
    const allocator = std.testing.allocator;
    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google",
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    const url = try buildRequestUrl(allocator, model);
    defer allocator.free(url);

    try std.testing.expectEqualStrings(
        "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google/models/gemini-2.5-pro:streamGenerateContent?alt=sse",
        url,
    );
}

test "buildAuthorizedUserTokenRequestBody encodes refresh token grant" {
    const allocator = std.testing.allocator;
    const body = try buildAuthorizedUserTokenRequestBody(allocator, .{
        .client_id = "client-id",
        .client_secret = "client secret",
        .refresh_token = "refresh/token",
        .token_uri = DEFAULT_TOKEN_URI,
    });
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "grant_type=refresh_token") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "client_secret=client%20secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "refresh_token=refresh%2Ftoken") != null);
}

test "buildServiceAccountAssertion encodes a signed JWT" {
    const allocator = std.testing.allocator;

    const credentials = ServiceAccountCredentials{
        .client_email = "vertex-test@project.iam.gserviceaccount.com",
        .private_key_pem = "-----BEGIN PRIVATE KEY-----\n" ++
            "MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAK/SEfVlRdzwgyBN\n" ++
            "UbxPuQ7NtfnaJgsbK+5rRa0qHQLKwpAsc0s3ZuT43vV1YbxPyYS044poIBwLmLs1\n" ++
            "/T9LSFeFNwyybUW5nVK1VGPO0woy82LoAjA46FmqEa4baaAu3f+Vq5jLWocmXI0w\n" ++
            "jLfSnje7C7nRVBY2kDwVS1/VHLNFAgMBAAECgYAb0f+pdsbhOOVmvRVL2MmNgBtl\n" ++
            "V5FhfIEtDqhNyDYi9PZoXcA4jKGpZX/SEyrN40odx4mhouxBw8v9A4P4+e6ON4hE\n" ++
            "wYrfJ5+LLTbT00CVvpP232eYj7L5NF9AcWoH/rIvs3SbIOoDrX0QA4J79TOIJVcs\n" ++
            "BWmV1hO23P9TxIXXGQJBANqoZ9qEloCnvhKhg+4vWIEZUCOULKcpEgZzG96RKiKZ\n" ++
            "tR7uooQuq0Vw6Hz0hZUxcUO3/27iGzy5X0MOu/FsFjsCQQDN2Ng+3HjZs3/hTcgt\n" ++
            "KGJ4r1RmXLvyO+AepWn7ahPG/d/5hSfo8GYixBuT+77pdCXiChQ6taPj1HguXNAI\n" ++
            "YkR/AkAo5crXAmmsErPohDFLAawKKZPls7dOZM4sSqdxz7ET27AW4weetaPvTxkN\n" ++
            "FidOKntG8UljkgMKLpn0zvK0S0U1AkBB2+cT9aYUwQFhLGmnSQx4YGA4f+MCFXYX\n" ++
            "WAUYk0/QktleE+Q4+vEynlvUdO8X8jlMoLzoK8VL12a8LqXAiPAxAkEAnZQ+rfph\n" ++
            "Br+fH6YFqGNfK1/QU0kis7YglMnydI1yo2/gfHfCK3mkAgPgdk7aQPPm//Dh/RYW\n" ++
            "oH//P8IEqjq+hQ==\n" ++
            "-----END PRIVATE KEY-----\n",
        .token_uri = DEFAULT_TOKEN_URI,
    };

    const assertion = try buildServiceAccountAssertion(allocator, credentials, 1_700_000_000);
    defer allocator.free(assertion);

    var parts = std.mem.splitScalar(u8, assertion, '.');
    try std.testing.expect(parts.next() != null);
    const payload_segment = parts.next().?;
    const signature_segment = parts.next().?;
    try std.testing.expect(parts.next() == null);
    try std.testing.expect(signature_segment.len > 0);

    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_segment);
    const decoded = try allocator.alloc(u8, decoded_len);
    defer allocator.free(decoded);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_segment);

    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"iss\":\"vertex-test@project.iam.gserviceaccount.com\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, decoded, "\"scope\":\"https://www.googleapis.com/auth/cloud-platform\"") != null);
}

test "resolveCredentialsFromInputs supports service account ADC and API key" {
    const allocator = std.testing.allocator;

    const service_account_json =
        "{\n" ++
        "  \"type\": \"service_account\",\n" ++
        "  \"project_id\": \"test-project\",\n" ++
        "  \"client_email\": \"vertex-test@project.iam.gserviceaccount.com\",\n" ++
        "  \"private_key\": \"-----BEGIN PRIVATE KEY-----\\nMIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGBAK/SEfVlRdzwgyBNUbxPuQ7NtfnaJgsbK+5rRa0qHQLKwpAsc0s3ZuT43vV1YbxPyYS044poIBwLmLs1/T9LSFeFNwyybUW5nVK1VGPO0woy82LoAjA46FmqEa4baaAu3f+Vq5jLWocmXI0wjLfSnje7C7nRVBY2kDwVS1/VHLNFAgMBAAECgYAb0f+pdsbhOOVmvRVL2MmNgBtlV5FhfIEtDqhNyDYi9PZoXcA4jKGpZX/SEyrN40odx4mhouxBw8v9A4P4+e6ON4hEwYrfJ5+LLTbT00CVvpP232eYj7L5NF9AcWoH/rIvs3SbIOoDrX0QA4J79TOIJVcsBWmV1hO23P9TxIXXGQJBANqoZ9qEloCnvhKhg+4vWIEZUCOULKcpEgZzG96RKiKZtR7uooQuq0Vw6Hz0hZUxcUO3/27iGzy5X0MOu/FsFjsCQQDN2Ng+3HjZs3/hTcgtKGJ4r1RmXLvyO+AepWn7ahPG/d/5hSfo8GYixBuT+77pdCXiChQ6taPj1HguXNAIYkR/AkAo5crXAmmsErPohDFLAawKKZPls7dOZM4sSqdxz7ET27AW4weetaPvTxkNFidOKntG8UljkgMKLpn0zvK0S0U1AkBB2+cT9aYUwQFhLGmnSQx4YGA4f+MCFXYXWAUYk0/QktleE+Q4+vEynlvUdO8X8jlMoLzoK8VL12a8LqXAiPAxAkEAnZQ+rfphBr+fH6YFqGNfK1/QU0kis7YglMnydI1yo2/gfHfCK3mkAgPgdk7aQPPm//Dh/RYWoH//P8IEqjq+hQ==\\n-----END PRIVATE KEY-----\\n\"\n" ++
        "}\n";

    var service_account = try resolveCredentialsFromInputs(allocator, std.Io.failing, null, AUTHENTICATED_SENTINEL, service_account_json);
    defer service_account.deinit(allocator);
    try std.testing.expect(service_account == .service_account);

    var api_key = try resolveCredentialsFromInputs(allocator, std.Io.failing, "vertex-api-key", null, null);
    defer api_key.deinit(allocator);
    try std.testing.expect(api_key == .api_key);
    try std.testing.expectEqualStrings("vertex-api-key", api_key.api_key);

    try std.testing.expectError(VertexProviderError.MissingGoogleVertexCredentials, resolveCredentialsFromInputs(allocator, std.Io.failing, null, null, null));
}

test "parse stream emits Vertex thinking, tool, and text events" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;

    const body = try allocator.dupe(
        u8,
        "data: {\"responseId\":\"resp-vertex\",\"candidates\":[{\"content\":{\"parts\":[{\"thought\":true,\"text\":\"Need tool\",\"thoughtSignature\":\"c2ln\"},{\"functionCall\":{\"name\":\"get_weather\",\"args\":{\"city\":\"Berlin\"}}},{\"text\":\"It is sunny.\"}],\"role\":\"model\"},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":20,\"cachedContentTokenCount\":2,\"candidatesTokenCount\":7,\"thoughtsTokenCount\":3,\"totalTokenCount\":30}}\n" ++
            "data: [DONE]\n",
    );

    var stream_instance = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream_instance.deinit();

    var streaming = http_client.StreamingResponse{
        .status = 200,
        .body = body,
        .buffer = .empty,
        .allocator = allocator,
    };
    defer streaming.deinit();

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = "https://us-central1-aiplatform.googleapis.com/v1/projects/test-project/locations/us-central1/publishers/google",
        .reasoning = true,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };

    try parseSseStreamLines(allocator, &stream_instance, &streaming, model, null);

    try std.testing.expectEqual(types.EventType.start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_delta, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.thinking_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_start, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_delta, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.toolcall_end, stream_instance.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream_instance.next().?.event_type);
    const text_delta = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, text_delta.event_type);
    try std.testing.expectEqualStrings("It is sunny.", text_delta.delta.?);
    try std.testing.expectEqual(types.EventType.text_end, stream_instance.next().?.event_type);
    const done = stream_instance.next().?;
    try std.testing.expectEqual(types.EventType.done, done.event_type);
    try std.testing.expectEqual(types.StopReason.tool_use, done.message.?.stop_reason);
    try std.testing.expectEqualStrings("resp-vertex", done.message.?.response_id.?);
}

test "stream HTTP status error is terminal sanitized event" {
    const allocator = std.heap.page_allocator;
    const io = std.testing.io;

    var body = std.ArrayList(u8).empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"error\":{\"message\":\"vertex denied\",\"x-goog-api-key\":\"AIza-vertex-secret\",\"request_id\":\"req_vertex_random_123456\"},\"trace\":\"/Users/alice/pi/google_vertex.zig\"}");
    try body.appendNTimes(allocator, 'x', 900);

    var server = try provider_error.TestStatusServer.init(io, 403, "Forbidden", "", body.items);
    defer server.deinit();
    try server.start();

    const server_url = try server.url(allocator);
    defer allocator.free(server_url);
    const base_url = try std.fmt.allocPrint(allocator, "{s}/v1/projects/test-project/locations/us-central1/publishers/google", .{server_url});
    defer allocator.free(base_url);

    const model = types.Model{
        .id = "gemini-2.5-pro",
        .name = "Vertex Gemini 2.5 Pro",
        .api = "google-vertex",
        .provider = "google-vertex",
        .base_url = base_url,
        .input_types = &[_][]const u8{"text"},
        .context_window = 1048576,
        .max_tokens = 65535,
    };
    const context = types.Context{
        .messages = &[_]types.Message{
            .{ .user = .{
                .content = &[_]types.ContentBlock{.{ .text = .{ .text = "Hello" } }},
                .timestamp = 1,
            } },
        },
    };

    var stream = try GoogleVertexProvider.stream(allocator, io, model, context, .{ .api_key = "vertex-api-key" });
    defer stream.deinit();

    const event = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, event.event_type);
    try std.testing.expect(event.message != null);
    try std.testing.expectEqualStrings(event.error_message.?, event.message.?.error_message.?);
    try std.testing.expect(std.mem.startsWith(u8, event.error_message.?, "HTTP 403: "));
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "vertex denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "[truncated]") != null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "AIza-vertex-secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "req_vertex_random") == null);
    try std.testing.expect(std.mem.indexOf(u8, event.error_message.?, "/Users/alice") == null);
    try std.testing.expect(stream.next() == null);

    const result = stream.result().?;
    try std.testing.expectEqualStrings(event.message.?.error_message.?, result.error_message.?);
    try std.testing.expectEqual(types.StopReason.error_reason, result.stop_reason);
    try std.testing.expectEqualStrings("google-vertex", result.api);
}

fn runtimePreservationTestModel(api: types.Api, provider: types.Provider) types.Model {
    return .{
        .id = "runtime-test-model",
        .name = "Runtime Test Model",
        .api = api,
        .provider = provider,
        .base_url = "https://example.test",
        .input_types = &[_][]const u8{"text"},
        .context_window = 128000,
        .max_tokens = 4096,
    };
}

test "parseSseStreamLines preserves partial Vertex text before malformed terminal error" {
    const allocator = std.heap.page_allocator;
    const io = std.Io.failing;
    const body = try allocator.dupe(
        u8,
        "data: {\"responseId\":\"vertex-runtime\",\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"partial\"}]}}]}\n" ++
            "data: {not-json}\n" ++
            "data: [DONE]\n",
    );

    var streaming = http_client.StreamingResponse{ .status = 200, .body = body, .buffer = .empty, .allocator = allocator };
    defer streaming.deinit();
    var stream = event_stream.createAssistantMessageEventStream(allocator, io);
    defer stream.deinit();

    try parseSseStreamLines(allocator, &stream, &streaming, runtimePreservationTestModel("google-vertex-generate-content", "google-vertex"), null);

    try std.testing.expectEqual(types.EventType.start, stream.next().?.event_type);
    try std.testing.expectEqual(types.EventType.text_start, stream.next().?.event_type);
    const delta = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_delta, delta.event_type);
    try std.testing.expectEqualStrings("partial", delta.delta.?);
    const text_end = stream.next().?;
    try std.testing.expectEqual(types.EventType.text_end, text_end.event_type);
    try std.testing.expectEqualStrings("partial", text_end.content.?);
    const terminal = stream.next().?;
    try std.testing.expectEqual(types.EventType.error_event, terminal.event_type);
    try std.testing.expect(terminal.message != null);
    try std.testing.expectEqualStrings("vertex-runtime", terminal.message.?.response_id.?);
    try std.testing.expectEqualStrings("partial", terminal.message.?.content[0].text.text);
    try std.testing.expectEqual(types.StopReason.error_reason, terminal.message.?.stop_reason);
    try std.testing.expect(stream.next() == null);
    try std.testing.expectEqualStrings(terminal.message.?.error_message.?, stream.result().?.error_message.?);
}
