const std = @import("std");
const lightpanda = @import("../bridge/lightpanda.zig");
const web_login = @import("../bridge/web_login.zig");
const memory_store = @import("../memory/store.zig");
const time_util = @import("../util/time.zig");

var process_environ: std.process.Environ = std.process.Environ.empty;
const telegram_context_history_limit: usize = 24;
const telegram_context_recall_limit: usize = 6;
const telegram_context_message_max_chars: usize = 1200;
const telegram_completion_max_chars: usize = 12_000;

pub const RuntimeError = error{
    InvalidParamsFrame,
    MissingMessage,
    UnsupportedChannel,
};

pub const ProviderApiKeyResolver = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    provider: []const u8,
) anyerror!?[]u8;

pub const ProviderApiKeySetter = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    provider: []const u8,
    api_key: []const u8,
) anyerror!bool;

pub const ModelCatalogResolver = *const fn (
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    refresh_provider: []const u8,
) anyerror![]TelegramModelDescriptor;

pub fn setEnviron(environ: std.process.Environ) void {
    process_environ = environ;
}

pub const SendResult = struct {
    status: []const u8,
    accepted: bool,
    channel: []u8,
    to: []u8,
    sessionId: []u8,
    command: bool,
    commandName: []u8,
    reply: []u8,
    replySource: []u8,
    providerFailover: bool,
    providerApiKeyUsed: bool,
    provider: []u8,
    model: []u8,
    loginSessionId: []u8,
    loginCode: []u8,
    authStatus: []u8,
    audioAvailable: bool,
    audioFormat: []u8,
    audioBase64: []u8,
    audioBytes: usize,
    audioProviderUsed: []u8,
    audioSource: []u8,
    metadataJson: ?[]u8 = null,
    queueDepth: usize,

    pub fn deinit(self: *SendResult, allocator: std.mem.Allocator) void {
        allocator.free(self.channel);
        allocator.free(self.to);
        allocator.free(self.sessionId);
        allocator.free(self.commandName);
        allocator.free(self.reply);
        allocator.free(self.replySource);
        allocator.free(self.provider);
        allocator.free(self.model);
        allocator.free(self.loginSessionId);
        allocator.free(self.loginCode);
        allocator.free(self.authStatus);
        allocator.free(self.audioFormat);
        allocator.free(self.audioBase64);
        allocator.free(self.audioProviderUsed);
        allocator.free(self.audioSource);
        if (self.metadataJson) |metadata_json| allocator.free(metadata_json);
    }

    pub fn jsonStringify(self: *const SendResult, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("status");
        try jw.write(self.status);
        try jw.objectField("accepted");
        try jw.write(self.accepted);
        try jw.objectField("channel");
        try jw.write(self.channel);
        try jw.objectField("to");
        try jw.write(self.to);
        try jw.objectField("sessionId");
        try jw.write(self.sessionId);
        try jw.objectField("command");
        try jw.write(self.command);
        try jw.objectField("commandName");
        try jw.write(self.commandName);
        try jw.objectField("reply");
        try jw.write(self.reply);
        try jw.objectField("replySource");
        try jw.write(self.replySource);
        try jw.objectField("providerFailover");
        try jw.write(self.providerFailover);
        try jw.objectField("providerApiKeyUsed");
        try jw.write(self.providerApiKeyUsed);
        try jw.objectField("provider");
        try jw.write(self.provider);
        try jw.objectField("model");
        try jw.write(self.model);
        try jw.objectField("loginSessionId");
        try jw.write(self.loginSessionId);
        try jw.objectField("loginCode");
        try jw.write(self.loginCode);
        try jw.objectField("authStatus");
        try jw.write(self.authStatus);
        try jw.objectField("audioAvailable");
        try jw.write(self.audioAvailable);
        try jw.objectField("audioFormat");
        try jw.write(self.audioFormat);
        try jw.objectField("audioBase64");
        try jw.write(self.audioBase64);
        try jw.objectField("audioBytes");
        try jw.write(self.audioBytes);
        try jw.objectField("audioProviderUsed");
        try jw.write(self.audioProviderUsed);
        try jw.objectField("audioSource");
        try jw.write(self.audioSource);
        if (self.metadataJson) |metadata_json| {
            try jw.objectField("metadata");
            try jw.beginWriteRaw();
            defer jw.endWriteRaw();
            try jw.writer.writeAll(metadata_json);
        }
        try jw.objectField("queueDepth");
        try jw.write(self.queueDepth);
        try jw.endObject();
    }
};

const AuthProviderMetadataEntry = struct {
    id: []const u8,
    providerId: []const u8,
    name: []const u8,
    displayName: []const u8,
    aliases: []const []const u8,
    verificationUrl: []const u8,
    verificationUri: []const u8,
    supportsBrowserSession: bool,
    apiKeyConfigured: bool,
    authMode: []const u8,
    defaultModel: []const u8,
    guestBypassSupported: bool,
    popupBypassAction: []const u8,
    guestBypassHint: []const u8,
};

const AuthBridgeMetadata = struct {
    enabled: bool,
    status: []const u8,
    endpoint: []const u8,
    reachable: bool,
    httpStatus: u16,
    probeUrl: []const u8,
    statusCode: u16,
    latencyMs: i64,
    @"error": []const u8,
    sessions: web_login.SummaryView,
    guidance: []const u8,
};

const AuthCommandMetadata = struct {
    type: []const u8,
    target: []const u8,
    provider: ?[]const u8 = null,
    account: ?[]const u8 = null,
    scope: ?[]const u8 = null,
    resolvedScope: ?[]const u8 = null,
    status: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
    loginSessionId: ?[]const u8 = null,
    code: ?[]const u8 = null,
    expiresAt: ?[]const u8 = null,
    verificationUri: ?[]const u8 = null,
    verificationUriComplete: ?[]const u8 = null,
    model: ?[]const u8 = null,
    force: ?bool = null,
    timeoutSeconds: ?u32 = null,
    expiresInSeconds: ?u32 = null,
    revoked: ?bool = null,
    providers: ?[]const AuthProviderMetadataEntry = null,
    bridge: ?AuthBridgeMetadata = null,
    login: ?web_login.SessionView = null,
};

const ModelCommandMetadata = struct {
    type: []const u8,
    target: []const u8,
    provider: ?[]const u8 = null,
    currentProvider: ?[]const u8 = null,
    currentModel: ?[]const u8 = null,
    modelRef: ?[]const u8 = null,
    requestedProvider: ?[]const u8 = null,
    requestedModel: ?[]const u8 = null,
    requested: ?[]const u8 = null,
    aliasUsed: ?[]const u8 = null,
    matchedCatalogModel: ?bool = null,
    customOverride: ?bool = null,
    providers: ?[]const []const u8 = null,
    availableModels: ?[]const []const u8 = null,
    models: ?[]const TelegramModelDescriptor = null,
    @"error": ?[]const u8 = null,
};

const TtsProviderMetadataEntry = struct {
    id: []const u8,
    name: []const u8,
    enabled: bool,
    available: bool,
    requiresAuth: ?bool = null,
    reason: ?[]const u8 = null,
};

const TtsCommandMetadata = struct {
    type: []const u8,
    target: []const u8,
    action: ?[]const u8 = null,
    enabled: ?bool = null,
    provider: ?[]const u8 = null,
    available: ?bool = null,
    reason: ?[]const u8 = null,
    providers: ?[]const TtsProviderMetadataEntry = null,
    text: ?[]const u8 = null,
    audioRef: ?[]const u8 = null,
    bytes: ?usize = null,
    outputFormat: ?[]const u8 = null,
    realAudio: ?bool = null,
    fallback: ?bool = null,
    engine: ?[]const u8 = null,
    audioSource: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

const SetCommandMetadata = struct {
    type: []const u8,
    target: []const u8,
    provider: ?[]const u8 = null,
    stored: ?bool = null,
    keyMasked: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const PolledMessage = struct {
    id: u64,
    channel: []u8,
    to: []u8,
    sessionId: []u8,
    role: []u8,
    kind: []u8,
    message: []u8,
    createdAtMs: i64,

    pub fn deinit(self: *PolledMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.channel);
        allocator.free(self.to);
        allocator.free(self.sessionId);
        allocator.free(self.role);
        allocator.free(self.kind);
        allocator.free(self.message);
    }
};

pub const PollResult = struct {
    status: []const u8,
    channel: []u8,
    count: usize,
    remaining: usize,
    updates: []PolledMessage,

    pub fn deinit(self: *PollResult, allocator: std.mem.Allocator) void {
        allocator.free(self.channel);
        for (self.updates) |*entry| entry.deinit(allocator);
        allocator.free(self.updates);
    }
};

pub const StatusView = struct {
    enabled: bool,
    status: []const u8,
    queueDepth: usize,
    targetCount: usize,
    authBindingCount: usize,
};

const QueuedMessage = struct {
    id: u64,
    to: []u8,
    session_id: []u8,
    role: []u8,
    kind: []u8,
    message: []u8,
    created_at_ms: i64,

    fn deinit(self: *QueuedMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.to);
        allocator.free(self.session_id);
        allocator.free(self.role);
        allocator.free(self.kind);
        allocator.free(self.message);
    }
};

const PersistedMapEntry = struct {
    key: []const u8,
    value: []const u8,
};

const PersistedQueuedMessage = struct {
    id: u64,
    to: []const u8,
    sessionId: []const u8,
    role: []const u8,
    kind: []const u8,
    message: []const u8,
    createdAtMs: i64,
};

const PersistedState = struct {
    nextUpdateId: u64 = 1,
    maxQueueEntries: usize = 4096,
    ttsEnabled: bool = true,
    ttsProvider: []const u8 = "edge",
    bridgeEndpoint: []const u8 = "http://127.0.0.1:9222",
    bridgeTimeoutMs: u32 = 15_000,
    targetModels: []PersistedMapEntry = &.{},
    authBindings: []PersistedMapEntry = &.{},
    queue: []PersistedQueuedMessage = &.{},
};

pub const TelegramRuntime = struct {
    allocator: std.mem.Allocator,
    login_manager: *web_login.LoginManager,
    queue: std.ArrayList(QueuedMessage),
    max_queue_entries: usize,
    target_models: std.StringHashMap([]u8),
    auth_bindings: std.StringHashMap([]u8),
    tts_enabled: bool,
    tts_provider: []u8,
    bridge_endpoint: []u8,
    bridge_timeout_ms: u32,
    next_update_id: u64,
    memory_store_ref: ?*memory_store.Store,
    state_path: ?[]u8,
    persistent: bool,
    provider_api_key_resolver_ctx: ?*anyopaque,
    provider_api_key_resolver: ?ProviderApiKeyResolver,
    provider_api_key_setter_ctx: ?*anyopaque,
    provider_api_key_setter: ?ProviderApiKeySetter,
    model_catalog_resolver_ctx: ?*anyopaque,
    model_catalog_resolver: ?ModelCatalogResolver,

    pub fn init(allocator: std.mem.Allocator, login_manager: *web_login.LoginManager) TelegramRuntime {
        return .{
            .allocator = allocator,
            .login_manager = login_manager,
            .queue = .empty,
            .max_queue_entries = 4096,
            .target_models = std.StringHashMap([]u8).init(allocator),
            .auth_bindings = std.StringHashMap([]u8).init(allocator),
            .tts_enabled = true,
            .tts_provider = allocator.dupe(u8, "edge") catch @panic("oom"),
            .bridge_endpoint = allocator.dupe(u8, "http://127.0.0.1:9222") catch @panic("oom"),
            .bridge_timeout_ms = 15_000,
            .next_update_id = 1,
            .memory_store_ref = null,
            .state_path = null,
            .persistent = false,
            .provider_api_key_resolver_ctx = null,
            .provider_api_key_resolver = null,
            .provider_api_key_setter_ctx = null,
            .provider_api_key_setter = null,
            .model_catalog_resolver_ctx = null,
            .model_catalog_resolver = null,
        };
    }

    pub fn deinit(self: *TelegramRuntime) void {
        for (self.queue.items) |*entry| entry.deinit(self.allocator);
        self.queue.deinit(self.allocator);

        var model_it = self.target_models.iterator();
        while (model_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.target_models.deinit();

        var auth_it = self.auth_bindings.iterator();
        while (auth_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.auth_bindings.deinit();
        self.allocator.free(self.tts_provider);
        self.allocator.free(self.bridge_endpoint);
        if (self.state_path) |path| self.allocator.free(path);
        self.state_path = null;
        self.persistent = false;
    }

    pub fn configurePersistence(self: *TelegramRuntime, state_root: []const u8) !void {
        const resolved = try resolveStatePath(self.allocator, state_root);
        if (self.state_path) |path| self.allocator.free(path);
        self.state_path = resolved;
        self.persistent = shouldPersist(resolved);
        if (!self.persistent) return;

        if (self.queue.items.len == 0 and self.target_models.count() == 0 and self.auth_bindings.count() == 0 and self.next_update_id == 1) {
            try self.load();
        }
    }

    pub fn setBridgeConfig(self: *TelegramRuntime, endpoint_raw: []const u8, timeout_ms: u32) !void {
        const trimmed = std.mem.trim(u8, endpoint_raw, " \t\r\n");
        const resolved_endpoint = if (trimmed.len > 0) trimmed else "http://127.0.0.1:9222";
        if (!std.mem.eql(u8, self.bridge_endpoint, resolved_endpoint)) {
            const copied = try self.allocator.dupe(u8, resolved_endpoint);
            self.allocator.free(self.bridge_endpoint);
            self.bridge_endpoint = copied;
        }
        self.bridge_timeout_ms = std.math.clamp(if (timeout_ms == 0) @as(u32, 15_000) else timeout_ms, @as(u32, 500), @as(u32, 120_000));
        if (self.persistent) try self.persist();
    }

    pub fn setMemoryStore(self: *TelegramRuntime, store: *memory_store.Store) void {
        self.memory_store_ref = store;
    }

    pub fn setProviderApiKeyResolver(
        self: *TelegramRuntime,
        ctx: ?*anyopaque,
        resolver: ?ProviderApiKeyResolver,
    ) void {
        self.provider_api_key_resolver_ctx = ctx;
        self.provider_api_key_resolver = resolver;
    }

    pub fn setProviderApiKeySetter(
        self: *TelegramRuntime,
        ctx: ?*anyopaque,
        setter: ?ProviderApiKeySetter,
    ) void {
        self.provider_api_key_setter_ctx = ctx;
        self.provider_api_key_setter = setter;
    }

    pub fn setModelCatalogResolver(
        self: *TelegramRuntime,
        ctx: ?*anyopaque,
        resolver: ?ModelCatalogResolver,
    ) void {
        self.model_catalog_resolver_ctx = ctx;
        self.model_catalog_resolver = resolver;
    }

    pub fn status(self: *TelegramRuntime) StatusView {
        return .{
            .enabled = true,
            .status = "ready",
            .queueDepth = self.queue.items.len,
            .targetCount = self.target_models.count(),
            .authBindingCount = self.auth_bindings.count(),
        };
    }

    fn resolveModelCatalogAlloc(
        self: *TelegramRuntime,
        allocator: std.mem.Allocator,
        refresh_provider_raw: []const u8,
    ) ![]TelegramModelDescriptor {
        if (self.model_catalog_resolver) |resolver| {
            if (self.model_catalog_resolver_ctx) |ctx| {
                return resolver(ctx, allocator, refresh_provider_raw);
            }
        }
        return allocator.dupe(TelegramModelDescriptor, telegramModelCatalog());
    }

    fn normalizeSendChannelAlias(channel: []const u8) ?[]const u8 {
        const trimmed = std.mem.trim(u8, channel, " \t\r\n");
        if (trimmed.len == 0) return "telegram";
        if (std.ascii.eqlIgnoreCase(trimmed, "telegram") or std.ascii.eqlIgnoreCase(trimmed, "tg") or std.ascii.eqlIgnoreCase(trimmed, "tele")) return "telegram";
        if (std.ascii.eqlIgnoreCase(trimmed, "webchat") or std.ascii.eqlIgnoreCase(trimmed, "web")) return "webchat";
        if (std.ascii.eqlIgnoreCase(trimmed, "cli") or std.ascii.eqlIgnoreCase(trimmed, "console") or std.ascii.eqlIgnoreCase(trimmed, "terminal")) return "cli";
        return null;
    }

    pub fn sendFromFrame(self: *TelegramRuntime, allocator: std.mem.Allocator, frame_json: []const u8) !SendResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame_json, .{});
        defer parsed.deinit();
        const params = try getParamsObject(parsed.value);

        const channel = normalizeSendChannelAlias(getOptionalString(params, "channel", "telegram")) orelse return error.UnsupportedChannel;
        const target = getOptionalString(params, "to", "default");
        const session_id = getOptionalString(params, "sessionId", "tg-chat-default");
        const message = try getRequiredString(params, "message", "text", error.MissingMessage);

        const outcome = try self.handleSendMessage(allocator, target, session_id, std.mem.trim(u8, message, " \t\r\n"));
        defer allocator.free(outcome.reply);
        defer if (outcome.owned_login_session_id) |login_session_id| allocator.free(login_session_id);
        defer if (outcome.audio_base64) |audio| allocator.free(audio);
        defer if (outcome.metadata_json) |metadata_json| allocator.free(metadata_json);
        return self.makeSendResult(allocator, channel, target, session_id, outcome);
    }

    pub fn pollFromFrame(self: *TelegramRuntime, allocator: std.mem.Allocator, frame_json: []const u8) !PollResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame_json, .{});
        defer parsed.deinit();
        const params = try getParamsObject(parsed.value);
        const channel = normalizeSendChannelAlias(getOptionalString(params, "channel", "telegram")) orelse return error.UnsupportedChannel;
        if (!std.mem.eql(u8, channel, "telegram")) return error.UnsupportedChannel;
        const limit = std.math.clamp(getOptionalUsize(params, "limit", 20), 1, 100);

        const count = @min(limit, self.queue.items.len);
        var updates = try allocator.alloc(PolledMessage, count);
        var idx: usize = 0;
        errdefer {
            var cleanup: usize = 0;
            while (cleanup < idx) : (cleanup += 1) updates[cleanup].deinit(allocator);
            allocator.free(updates);
        }

        while (idx < count) : (idx += 1) {
            const entry = self.queue.items[idx];
            updates[idx] = .{
                .id = entry.id,
                .channel = try allocator.dupe(u8, "telegram"),
                .to = try allocator.dupe(u8, entry.to),
                .sessionId = try allocator.dupe(u8, entry.session_id),
                .role = try allocator.dupe(u8, entry.role),
                .kind = try allocator.dupe(u8, entry.kind),
                .message = try allocator.dupe(u8, entry.message),
                .createdAtMs = entry.created_at_ms,
            };
        }
        self.compactQueueFront(count);

        return .{
            .status = "ok",
            .channel = try allocator.dupe(u8, "telegram"),
            .count = count,
            .remaining = self.queue.items.len,
            .updates = updates,
        };
    }

    fn compactQueueFront(self: *TelegramRuntime, count: usize) void {
        if (count == 0 or self.queue.items.len == 0) return;
        const to_remove = @min(count, self.queue.items.len);
        for (self.queue.items[0..to_remove]) |*entry| entry.deinit(self.allocator);
        const remaining = self.queue.items.len - to_remove;
        if (remaining > 0) {
            std.mem.copyForwards(QueuedMessage, self.queue.items[0..remaining], self.queue.items[to_remove..]);
        }
        self.queue.items.len = remaining;
        if (self.persistent) self.persist() catch {};
    }

    const SendOutcome = struct {
        is_command: bool,
        command_name: []const u8,
        reply: []u8,
        provider: []const u8,
        model: []const u8,
        login_session_id: []const u8,
        owned_login_session_id: ?[]u8 = null,
        login_code: []const u8,
        auth_status: []const u8,
        bridge_used: bool = false,
        provider_failover: bool = false,
        provider_api_key_used: bool = false,
        audio_base64: ?[]u8 = null,
        audio_format: []const u8 = "",
        audio_bytes: usize = 0,
        audio_provider_used: []const u8 = "",
        audio_source: []const u8 = "",
        metadata_json: ?[]u8 = null,
    };

    fn handleSendMessage(
        self: *TelegramRuntime,
        allocator: std.mem.Allocator,
        target: []const u8,
        session_id: []const u8,
        message: []const u8,
    ) !SendOutcome {
        if (message.len > 0 and message[0] == '/') {
            const command = try self.handleCommand(allocator, target, message);
            if (command.audio_base64) |audio_base64| {
                const audio_payload = try std.fmt.allocPrint(
                    allocator,
                    "{{\"format\":\"{s}\",\"providerUsed\":\"{s}\",\"source\":\"{s}\",\"audioBytes\":{d},\"audioBase64\":\"{s}\"}}",
                    .{ command.audio_format, command.audio_provider_used, command.audio_source, command.audio_bytes, audio_base64 },
                );
                defer allocator.free(audio_payload);
                try self.enqueue(target, session_id, "assistant", "audio_clip", audio_payload);
            }
            try self.enqueue(target, session_id, "assistant", "command_reply", command.reply);
            return command;
        }

        const model_sel = self.getTargetModel(target);
        const provider = model_sel.provider;
        const model = model_sel.model;
        var login_session: []const u8 = "";
        var response_provider: []const u8 = provider;
        var response_model: []const u8 = model;
        var provider_failover = false;
        var provider_api_key_used = false;
        var auth_status: []const u8 = "pending";
        var authorized = false;
        var bound_session = try self.getAuthBinding(allocator, target, provider, "default");
        if (bound_session.len == 0) {
            bound_session = try self.getAnyAuthBindingForProvider(allocator, target, provider);
        }
        if (bound_session.len > 0) {
            const session = bound_session;
            login_session = session;
            if (self.login_manager.get(session)) |view| {
                auth_status = view.status;
                authorized = std.ascii.eqlIgnoreCase(view.status, "authorized");
            }
        }

        const has_any_authorized = self.login_manager.latestAuthorizedSession("") != null;
        const has_provider_api_key = providerApiKeyConfigured(self, allocator, provider);
        if (!authorized and (has_any_authorized or has_provider_api_key)) {
            auth_status = "authorized";
        }
        var bridge_used = false;
        const reply = blk: {
            if (authorized or has_any_authorized or has_provider_api_key) {
                if (try self.tryGenerateBridgeReply(allocator, provider, model, login_session, session_id, message)) |generated| {
                    bridge_used = true;
                    provider_failover = generated.failover;
                    provider_api_key_used = generated.used_api_key;
                    response_provider = generated.provider;
                    response_model = generated.model;
                    login_session = generated.login_session_id;
                    auth_status = "authorized";
                    authorized = true;
                    break :blk generated.text;
                }
                break :blk try std.fmt.allocPrint(allocator, "OpenClaw Zig ({s}/{s}) assistant: {s}", .{ provider, model, message });
            }
            if (web_login.supportsGuestBypass(provider)) {
                break :blk try std.fmt.allocPrint(allocator, "Auth required for `{s}/{s}`. Run `/auth start {s}`, choose 'Stay logged out' in browser popup, then run `/auth guest {s}` (or `/auth complete {s} guest`).", .{ provider, model, provider, provider, provider });
            }
            break :blk try std.fmt.allocPrint(allocator, "Auth required for `{s}/{s}`. Run `/auth start {s}` then `/auth complete {s} <code_or_url>`.", .{ provider, model, provider, provider });
        };

        const provider_used = normalizeTtsProvider(self.tts_provider);
        var audio_base64: ?[]u8 = null;
        var audio_format: []const u8 = "";
        var audio_bytes: usize = 0;
        var audio_source: []const u8 = "";
        if (authorized and self.tts_enabled and std.mem.trim(u8, reply, " \t\r\n").len > 0) {
            audio_source = resolveTtsSource(allocator, provider_used);
            audio_base64 = try synthesizeTelegramTtsClipBase64(
                allocator,
                std.mem.trim(u8, reply, " \t\r\n"),
                provider_used,
                audio_source,
            );
            audio_format = "wav";
            audio_bytes = base64DecodedLen(audio_base64.?);
            const audio_payload = try std.fmt.allocPrint(
                allocator,
                "{{\"format\":\"{s}\",\"providerUsed\":\"{s}\",\"source\":\"{s}\",\"audioBytes\":{d},\"audioBase64\":\"{s}\"}}",
                .{ audio_format, provider_used, audio_source, audio_bytes, audio_base64.? },
            );
            defer allocator.free(audio_payload);
            try self.enqueue(target, session_id, "assistant", "audio_clip", audio_payload);
        }

        try self.enqueue(target, session_id, "assistant", "assistant_reply", reply);
        return .{
            .is_command = false,
            .command_name = "",
            .reply = reply,
            .provider = response_provider,
            .model = response_model,
            .login_session_id = login_session,
            .login_code = "",
            .auth_status = if (authorized) "authorized" else auth_status,
            .bridge_used = bridge_used,
            .provider_failover = provider_failover,
            .provider_api_key_used = provider_api_key_used,
            .audio_base64 = audio_base64,
            .audio_format = audio_format,
            .audio_bytes = audio_bytes,
            .audio_provider_used = if (audio_base64 != null) provider_used else "",
            .audio_source = if (audio_base64 != null) audio_source else "",
        };
    }

    fn makeSendResult(
        self: *TelegramRuntime,
        allocator: std.mem.Allocator,
        channel: []const u8,
        target: []const u8,
        session_id: []const u8,
        outcome: SendOutcome,
    ) !SendResult {
        const reply_source = if (outcome.is_command)
            "command"
        else if (std.ascii.eqlIgnoreCase(outcome.auth_status, "authorized"))
            if (outcome.bridge_used) "bridge_completion" else "runtime_echo"
        else
            "auth_required";
        return .{
            .status = "accepted",
            .accepted = true,
            .channel = try allocator.dupe(u8, channel),
            .to = try allocator.dupe(u8, target),
            .sessionId = try allocator.dupe(u8, session_id),
            .command = outcome.is_command,
            .commandName = try allocator.dupe(u8, outcome.command_name),
            .reply = try allocator.dupe(u8, outcome.reply),
            .replySource = try allocator.dupe(u8, reply_source),
            .providerFailover = outcome.provider_failover,
            .providerApiKeyUsed = outcome.provider_api_key_used,
            .provider = try allocator.dupe(u8, outcome.provider),
            .model = try allocator.dupe(u8, outcome.model),
            .loginSessionId = try allocator.dupe(u8, outcome.login_session_id),
            .loginCode = try allocator.dupe(u8, outcome.login_code),
            .authStatus = try allocator.dupe(u8, outcome.auth_status),
            .audioAvailable = outcome.audio_base64 != null,
            .audioFormat = try allocator.dupe(u8, outcome.audio_format),
            .audioBase64 = if (outcome.audio_base64) |audio| try allocator.dupe(u8, audio) else try allocator.dupe(u8, ""),
            .audioBytes = outcome.audio_bytes,
            .audioProviderUsed = try allocator.dupe(u8, outcome.audio_provider_used),
            .audioSource = try allocator.dupe(u8, outcome.audio_source),
            .metadataJson = if (outcome.metadata_json) |metadata_json| try allocator.dupe(u8, metadata_json) else null,
            .queueDepth = self.queue.items.len,
        };
    }

    const CompletionAttempt = struct {
        provider: []const u8,
        model: []const u8,
        login_session_id: []const u8,
        api_key: []u8,
        reason: []const u8,
    };

    const BridgeReply = struct {
        text: []u8,
        provider: []const u8,
        model: []const u8,
        login_session_id: []const u8,
        failover: bool,
        used_api_key: bool,
    };

    fn tryGenerateBridgeReply(
        self: *TelegramRuntime,
        allocator: std.mem.Allocator,
        provider: []const u8,
        model: []const u8,
        login_session_id: []const u8,
        session_id: []const u8,
        message: []const u8,
    ) !?BridgeReply {
        const trimmed_message = std.mem.trim(u8, message, " \t\r\n");
        if (trimmed_message.len == 0) return null;

        const normalized_provider = normalizeProvider(provider);
        const normalized_model = if (normalizeModel(model).len > 0) normalizeModel(model) else defaultModelForProvider(normalized_provider);
        const completion = lightpanda.complete("lightpanda", normalized_provider, normalized_model, "") catch return null;

        var completion_messages: std.ArrayList(lightpanda.CompletionMessage) = .empty;
        defer {
            for (completion_messages.items) |entry| {
                allocator.free(entry.role);
                allocator.free(entry.content);
            }
            completion_messages.deinit(allocator);
        }

        try appendCompletionMessage(
            allocator,
            &completion_messages,
            "system",
            "You are OpenClaw Zig running in Telegram with runtime tool capabilities. Do not claim there are no tools or no memory unless context explicitly indicates a failure. Tools include: tools.catalog, exec.run, file.read, file.write, send, poll, sessions.history, chat.history, doctor.memory.status, tts.convert, web.login.start, web.login.wait, web.login.complete, web.login.status.",
        );

        if (self.memory_store_ref) |store| {
            if (store.recallSynthesis(allocator, trimmed_message, telegram_context_recall_limit)) |recall| {
                defer {
                    var recall_mut = recall;
                    recall_mut.deinit(allocator);
                }
                if (recall.countSemantic > 0 or recall.countNeighbors > 0) {
                    const recall_context = try buildTelegramRecallContextMessage(allocator, recall);
                    defer allocator.free(recall_context);
                    if (std.mem.trim(u8, recall_context, " \t\r\n").len > 0) {
                        try appendCompletionMessage(allocator, &completion_messages, "system", recall_context);
                    }
                }
            } else |_| {}

            if (store.historyBySession(allocator, session_id, telegram_context_history_limit)) |history| {
                defer {
                    var history_mut = history;
                    history_mut.deinit(allocator);
                }
                for (history.items) |entry| {
                    const role = std.mem.trim(u8, entry.role, " \t\r\n");
                    const content = trimPromptText(entry.text, telegram_context_message_max_chars);
                    if (!isAllowedCompletionRole(role) or content.len == 0) continue;
                    try appendCompletionMessage(allocator, &completion_messages, role, content);
                }
            } else |_| {}
        }

        if (!completionMessagesEndWithUser(completion_messages.items, trimmed_message)) {
            try appendCompletionMessage(allocator, &completion_messages, "user", trimmed_message);
        }
        try trimCompletionMessagesToBudget(allocator, &completion_messages, telegram_completion_max_chars);

        var attempts: std.ArrayList(CompletionAttempt) = .empty;
        defer attempts.deinit(allocator);

        try attempts.append(allocator, .{
            .provider = completion.provider,
            .model = completion.model,
            .login_session_id = std.mem.trim(u8, login_session_id, " \t\r\n"),
            .api_key = if (try resolveProviderApiKey(self, allocator, completion.provider)) |value| value else try allocator.dupe(u8, ""),
            .reason = "selected",
        });

        if (self.login_manager.latestAuthorizedSession("")) |latest| {
            const fallback_provider = normalizeProvider(latest.provider);
            const fallback_model = if (normalizeModel(latest.model).len > 0) normalizeModel(latest.model) else defaultModelForProvider(fallback_provider);
            const fallback_login = std.mem.trim(u8, latest.loginSessionId, " \t\r\n");
            const selected_login = std.mem.trim(u8, login_session_id, " \t\r\n");
            const selected_api_key = attempts.items[0].api_key;
            const fallback_api_key = if (try resolveProviderApiKey(self, allocator, fallback_provider)) |value| value else try allocator.dupe(u8, "");
            const duplicate = std.ascii.eqlIgnoreCase(fallback_provider, completion.provider) and
                std.mem.eql(u8, fallback_model, completion.model) and
                std.mem.eql(u8, fallback_login, selected_login) and
                std.mem.eql(u8, fallback_api_key, selected_api_key);
            if (!duplicate and (fallback_login.len > 0 or std.mem.trim(u8, fallback_api_key, " \t\r\n").len > 0)) {
                try attempts.append(allocator, .{
                    .provider = fallback_provider,
                    .model = fallback_model,
                    .login_session_id = fallback_login,
                    .api_key = fallback_api_key,
                    .reason = "latest-authorized-fallback",
                });
            } else {
                allocator.free(fallback_api_key);
            }
        }
        defer {
            for (attempts.items) |attempt| allocator.free(attempt.api_key);
        }

        for (attempts.items, 0..) |attempt, idx| {
            _ = attempt.reason;
            const attempt_login = std.mem.trim(u8, attempt.login_session_id, " \t\r\n");
            const attempt_api_key = std.mem.trim(u8, attempt.api_key, " \t\r\n");
            if (attempt_login.len == 0 and attempt_api_key.len == 0) continue;

            var execution = lightpanda.executeCompletion(
                allocator,
                self.bridge_endpoint,
                self.bridge_timeout_ms,
                attempt.provider,
                attempt.model,
                completion_messages.items,
                null,
                null,
                attempt_login,
                attempt_api_key,
            ) catch continue;
            defer execution.deinit(allocator);

            if (!execution.ok) continue;
            const assistant_text = std.mem.trim(u8, execution.assistantText, " \t\r\n");
            if (assistant_text.len == 0) continue;
            return .{
                .text = try allocator.dupe(u8, assistant_text),
                .provider = attempt.provider,
                .model = attempt.model,
                .login_session_id = attempt_login,
                .failover = idx > 0,
                .used_api_key = attempt_api_key.len > 0,
            };
        }
        return null;
    }

    fn appendCompletionMessage(
        allocator: std.mem.Allocator,
        completion_messages: *std.ArrayList(lightpanda.CompletionMessage),
        role_raw: []const u8,
        content_raw: []const u8,
    ) !void {
        const role = std.mem.trim(u8, role_raw, " \t\r\n");
        const content = std.mem.trim(u8, content_raw, " \t\r\n");
        if (role.len == 0 or content.len == 0) return;
        const role_copy = try allocator.dupe(u8, role);
        errdefer allocator.free(role_copy);
        const content_copy = try allocator.dupe(u8, content);
        errdefer allocator.free(content_copy);
        try completion_messages.append(allocator, .{
            .role = role_copy,
            .content = content_copy,
        });
    }

    fn isAllowedCompletionRole(role_raw: []const u8) bool {
        const role = std.mem.trim(u8, role_raw, " \t\r\n");
        if (role.len == 0) return false;
        return std.ascii.eqlIgnoreCase(role, "user") or
            std.ascii.eqlIgnoreCase(role, "assistant") or
            std.ascii.eqlIgnoreCase(role, "system") or
            std.ascii.eqlIgnoreCase(role, "tool");
    }

    fn trimPromptText(text_raw: []const u8, limit: usize) []const u8 {
        const text = std.mem.trim(u8, text_raw, " \t\r\n");
        if (text.len == 0 or limit == 0 or text.len <= limit) return text;
        return text[0..limit];
    }

    fn completionMessagesEndWithUser(messages: []const lightpanda.CompletionMessage, user_message_raw: []const u8) bool {
        if (messages.len == 0) return false;
        const last = messages[messages.len - 1];
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, last.role, " \t\r\n"), "user")) return false;
        const last_content = std.mem.trim(u8, last.content, " \t\r\n");
        const user_message = std.mem.trim(u8, user_message_raw, " \t\r\n");
        return std.mem.eql(u8, last_content, user_message);
    }

    fn completionMessageChars(entry: lightpanda.CompletionMessage) usize {
        return std.mem.trim(u8, entry.content, " \t\r\n").len;
    }

    fn completionMessagesTotalChars(messages: []const lightpanda.CompletionMessage) usize {
        var total: usize = 0;
        for (messages) |entry| total += completionMessageChars(entry);
        return total;
    }

    fn trimCompletionMessagesToBudget(
        allocator: std.mem.Allocator,
        completion_messages: *std.ArrayList(lightpanda.CompletionMessage),
        max_chars: usize,
    ) !void {
        if (max_chars == 0 or completion_messages.items.len <= 1) return;

        var total = completionMessagesTotalChars(completion_messages.items);
        if (total <= max_chars) return;

        while (total > max_chars and completion_messages.items.len > 2) {
            const removed = completion_messages.orderedRemove(1);
            total -= completionMessageChars(removed);
            allocator.free(removed.role);
            allocator.free(removed.content);
        }

        if (completion_messages.items.len <= 1) return;
        if (total <= max_chars) return;

        const system_chars = completionMessageChars(completion_messages.items[0]);
        if (system_chars >= max_chars) {
            while (completion_messages.items.len > 1) {
                const removed = completion_messages.pop().?;
                allocator.free(removed.role);
                allocator.free(removed.content);
            }
            return;
        }

        const keep_chars = max_chars - system_chars;
        if (keep_chars == 0) {
            while (completion_messages.items.len > 1) {
                const removed = completion_messages.pop().?;
                allocator.free(removed.role);
                allocator.free(removed.content);
            }
            return;
        }

        const last_idx = completion_messages.items.len - 1;
        const last = completion_messages.items[last_idx];
        const trimmed = std.mem.trim(u8, last.content, " \t\r\n");
        if (trimmed.len <= keep_chars) return;

        const truncated = trimmed[0..keep_chars];
        const replacement = try allocator.dupe(u8, truncated);
        allocator.free(completion_messages.items[last_idx].content);
        completion_messages.items[last_idx].content = replacement;
    }

    fn buildTelegramRecallContextMessage(
        allocator: std.mem.Allocator,
        recall: memory_store.RecallSynthesis,
    ) ![]u8 {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        const query = std.mem.trim(u8, recall.query, " \t\r\n");
        if (query.len > 0) {
            const query_line = try std.fmt.allocPrint(allocator, "Long-term memory recall query: {s}\n", .{trimPromptText(query, 320)});
            defer allocator.free(query_line);
            try out.appendSlice(allocator, query_line);
        }

        if (recall.semantic.items.len > 0) {
            try out.appendSlice(allocator, "Semantic recall hits:\n");
            for (recall.semantic.items, 0..) |entry, idx| {
                if (idx >= telegram_context_recall_limit) break;
                const role = if (std.mem.trim(u8, entry.role, " \t\r\n").len > 0) entry.role else "memory";
                const snippet = trimPromptText(entry.text, 220);
                if (snippet.len == 0) continue;
                const line = try std.fmt.allocPrint(allocator, "- semantic[{d}] ({s}): {s}\n", .{ idx + 1, role, snippet });
                defer allocator.free(line);
                try out.appendSlice(allocator, line);
            }
        }

        if (recall.neighbors.items.len > 0) {
            try out.appendSlice(allocator, "Graph neighbors:\n");
            for (recall.neighbors.items, 0..) |edge, idx| {
                if (idx >= telegram_context_recall_limit) break;
                const line = try std.fmt.allocPrint(allocator, "- graph[{d}]: {s} -> {s} ({d})\n", .{ idx + 1, edge.from, edge.to, edge.weight });
                defer allocator.free(line);
                try out.appendSlice(allocator, line);
            }
        }

        return out.toOwnedSlice(allocator);
    }

    fn handleCommand(
        self: *TelegramRuntime,
        allocator: std.mem.Allocator,
        target: []const u8,
        raw_message: []const u8,
    ) !SendOutcome {
        var tokens = std.ArrayList([]const u8).empty;
        defer tokens.deinit(allocator);
        var it = std.mem.tokenizeAny(u8, raw_message, " \t\r\n");
        while (it.next()) |token| try tokens.append(allocator, token);
        if (tokens.items.len == 0) {
            return .{ .is_command = true, .command_name = "help", .reply = try allocator.dupe(u8, "Commands: /model, /auth, /set, /tts, /start, /help"), .provider = "chatgpt", .model = "gpt-5.2", .login_session_id = "", .login_code = "", .auth_status = "ok" };
        }

        var command = tokens.items[0];
        if (command.len > 0 and command[0] == '/') command = command[1..];
        if (std.mem.indexOfScalar(u8, command, '@')) |at| command = command[0..at];

        const args = if (tokens.items.len > 1) tokens.items[1..] else &[_][]const u8{};
        if (std.ascii.eqlIgnoreCase(command, "help") or std.ascii.eqlIgnoreCase(command, "start")) {
            return .{
                .is_command = true,
                .command_name = "help",
                .reply = try allocator.dupe(u8, "Commands: /model, /auth, /set, /tts, /start, /help"),
                .provider = self.getTargetModel(target).provider,
                .model = self.getTargetModel(target).model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }
        if (std.ascii.eqlIgnoreCase(command, "model")) {
            return self.handleModelCommand(allocator, target, args);
        }
        if (std.ascii.eqlIgnoreCase(command, "auth")) {
            return self.handleAuthCommand(allocator, target, args);
        }
        if (std.ascii.eqlIgnoreCase(command, "set")) {
            return self.handleSetCommand(allocator, target, args);
        }
        if (std.ascii.eqlIgnoreCase(command, "tts")) {
            return self.handleTtsCommand(allocator, target, args);
        }
        return .{
            .is_command = true,
            .command_name = "unknown",
            .reply = try std.fmt.allocPrint(allocator, "Unknown command `{s}`. Supported: /model, /auth, /set, /tts, /start, /help", .{command}),
            .provider = self.getTargetModel(target).provider,
            .model = self.getTargetModel(target).model,
            .login_session_id = "",
            .login_code = "",
            .auth_status = "ok",
        };
    }

    fn authInvalidOutcome(
        self: *TelegramRuntime,
        allocator: std.mem.Allocator,
        trimmed_target: []const u8,
        action_type: []const u8,
        provider: []const u8,
        account_raw: []const u8,
        reply: []u8,
        error_code: []const u8,
        auth_status: []const u8,
        login_session_id: []const u8,
        timeout_seconds: ?u32,
    ) !SendOutcome {
        _ = self;
        const account_norm = normalizeAccount(account_raw);
        const scope = try authScopeAlloc(allocator, provider, account_norm);
        defer allocator.free(scope);
        const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
            .type = action_type,
            .target = trimmed_target,
            .provider = provider,
            .account = account_norm,
            .scope = scope,
            .status = auth_status,
            .@"error" = error_code,
            .loginSessionId = if (std.mem.trim(u8, login_session_id, " \t\r\n").len > 0) login_session_id else null,
            .timeoutSeconds = timeout_seconds,
        });
        return .{
            .is_command = true,
            .command_name = "auth",
            .reply = reply,
            .provider = provider,
            .model = defaultModelForProvider(provider),
            .login_session_id = login_session_id,
            .login_code = "",
            .auth_status = auth_status,
            .metadata_json = metadata_json,
        };
    }

    fn handleSetCommand(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, args: []const []const u8) !SendOutcome {
        const model_sel = self.getTargetModel(target);
        const trimmed_target = std.mem.trim(u8, target, " \t\r\n");

        if (args.len < 4 or !std.ascii.eqlIgnoreCase(args[0], "api") or !std.ascii.eqlIgnoreCase(args[1], "key")) {
            const metadata_json = try stringifyJsonAlloc(allocator, SetCommandMetadata{
                .type = "set.invalid",
                .target = trimmed_target,
            });
            return .{
                .is_command = true,
                .command_name = "set",
                .reply = try allocator.dupe(u8, "Usage: `/set api key <provider> <key>`"),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "invalid",
                .metadata_json = metadata_json,
            };
        }

        const requested_provider = std.mem.trim(u8, args[2], " \t\r\n");
        const api_key_joined = try std.mem.join(allocator, " ", args[3..]);
        defer allocator.free(api_key_joined);
        const api_key = std.mem.trim(u8, api_key_joined, " \t\r\n");
        if (requested_provider.len == 0 or api_key.len == 0) {
            const metadata_json = try stringifyJsonAlloc(allocator, SetCommandMetadata{
                .type = "set.invalid",
                .target = trimmed_target,
                .@"error" = "missing_provider_or_key",
            });
            return .{
                .is_command = true,
                .command_name = "set",
                .reply = try allocator.dupe(u8, "Usage: `/set api key <provider> <key>`"),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "invalid",
                .metadata_json = metadata_json,
            };
        }

        if (std.mem.indexOfScalar(u8, api_key, '\n') != null or std.mem.indexOfScalar(u8, api_key, '\r') != null) {
            const provider = normalizeProvider(requested_provider);
            const metadata_json = try stringifyJsonAlloc(allocator, SetCommandMetadata{
                .type = "set.api_key",
                .target = trimmed_target,
                .provider = provider,
                .@"error" = "invalid_key_format",
            });
            return .{
                .is_command = true,
                .command_name = "set",
                .reply = try allocator.dupe(u8, "API key must be a single line."),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "invalid",
                .metadata_json = metadata_json,
            };
        }

        const provider = normalizeProvider(requested_provider);
        const setter = self.provider_api_key_setter orelse {
            const metadata_json = try stringifyJsonAlloc(allocator, SetCommandMetadata{
                .type = "set.api_key",
                .target = trimmed_target,
                .provider = provider,
                .@"error" = "store_failed",
            });
            return .{
                .is_command = true,
                .command_name = "set",
                .reply = try allocator.dupe(u8, "Failed to store API key."),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "invalid",
                .metadata_json = metadata_json,
            };
        };
        const setter_ctx = self.provider_api_key_setter_ctx orelse {
            const metadata_json = try stringifyJsonAlloc(allocator, SetCommandMetadata{
                .type = "set.api_key",
                .target = trimmed_target,
                .provider = provider,
                .@"error" = "store_failed",
            });
            return .{
                .is_command = true,
                .command_name = "set",
                .reply = try allocator.dupe(u8, "Failed to store API key."),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "invalid",
                .metadata_json = metadata_json,
            };
        };
        const stored = try setter(setter_ctx, allocator, provider, api_key);
        if (!stored) {
            const metadata_json = try stringifyJsonAlloc(allocator, SetCommandMetadata{
                .type = "set.api_key",
                .target = trimmed_target,
                .provider = provider,
                .@"error" = "store_failed",
            });
            return .{
                .is_command = true,
                .command_name = "set",
                .reply = try allocator.dupe(u8, "Failed to store API key."),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "invalid",
                .metadata_json = metadata_json,
            };
        }

        const key_masked = try maskSecretAlloc(allocator, api_key);
        defer allocator.free(key_masked);
        const metadata_json = try stringifyJsonAlloc(allocator, SetCommandMetadata{
            .type = "set.api_key",
            .target = trimmed_target,
            .provider = provider,
            .stored = true,
            .keyMasked = key_masked,
        });
        return .{
            .is_command = true,
            .command_name = "set",
            .reply = try std.fmt.allocPrint(allocator, "Provider API key saved for `{s}`. You can now set a model with `/model {s}/<model>`.", .{ provider, provider }),
            .provider = provider,
            .model = model_sel.model,
            .login_session_id = "",
            .login_code = "",
            .auth_status = "ok",
            .metadata_json = metadata_json,
        };
    }

    fn handleModelCommand(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, args: []const []const u8) !SendOutcome {
        const model_sel = self.getTargetModel(target);
        const trimmed_target = std.mem.trim(u8, target, " \t\r\n");
        const action = if (args.len == 0) "status" else args[0];

        if (std.ascii.eqlIgnoreCase(action, "status")) {
            const catalog = try self.resolveModelCatalogAlloc(allocator, model_sel.provider);
            defer allocator.free(catalog);
            const providers = try listTelegramModelProvidersFromCatalogAlloc(allocator, catalog);
            defer allocator.free(providers);
            const available_models = try listTelegramModelIDsFromCatalogAlloc(allocator, catalog, "");
            defer allocator.free(available_models);
            const descriptors = try listTelegramModelDescriptorsFromCatalogAlloc(allocator, catalog, "");
            defer allocator.free(descriptors);
            const providers_text = try std.mem.join(allocator, ", ", providers);
            defer allocator.free(providers_text);
            const model_ref = try modelRefForDisplayAlloc(allocator, model_sel.provider, model_sel.model);
            defer allocator.free(model_ref);
            const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                .type = "model.status",
                .target = trimmed_target,
                .currentProvider = model_sel.provider,
                .currentModel = model_sel.model,
                .modelRef = model_ref,
                .providers = providers,
                .availableModels = available_models,
                .models = descriptors,
            });
            return .{
                .is_command = true,
                .command_name = "model",
                .reply = try std.fmt.allocPrint(allocator, "Current model: `{s}/{s}`\nAvailable providers: {s}", .{ model_sel.provider, model_sel.model, providers_text }),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "list")) {
            const refresh_provider = if (args.len >= 2) normalizeProvider(args[1]) else model_sel.provider;
            const catalog = try self.resolveModelCatalogAlloc(allocator, refresh_provider);
            defer allocator.free(catalog);
            const providers = try listTelegramModelProvidersFromCatalogAlloc(allocator, catalog);
            defer allocator.free(providers);
            if (args.len < 2) {
                const available_models = try listTelegramModelIDsFromCatalogAlloc(allocator, catalog, "");
                defer allocator.free(available_models);
                const descriptors = try listTelegramModelDescriptorsFromCatalogAlloc(allocator, catalog, "");
                defer allocator.free(descriptors);
                const providers_text = try std.mem.join(allocator, ", ", providers);
                defer allocator.free(providers_text);
                const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                    .type = "model.list",
                    .target = trimmed_target,
                    .providers = providers,
                    .availableModels = available_models,
                    .models = descriptors,
                });
                return .{
                    .is_command = true,
                    .command_name = "model",
                    .reply = try std.fmt.allocPrint(allocator, "Providers: {s}\nUse `/model list <provider>` for full model IDs.", .{providers_text}),
                    .provider = model_sel.provider,
                    .model = model_sel.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "ok",
                    .metadata_json = metadata_json,
                };
            }

            const requested_provider = normalizeProvider(args[1]);
            const filtered = try listTelegramModelIDsFromCatalogAlloc(allocator, catalog, requested_provider);
            defer allocator.free(filtered);
            const descriptors = try listTelegramModelDescriptorsFromCatalogAlloc(allocator, catalog, requested_provider);
            defer allocator.free(descriptors);
            const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                .type = "model.list",
                .target = trimmed_target,
                .requestedProvider = requested_provider,
                .providers = providers,
                .availableModels = filtered,
                .models = descriptors,
            });
            if (filtered.len == 0) {
                return .{
                    .is_command = true,
                    .command_name = "model",
                    .reply = try std.fmt.allocPrint(allocator, "No models found for provider `{s}`.", .{requested_provider}),
                    .provider = model_sel.provider,
                    .model = model_sel.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "invalid",
                    .metadata_json = metadata_json,
                };
            }

            const filtered_text = try std.mem.join(allocator, ", ", filtered);
            defer allocator.free(filtered_text);
            return .{
                .is_command = true,
                .command_name = "model",
                .reply = try std.fmt.allocPrint(allocator, "Models for `{s}`: {s}", .{ requested_provider, filtered_text }),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "next")) {
            const catalog = try self.resolveModelCatalogAlloc(allocator, model_sel.provider);
            defer allocator.free(catalog);
            const next_choice = nextTelegramModelChoiceInCatalog(catalog, model_sel.model);
            try self.setTargetModel(target, next_choice.provider, next_choice.id);
            const model_ref = try modelRefForDisplayAlloc(allocator, next_choice.provider, next_choice.id);
            defer allocator.free(model_ref);
            const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                .type = "model.next",
                .target = trimmed_target,
                .provider = next_choice.provider,
                .currentProvider = next_choice.provider,
                .currentModel = next_choice.id,
                .modelRef = model_ref,
            });
            return .{
                .is_command = true,
                .command_name = "model",
                .reply = try std.fmt.allocPrint(allocator, "Model advanced to `{s}` for `{s}`.", .{ model_ref, trimmed_target }),
                .provider = next_choice.provider,
                .model = next_choice.id,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "reset")) {
            const model_ref = try modelRefForDisplayAlloc(allocator, "chatgpt", "gpt-5.2");
            defer allocator.free(model_ref);
            const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                .type = "model.reset",
                .target = trimmed_target,
                .provider = "chatgpt",
                .currentProvider = "chatgpt",
                .currentModel = "gpt-5.2",
                .modelRef = model_ref,
            });
            try self.setTargetModel(target, "chatgpt", "gpt-5.2");
            return .{
                .is_command = true,
                .command_name = "model",
                .reply = try std.fmt.allocPrint(allocator, "Model reset to `chatgpt/gpt-5.2` for `{s}`.", .{trimmed_target}),
                .provider = "chatgpt",
                .model = "gpt-5.2",
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        var parsed_provider_args = try parseProviderScopedModelArgs(allocator, args);
        defer parsed_provider_args.deinit(allocator);
        const requested_provider = parsed_provider_args.provider;
        const requested_model = parsed_provider_args.model;
        const provider_scoped = parsed_provider_args.provider_scoped;

        if (provider_scoped) {
            if (requested_provider.len == 0) {
                const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                    .type = "model.invalid",
                    .target = trimmed_target,
                    .@"error" = "missing_provider",
                });
                return .{
                    .is_command = true,
                    .command_name = "model",
                    .reply = try allocator.dupe(u8, "Provider is required. Usage: `/model <provider>/<model>` or `/model <provider> <model>`."),
                    .provider = model_sel.provider,
                    .model = model_sel.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "invalid",
                    .metadata_json = metadata_json,
                };
            }

            const catalog = try self.resolveModelCatalogAlloc(allocator, requested_provider);
            defer allocator.free(catalog);
            const providers = try listTelegramModelProvidersFromCatalogAlloc(allocator, catalog);
            defer allocator.free(providers);
            if (!isKnownModelProviderInCatalog(catalog, requested_provider)) {
                const providers_text = try std.mem.join(allocator, ", ", providers);
                defer allocator.free(providers_text);
                const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                    .type = "model.invalid",
                    .target = trimmed_target,
                    .requestedProvider = requested_provider,
                    .providers = providers,
                    .@"error" = "unknown_provider",
                });
                return .{
                    .is_command = true,
                    .command_name = "model",
                    .reply = try std.fmt.allocPrint(allocator, "Unknown provider `{s}`. Available providers: {s}", .{ requested_provider, providers_text }),
                    .provider = model_sel.provider,
                    .model = model_sel.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "invalid",
                    .metadata_json = metadata_json,
                };
            }

            if (requested_model.len == 0) {
                const default_model = defaultModelForProviderInCatalog(catalog, requested_provider) orelse {
                    const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                        .type = "model.invalid",
                        .target = trimmed_target,
                        .requestedProvider = requested_provider,
                        .@"error" = "missing_provider_model",
                    });
                    return .{
                        .is_command = true,
                        .command_name = "model",
                        .reply = try std.fmt.allocPrint(allocator, "Provider `{s}` has no catalog models. Run `/model list` first.", .{requested_provider}),
                        .provider = model_sel.provider,
                        .model = model_sel.model,
                        .login_session_id = "",
                        .login_code = "",
                        .auth_status = "invalid",
                        .metadata_json = metadata_json,
                    };
                };
                try self.setTargetModel(target, requested_provider, default_model);
                const model_ref = try modelRefForDisplayAlloc(allocator, requested_provider, default_model);
                defer allocator.free(model_ref);
                const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                    .type = "model.set",
                    .target = trimmed_target,
                    .requestedProvider = requested_provider,
                    .currentProvider = requested_provider,
                    .currentModel = default_model,
                    .modelRef = model_ref,
                    .matchedCatalogModel = true,
                });
                return .{
                    .is_command = true,
                    .command_name = "model",
                    .reply = try std.fmt.allocPrint(allocator, "Model set to `{s}` for `{s}`.", .{ model_ref, trimmed_target }),
                    .provider = requested_provider,
                    .model = default_model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "ok",
                    .metadata_json = metadata_json,
                };
            }

            if (try resolveTelegramModelChoiceForProviderDetailedInCatalog(allocator, catalog, requested_provider, requested_model)) |choice| {
                try self.setTargetModel(target, choice.provider, choice.id);
                const selected = self.getTargetModel(target);
                const model_ref = try modelRefForDisplayAlloc(allocator, selected.provider, selected.model);
                defer allocator.free(model_ref);
                const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                    .type = "model.set",
                    .target = trimmed_target,
                    .requestedProvider = requested_provider,
                    .requestedModel = requested_model,
                    .requested = parsed_provider_args.requested,
                    .aliasUsed = choice.alias_used,
                    .currentProvider = selected.provider,
                    .currentModel = selected.model,
                    .modelRef = model_ref,
                    .matchedCatalogModel = true,
                    .customOverride = false,
                });
                return .{
                    .is_command = true,
                    .command_name = "model",
                    .reply = try std.fmt.allocPrint(allocator, "Model set to `{s}` for `{s}`.", .{ model_ref, trimmed_target }),
                    .provider = selected.provider,
                    .model = selected.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "ok",
                    .metadata_json = metadata_json,
                };
            }

            const custom_model = normalizeModel(requested_model);
            try self.setTargetModel(target, requested_provider, custom_model);
            const selected = self.getTargetModel(target);
            const model_ref = try modelRefForDisplayAlloc(allocator, selected.provider, selected.model);
            defer allocator.free(model_ref);
            const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                .type = "model.set",
                .target = trimmed_target,
                .requestedProvider = requested_provider,
                .requestedModel = custom_model,
                .requested = parsed_provider_args.requested,
                .currentProvider = selected.provider,
                .currentModel = selected.model,
                .modelRef = model_ref,
                .matchedCatalogModel = false,
                .customOverride = true,
            });
            return .{
                .is_command = true,
                .command_name = "model",
                .reply = try std.fmt.allocPrint(allocator, "Model set to `{s}` for `{s}`.\nNote: custom model override applied (not found in catalog).", .{ model_ref, trimmed_target }),
                .provider = selected.provider,
                .model = selected.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        const catalog = try self.resolveModelCatalogAlloc(allocator, action);
        defer allocator.free(catalog);

        if (isKnownModelProviderInCatalog(catalog, action)) {
            const provider = normalizeProvider(action);
            const model = defaultModelForProviderInCatalog(catalog, provider).?;
            try self.setTargetModel(target, provider, model);
            const model_ref = try modelRefForDisplayAlloc(allocator, provider, model);
            defer allocator.free(model_ref);
            const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                .type = "model.set",
                .target = trimmed_target,
                .requestedProvider = provider,
                .currentProvider = provider,
                .currentModel = model,
                .modelRef = model_ref,
                .matchedCatalogModel = true,
            });
            return .{
                .is_command = true,
                .command_name = "model",
                .reply = try std.fmt.allocPrint(allocator, "Model set to `{s}` for `{s}`.", .{ model_ref, trimmed_target }),
                .provider = provider,
                .model = model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        if (try resolveTelegramModelChoiceDetailedInCatalog(allocator, catalog, action)) |choice| {
            try self.setTargetModel(target, choice.provider, choice.id);
            const model_ref = try modelRefForDisplayAlloc(allocator, choice.provider, choice.id);
            defer allocator.free(model_ref);
            const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
                .type = "model.set",
                .target = trimmed_target,
                .requested = action,
                .aliasUsed = choice.alias_used,
                .provider = choice.provider,
                .currentProvider = choice.provider,
                .currentModel = choice.id,
                .modelRef = model_ref,
            });
            return .{
                .is_command = true,
                .command_name = "model",
                .reply = try std.fmt.allocPrint(allocator, "Model set to `{s}` for `{s}`.", .{ model_ref, trimmed_target }),
                .provider = choice.provider,
                .model = choice.id,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        const available_models = try listTelegramModelIDsFromCatalogAlloc(allocator, catalog, "");
        defer allocator.free(available_models);
        const providers = try listTelegramModelProvidersFromCatalogAlloc(allocator, catalog);
        defer allocator.free(providers);
        const available_text = try std.mem.join(allocator, ", ", available_models);
        defer allocator.free(available_text);
        const metadata_json = try stringifyJsonAlloc(allocator, ModelCommandMetadata{
            .type = "model.invalid",
            .target = trimmed_target,
            .requestedModel = action,
            .providers = providers,
            .availableModels = available_models,
            .@"error" = "unknown_model",
        });
        return .{
            .is_command = true,
            .command_name = "model",
            .reply = try std.fmt.allocPrint(allocator, "Unknown model `{s}`. Available: {s}", .{ action, available_text }),
            .provider = model_sel.provider,
            .model = model_sel.model,
            .login_session_id = "",
            .login_code = "",
            .auth_status = "invalid",
            .metadata_json = metadata_json,
        };
    }

    fn handleTtsCommand(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, args: []const []const u8) !SendOutcome {
        const model_sel = self.getTargetModel(target);
        const trimmed_target = std.mem.trim(u8, target, " \t\r\n");
        const action = if (args.len == 0) "status" else args[0];
        const rest = if (args.len > 1) args[1..] else &[_][]const u8{};

        if (std.ascii.eqlIgnoreCase(action, "help")) {
            const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
                .type = "tts.help",
                .target = trimmed_target,
            });
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try allocator.dupe(u8, "TTS command usage:\n`/tts status`\n`/tts providers`\n`/tts provider <name>`\n`/tts on`\n`/tts off`\n`/tts say <text>`"),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "status")) {
            const provider_id = ttsProviderMetadataId(self.tts_provider);
            const available = ttsProviderAvailable(allocator, self.tts_provider);
            const reason = ttsProviderReason(allocator, self.tts_provider);
            const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
                .type = "tts.status",
                .target = trimmed_target,
                .enabled = self.tts_enabled,
                .provider = provider_id,
                .available = available,
                .reason = reason,
            });
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try std.fmt.allocPrint(allocator, "TTS is `{any}` via `{s}` (available={any}).", .{ self.tts_enabled, provider_id, available }),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "providers")) {
            const providers_catalog = try buildTtsProviderCatalogAlloc(allocator);
            defer allocator.free(providers_catalog);
            const providers_summary = try formatTtsProviderSummaryAlloc(allocator, providers_catalog);
            defer allocator.free(providers_summary);
            const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
                .type = "tts.providers",
                .target = trimmed_target,
                .providers = providers_catalog,
            });
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try std.fmt.allocPrint(allocator, "TTS providers: {s}", .{providers_summary}),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "on") or std.ascii.eqlIgnoreCase(action, "enable")) {
            self.tts_enabled = true;
            if (self.persistent) try self.persist();
            const provider_id = ttsProviderMetadataId(self.tts_provider);
            const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
                .type = "tts.enable",
                .target = trimmed_target,
                .enabled = true,
                .provider = provider_id,
                .available = ttsProviderAvailable(allocator, self.tts_provider),
                .reason = ttsProviderReason(allocator, self.tts_provider),
            });
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try std.fmt.allocPrint(allocator, "TTS enabled via `{s}`.", .{provider_id}),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "off") or std.ascii.eqlIgnoreCase(action, "disable")) {
            self.tts_enabled = false;
            if (self.persistent) try self.persist();
            const provider_id = ttsProviderMetadataId(self.tts_provider);
            const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
                .type = "tts.disable",
                .target = trimmed_target,
                .enabled = false,
                .provider = provider_id,
                .available = ttsProviderAvailable(allocator, self.tts_provider),
                .reason = ttsProviderReason(allocator, self.tts_provider),
            });
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try std.fmt.allocPrint(allocator, "TTS disabled (provider `{s}`).", .{provider_id}),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "provider")) {
            const requested_provider = if (rest.len > 0) std.mem.trim(u8, rest[0], " \t\r\n") else "";
            const provider = normalizeTtsProvider(requested_provider);
            if (!isSupportedTtsProvider(provider)) {
                const provider_error = if (requested_provider.len == 0) "missing_provider" else "unsupported_provider";
                const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
                    .type = "tts.provider",
                    .target = trimmed_target,
                    .provider = if (requested_provider.len > 0) ttsProviderMetadataId(requested_provider) else null,
                    .@"error" = provider_error,
                });
                return .{
                    .is_command = true,
                    .command_name = "tts",
                    .reply = if (requested_provider.len == 0)
                        try allocator.dupe(u8, "Missing provider. Usage: `/tts provider <NAME>`")
                    else
                        try std.fmt.allocPrint(allocator, "Failed to set provider: unsupported provider `{s}`.", .{requested_provider}),
                    .provider = model_sel.provider,
                    .model = model_sel.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "invalid",
                    .metadata_json = metadata_json,
                };
            }
            self.allocator.free(self.tts_provider);
            self.tts_provider = try self.allocator.dupe(u8, provider);
            if (self.persistent) try self.persist();
            const provider_id = ttsProviderMetadataId(requested_provider);
            const available = ttsProviderAvailable(allocator, provider);
            const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
                .type = "tts.provider",
                .target = trimmed_target,
                .enabled = self.tts_enabled,
                .provider = provider_id,
                .available = available,
                .reason = ttsProviderReason(allocator, provider),
            });
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try std.fmt.allocPrint(allocator, "TTS provider set to `{s}` (available={any}).", .{ provider_id, available }),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "speak") or std.ascii.eqlIgnoreCase(action, "say")) {
            const text = if (rest.len > 0) try std.mem.join(allocator, " ", rest) else try allocator.dupe(u8, "");
            defer allocator.free(text);
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len == 0) {
                const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
                    .type = "tts.say",
                    .target = trimmed_target,
                    .@"error" = "missing_text",
                });
                return .{
                    .is_command = true,
                    .command_name = "tts",
                    .reply = try allocator.dupe(u8, "Missing text. Usage: `/tts say <text>`"),
                    .provider = model_sel.provider,
                    .model = model_sel.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "invalid",
                    .metadata_json = metadata_json,
                };
            }
            if (!self.tts_enabled) {
                const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
                    .type = "tts.say",
                    .target = trimmed_target,
                    .enabled = false,
                    .provider = ttsProviderMetadataId(self.tts_provider),
                    .@"error" = "tts_disabled",
                });
                return .{
                    .is_command = true,
                    .command_name = "tts",
                    .reply = try allocator.dupe(u8, "TTS is disabled. Run `/tts on` first."),
                    .provider = model_sel.provider,
                    .model = model_sel.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "ok",
                    .metadata_json = metadata_json,
                };
            }

            const provider_used = normalizeTtsProvider(self.tts_provider);
            const provider_id = ttsProviderMetadataId(provider_used);
            const source = resolveTtsSource(allocator, provider_used);
            const audio_base64 = try synthesizeTelegramTtsClipBase64(allocator, trimmed, provider_used, source);
            const audio_ref = try buildTelegramTtsAudioRefAlloc(allocator, provider_used, "wav");
            defer allocator.free(audio_ref);
            const real_audio = !std.ascii.eqlIgnoreCase(source, "simulated");
            const fallback = !real_audio and !std.ascii.eqlIgnoreCase(provider_id, "native");
            const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
                .type = "tts.say",
                .target = trimmed_target,
                .text = trimmed,
                .provider = provider_id,
                .audioRef = audio_ref,
                .bytes = base64DecodedLen(audio_base64),
                .outputFormat = "wav",
                .realAudio = real_audio,
                .fallback = fallback,
                .engine = provider_id,
                .audioSource = source,
            });

            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try std.fmt.allocPrint(allocator, "TTS synthesized `{d}` bytes (real={any}).", .{ base64DecodedLen(audio_base64), real_audio }),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .audio_base64 = audio_base64,
                .audio_format = "wav",
                .audio_bytes = base64DecodedLen(audio_base64),
                .audio_provider_used = provider_used,
                .audio_source = source,
                .metadata_json = metadata_json,
            };
        }

        const metadata_json = try stringifyJsonAlloc(allocator, TtsCommandMetadata{
            .type = "tts.invalid",
            .target = trimmed_target,
            .action = action,
        });
        return .{
            .is_command = true,
            .command_name = "tts",
            .reply = try allocator.dupe(u8, "Unknown `/tts` action. Use `/tts status|providers|on|off|provider|say|help`."),
            .provider = model_sel.provider,
            .model = model_sel.model,
            .login_session_id = "",
            .login_code = "",
            .auth_status = "invalid",
            .metadata_json = metadata_json,
        };
    }

    fn handleAuthCommand(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, args: []const []const u8) !SendOutcome {
        const model_sel = self.getTargetModel(target);
        const default_provider = normalizeProvider(model_sel.provider);
        const default_model = normalizeModel(model_sel.model);
        const trimmed_target = std.mem.trim(u8, target, " \t\r\n");
        const action = if (args.len == 0) "start" else args[0];
        const rest = if (args.len > 1) args[1..] else &[_][]const u8{};

        if (std.ascii.eqlIgnoreCase(action, "help")) {
            const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                .type = "auth.help",
                .target = trimmed_target,
            });
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try allocator.dupe(
                    u8,
                    "Auth command usage:\n" ++
                        "`/auth providers`\n" ++
                        "`/auth status [provider] [account] [session_id]`\n" ++
                        "`/auth bridge`\n" ++
                        "`/auth` (start default provider)\n" ++
                        "`/auth start <provider> [account] [--force]`\n" ++
                        "`/auth wait <provider> [session_id] [account] [--timeout <seconds>]`\n" ++
                        "`/auth complete <provider> <callback_url_or_code> [session_id] [account]`\n" ++
                        "`/auth complete <code> [session_id]`\n" ++
                        "`/auth cancel [provider] [account] [session_id]`\n" ++
                        "`/auth url <provider> [account] [session_id]`\n" ++
                        "`/auth guest <provider> [account] [session_id]`",
                ),
                .provider = default_provider,
                .model = default_model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "providers")) {
            const metadata_json = try self.buildAuthProvidersMetadataJson(allocator, trimmed_target);
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try self.formatAuthProvidersMessage(allocator),
                .provider = default_provider,
                .model = default_model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "bridge")) {
            const bridge_provider = if (rest.len > 0 and isKnownProvider(rest[0])) normalizeProvider(rest[0]) else default_provider;
            const metadata_json = try self.buildAuthBridgeMetadataJson(allocator, trimmed_target, bridge_provider);
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try self.formatBridgeStatusMessage(allocator, bridge_provider),
                .provider = bridge_provider,
                .model = defaultModelForProvider(bridge_provider),
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
                .metadata_json = metadata_json,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "link") or std.ascii.eqlIgnoreCase(action, "open") or std.ascii.eqlIgnoreCase(action, "url")) {
            const usage = "Usage: `/auth status [provider] [account] [session_id]`";
            var provider = default_provider;
            var account: []const u8 = "default";
            var session_token: []const u8 = "";
            var index: usize = 0;
            if (rest.len > 0 and isKnownProvider(rest[0])) {
                provider = normalizeProvider(rest[0]);
                index = 1;
            }
            while (index < rest.len) : (index += 1) {
                const token = std.mem.trim(u8, rest[index], " \t\r\n");
                if (token.len == 0) continue;
                if (std.ascii.startsWithIgnoreCase(token, "--")) {
                    return self.authInvalidOutcome(
                        allocator,
                        trimmed_target,
                        "auth.url",
                        provider,
                        account,
                        try std.fmt.allocPrint(allocator, "Unknown status option `{s}`.", .{token}),
                        "invalid_url_args",
                        "invalid",
                        "",
                        null,
                    );
                }
                if (session_token.len == 0 and looksLikeLoginSessionID(token)) {
                    session_token = token;
                    continue;
                }
                if (std.mem.eql(u8, normalizeAccount(account), "default")) {
                    account = token;
                    continue;
                }
                return self.authInvalidOutcome(
                    allocator,
                    trimmed_target,
                    "auth.url",
                    provider,
                    account,
                    try allocator.dupe(u8, usage),
                    "invalid_url_args",
                    "invalid",
                    "",
                    null,
                );
            }

            const bound_session = try self.getAuthBinding(allocator, target, provider, account);
            const login_session = if (std.mem.trim(u8, session_token, " \t\r\n").len > 0) session_token else bound_session;
            if (std.mem.trim(u8, login_session, " \t\r\n").len == 0) {
                const missing_reply = try allocator.dupe(u8, "No active auth flow. Run `/auth start <provider>` first.");
                const scope = try authScopeAlloc(allocator, provider, account);
                defer allocator.free(scope);
                const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                    .type = "auth.url",
                    .target = trimmed_target,
                    .provider = provider,
                    .account = normalizeAccount(account),
                    .scope = scope,
                    .status = "none",
                });
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = missing_reply,
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "none",
                    .metadata_json = metadata_json,
                };
            }

            const view = self.login_manager.get(login_session) orelse {
                const should_clear_binding = std.mem.trim(u8, session_token, " \t\r\n").len == 0;
                const owned_login_session_id = if (should_clear_binding and std.mem.trim(u8, login_session, " \t\r\n").len > 0)
                    try allocator.dupe(u8, login_session)
                else
                    null;
                const login_session_value = if (owned_login_session_id) |value| value else login_session;
                if (should_clear_binding) {
                    try self.clearAuthBinding(allocator, target, provider, account);
                }
                const scope = try authScopeAlloc(allocator, provider, account);
                defer allocator.free(scope);
                const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                    .type = "auth.url",
                    .target = trimmed_target,
                    .provider = provider,
                    .account = normalizeAccount(account),
                    .scope = scope,
                    .status = "missing",
                    .loginSessionId = login_session_value,
                });
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Auth session expired or missing. Run `/auth` again."),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = login_session_value,
                    .owned_login_session_id = owned_login_session_id,
                    .login_code = "",
                    .auth_status = "missing",
                    .metadata_json = metadata_json,
                };
            };
            const account_norm = normalizeAccount(account);
            const reply = try self.formatAuthUrlMessage(allocator, provider, account_norm, view);
            const scope = try authScopeAlloc(allocator, provider, account_norm);
            defer allocator.free(scope);
            const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                .type = "auth.url",
                .target = trimmed_target,
                .provider = provider,
                .account = account_norm,
                .scope = scope,
                .status = view.status,
                .loginSessionId = view.loginSessionId,
                .code = view.code,
                .verificationUri = view.verificationUri,
                .verificationUriComplete = view.verificationUriComplete,
                .login = view,
            });
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = reply,
                .provider = provider,
                .model = view.model,
                .login_session_id = view.loginSessionId,
                .login_code = view.code,
                .auth_status = view.status,
                .metadata_json = metadata_json,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "start")) {
            var provider = default_provider;
            var account: []const u8 = "default";
            var force = false;
            var index: usize = 0;
            if (rest.len > 0 and isKnownProvider(rest[0])) {
                provider = normalizeProvider(rest[0]);
                index = 1;
            }
            while (index < rest.len) : (index += 1) {
                const token = std.mem.trim(u8, rest[index], " \t\r\n");
                if (token.len == 0) continue;
                if (std.ascii.eqlIgnoreCase(token, "--force")) {
                    force = true;
                    continue;
                }
                if (std.ascii.startsWithIgnoreCase(token, "--")) {
                    const scope = try authScopeAlloc(allocator, provider, account);
                    defer allocator.free(scope);
                    const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                        .type = "auth.start",
                        .target = trimmed_target,
                        .provider = provider,
                        .account = normalizeAccount(account),
                        .scope = scope,
                        .resolvedScope = scope,
                        .status = "invalid",
                        .@"error" = "invalid_start_args",
                    });
                    return .{
                        .is_command = true,
                        .command_name = "auth",
                        .reply = try std.fmt.allocPrint(allocator, "Unknown start option `{s}`.", .{token}),
                        .provider = provider,
                        .model = defaultModelForProvider(provider),
                        .login_session_id = "",
                        .login_code = "",
                        .auth_status = "invalid",
                        .metadata_json = metadata_json,
                    };
                }
                if (std.mem.eql(u8, account, "default")) {
                    account = token;
                    continue;
                }
                const scope = try authScopeAlloc(allocator, provider, account);
                defer allocator.free(scope);
                const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                    .type = "auth.start",
                    .target = trimmed_target,
                    .provider = provider,
                    .account = normalizeAccount(account),
                    .scope = scope,
                    .resolvedScope = scope,
                    .status = "invalid",
                    .@"error" = "invalid_start_args",
                });
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Usage: `/auth start <provider> [account] [--force]`"),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "invalid",
                    .metadata_json = metadata_json,
                };
            }

            const model = if (std.ascii.eqlIgnoreCase(provider, default_provider)) default_model else defaultModelForProvider(provider);
            const existing_session = try self.getAuthBinding(allocator, target, provider, account);
            if (!force and existing_session.len > 0) {
                if (self.login_manager.get(existing_session)) |existing| {
                    if (std.ascii.eqlIgnoreCase(existing.status, "pending")) {
                        const account_norm = normalizeAccount(account);
                        const expires_at = try time_util.unixMsToRfc3339Alloc(allocator, existing.expiresAtMs);
                        defer allocator.free(expires_at);
                        const reply = try std.fmt.allocPrint(
                            allocator,
                            "Auth already pending for `{s}` account `{s}`.\nOpen: {s}\nThen run: `/auth complete {s} {s}`",
                            .{ provider, account_norm, existing.verificationUriComplete, provider, existing.code },
                        );
                        const scope = try authScopeAlloc(allocator, provider, account_norm);
                        defer allocator.free(scope);
                        const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                            .type = "auth.start",
                            .target = trimmed_target,
                            .provider = provider,
                            .account = account_norm,
                            .scope = scope,
                            .resolvedScope = scope,
                            .status = existing.status,
                            .loginSessionId = existing.loginSessionId,
                            .code = existing.code,
                            .expiresAt = expires_at,
                            .verificationUri = existing.verificationUri,
                            .verificationUriComplete = existing.verificationUriComplete,
                            .model = existing.model,
                            .force = force,
                            .login = existing,
                        });
                        return .{
                            .is_command = true,
                            .command_name = "auth",
                            .reply = reply,
                            .provider = provider,
                            .model = existing.model,
                            .login_session_id = existing.loginSessionId,
                            .login_code = existing.code,
                            .auth_status = existing.status,
                            .metadata_json = metadata_json,
                        };
                    }
                }
            }

            const started = try self.login_manager.start(provider, model);
            try self.setAuthBinding(target, provider, account, started.loginSessionId);
            const account_norm = normalizeAccount(account);
            const account_is_default = std.mem.eql(u8, account_norm, "default");
            const expires_at = try time_util.unixMsToRfc3339Alloc(allocator, started.expiresAtMs);
            defer allocator.free(expires_at);
            const reply = if (account_is_default)
                try std.fmt.allocPrint(
                    allocator,
                    "Auth started for `{s}`.\nOpen: {s}\nIf prompted, use code `{s}`.\nThen run: `/auth complete {s} {s}`",
                    .{ provider, started.verificationUriComplete, started.code, provider, started.code },
                )
            else
                try std.fmt.allocPrint(
                    allocator,
                    "Auth started for `{s}` account `{s}`.\nOpen: {s}\nIf prompted, use code `{s}`.\nThen run: `/auth complete {s} {s} {s}`",
                    .{ provider, account_norm, started.verificationUriComplete, started.code, provider, started.code, account_norm },
                );
            const scope = try authScopeAlloc(allocator, provider, account_norm);
            defer allocator.free(scope);
            const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                .type = "auth.start",
                .target = trimmed_target,
                .provider = provider,
                .account = account_norm,
                .scope = scope,
                .resolvedScope = scope,
                .status = started.status,
                .loginSessionId = started.loginSessionId,
                .code = started.code,
                .expiresAt = expires_at,
                .verificationUri = started.verificationUri,
                .verificationUriComplete = started.verificationUriComplete,
                .model = model,
                .force = force,
                .login = started,
            });
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = reply,
                .provider = provider,
                .model = model,
                .login_session_id = started.loginSessionId,
                .login_code = started.code,
                .auth_status = started.status,
                .metadata_json = metadata_json,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "status") or std.ascii.eqlIgnoreCase(action, "wait")) {
            const is_wait = std.ascii.eqlIgnoreCase(action, "wait");
            const usage = if (is_wait)
                "Usage: `/auth wait <provider> [session_id] [account] [--timeout <seconds>]`"
            else
                "Usage: `/auth status [provider] [account] [session_id]`";
            var provider = default_provider;
            var account: []const u8 = "default";
            var session_token: []const u8 = "";
            var timeout_secs: u32 = 30;
            var explicit_timeout = false;
            var index: usize = 0;
            if (rest.len > 0 and isKnownProvider(rest[0])) {
                provider = normalizeProvider(rest[0]);
                index = 1;
            }
            while (index < rest.len) : (index += 1) {
                const token = std.mem.trim(u8, rest[index], " \t\r\n");
                if (token.len == 0) continue;
                if (is_wait and std.ascii.eqlIgnoreCase(token, "session")) {
                    if (index + 1 >= rest.len) {
                        return self.authInvalidOutcome(allocator, trimmed_target, "auth.wait", provider, account, try allocator.dupe(u8, usage), "invalid_wait_args", "invalid", "", timeout_secs);
                    }
                    session_token = std.mem.trim(u8, rest[index + 1], " \t\r\n");
                    index += 1;
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(token, "--timeout")) {
                    if (index + 1 >= rest.len) {
                        return self.authInvalidOutcome(allocator, trimmed_target, "auth.wait", provider, account, try allocator.dupe(u8, "Missing timeout value. Example: `/auth wait --timeout 90`"), "missing_timeout", "invalid", "", timeout_secs);
                    }
                    const parsed_timeout = std.fmt.parseInt(u32, std.mem.trim(u8, rest[index + 1], " \t\r\n"), 10) catch {
                        return self.authInvalidOutcome(allocator, trimmed_target, "auth.wait", provider, account, try allocator.dupe(u8, "Timeout must be an integer between 1 and 900 seconds."), "invalid_timeout", "invalid", "", timeout_secs);
                    };
                    if (parsed_timeout < 1 or parsed_timeout > 900) {
                        return self.authInvalidOutcome(allocator, trimmed_target, "auth.wait", provider, account, try allocator.dupe(u8, "Timeout must be an integer between 1 and 900 seconds."), "invalid_timeout", "invalid", "", timeout_secs);
                    }
                    timeout_secs = parsed_timeout;
                    explicit_timeout = true;
                    index += 1;
                    continue;
                }
                if (is_wait and std.ascii.startsWithIgnoreCase(token, "--timeout=")) {
                    const raw_timeout = std.mem.trim(u8, token["--timeout=".len..], " \t\r\n");
                    const parsed_timeout = std.fmt.parseInt(u32, raw_timeout, 10) catch {
                        return self.authInvalidOutcome(allocator, trimmed_target, "auth.wait", provider, account, try allocator.dupe(u8, "Timeout must be an integer between 1 and 900 seconds."), "invalid_timeout", "invalid", "", timeout_secs);
                    };
                    if (parsed_timeout < 1 or parsed_timeout > 900) {
                        return self.authInvalidOutcome(allocator, trimmed_target, "auth.wait", provider, account, try allocator.dupe(u8, "Timeout must be an integer between 1 and 900 seconds."), "invalid_timeout", "invalid", "", timeout_secs);
                    }
                    timeout_secs = parsed_timeout;
                    explicit_timeout = true;
                    continue;
                }
                if (std.ascii.startsWithIgnoreCase(token, "--")) {
                    const unknown_reply = if (is_wait)
                        try std.fmt.allocPrint(allocator, "Unknown wait option `{s}`.", .{token})
                    else
                        try std.fmt.allocPrint(allocator, "Unknown status option `{s}`.", .{token});
                    return self.authInvalidOutcome(allocator, trimmed_target, if (is_wait) "auth.wait" else "auth.status", provider, account, unknown_reply, if (is_wait) "invalid_wait_args" else "invalid_status_args", "invalid", "", if (is_wait) timeout_secs else null);
                }
                if (is_wait and !explicit_timeout and session_token.len == 0 and (std.mem.eql(u8, normalizeAccount(account), "default") or index == rest.len - 1)) {
                    if (std.fmt.parseInt(u32, token, 10)) |parsed_timeout| {
                        if (parsed_timeout < 1 or parsed_timeout > 900) {
                            return self.authInvalidOutcome(allocator, trimmed_target, "auth.wait", provider, account, try allocator.dupe(u8, "Timeout must be an integer between 1 and 900 seconds."), "invalid_timeout", "invalid", "", timeout_secs);
                        }
                        timeout_secs = parsed_timeout;
                        continue;
                    } else |_| {}
                }
                if (session_token.len == 0 and looksLikeLoginSessionID(token)) {
                    session_token = token;
                    continue;
                }
                if (std.mem.eql(u8, normalizeAccount(account), "default")) {
                    account = token;
                    continue;
                }
                return self.authInvalidOutcome(allocator, trimmed_target, if (is_wait) "auth.wait" else "auth.status", provider, account, try allocator.dupe(u8, usage), if (is_wait) "invalid_wait_args" else "invalid_status_args", "invalid", "", if (is_wait) timeout_secs else null);
            }

            const bound_session = try self.getAuthBinding(allocator, target, provider, account);
            const login_session = if (std.mem.trim(u8, session_token, " \t\r\n").len > 0) session_token else bound_session;
            if (std.mem.trim(u8, login_session, " \t\r\n").len == 0) {
                const account_norm = normalizeAccount(account);
                const scope = try authScopeAlloc(allocator, provider, account_norm);
                defer allocator.free(scope);
                const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                    .type = if (is_wait) "auth.wait" else "auth.status",
                    .target = trimmed_target,
                    .provider = provider,
                    .account = account_norm,
                    .scope = scope,
                    .status = if (is_wait) null else "none",
                    .@"error" = if (is_wait) "missing_session" else null,
                    .timeoutSeconds = if (is_wait) timeout_secs else null,
                });
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = if (is_wait)
                        try std.fmt.allocPrint(allocator, "No auth session selected for scope `{s}`. Start with `/auth start {s}`.", .{ scope, provider })
                    else
                        try std.fmt.allocPrint(allocator, "No active auth flow for `{s}` in scope `{s}`.", .{ trimmed_target, scope }),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = if (is_wait) "missing" else "none",
                    .metadata_json = metadata_json,
                };
            }

            if (std.ascii.eqlIgnoreCase(action, "wait")) {
                const timeout_ms: u32 = timeout_secs * 1000;
                const waited = self.login_manager.wait(login_session, timeout_ms) catch |err| switch (err) {
                    error.SessionNotFound => {
                        const account_norm = normalizeAccount(account);
                        const scope = try authScopeAlloc(allocator, provider, account_norm);
                        defer allocator.free(scope);
                        const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                            .type = "auth.wait",
                            .target = trimmed_target,
                            .provider = provider,
                            .account = account_norm,
                            .scope = scope,
                            .@"error" = "login session not found",
                            .loginSessionId = login_session,
                            .timeoutSeconds = timeout_secs,
                        });
                        return .{
                            .is_command = true,
                            .command_name = "auth",
                            .reply = try allocator.dupe(u8, "Auth wait failed: login session not found"),
                            .provider = provider,
                            .model = defaultModelForProvider(provider),
                            .login_session_id = login_session,
                            .login_code = "",
                            .auth_status = "missing",
                            .metadata_json = metadata_json,
                        };
                    },
                    error.SessionExpired => {
                        const account_norm = normalizeAccount(account);
                        const scope = try authScopeAlloc(allocator, provider, account_norm);
                        defer allocator.free(scope);
                        const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                            .type = "auth.wait",
                            .target = trimmed_target,
                            .provider = provider,
                            .account = account_norm,
                            .scope = scope,
                            .@"error" = "login session expired",
                            .loginSessionId = login_session,
                            .timeoutSeconds = timeout_secs,
                        });
                        return .{
                            .is_command = true,
                            .command_name = "auth",
                            .reply = try allocator.dupe(u8, "Auth wait failed: login session expired"),
                            .provider = provider,
                            .model = defaultModelForProvider(provider),
                            .login_session_id = login_session,
                            .login_code = "",
                            .auth_status = "expired",
                            .metadata_json = metadata_json,
                        };
                    },
                    error.InvalidCode => unreachable,
                };
                const account_norm = normalizeAccount(account);
                const scope = try authScopeAlloc(allocator, provider, account_norm);
                defer allocator.free(scope);
                const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                    .type = "auth.wait",
                    .target = trimmed_target,
                    .provider = provider,
                    .account = account_norm,
                    .scope = scope,
                    .status = waited.status,
                    .loginSessionId = waited.loginSessionId,
                    .code = waited.code,
                    .timeoutSeconds = timeout_secs,
                    .expiresInSeconds = authExpiresInSeconds(waited.expiresAtMs),
                    .login = waited,
                });
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "Auth wait result: `{s}` (session `{s}`).", .{ waited.status, waited.loginSessionId }),
                    .provider = provider,
                    .model = waited.model,
                    .login_session_id = waited.loginSessionId,
                    .login_code = waited.code,
                    .auth_status = waited.status,
                    .metadata_json = metadata_json,
                };
            }

            const view = self.login_manager.get(login_session) orelse {
                const should_clear_binding = std.mem.trim(u8, session_token, " \t\r\n").len == 0;
                const owned_login_session_id = if (should_clear_binding and std.mem.trim(u8, login_session, " \t\r\n").len > 0)
                    try allocator.dupe(u8, login_session)
                else
                    null;
                const login_session_value = if (owned_login_session_id) |value| value else login_session;
                if (should_clear_binding) {
                    try self.clearAuthBinding(allocator, target, provider, account);
                }
                const account_norm = normalizeAccount(account);
                const scope = try authScopeAlloc(allocator, provider, account_norm);
                defer allocator.free(scope);
                const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                    .type = "auth.status",
                    .target = trimmed_target,
                    .provider = provider,
                    .account = account_norm,
                    .scope = scope,
                    .status = "missing",
                    .loginSessionId = login_session_value,
                });
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Auth session expired or missing. Run `/auth start <provider>` again."),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = login_session_value,
                    .owned_login_session_id = owned_login_session_id,
                    .login_code = "",
                    .auth_status = "missing",
                    .metadata_json = metadata_json,
                };
            };
            const account_norm = normalizeAccount(account);
            const scope = try authScopeAlloc(allocator, provider, account_norm);
            defer allocator.free(scope);
            const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                .type = "auth.status",
                .target = trimmed_target,
                .provider = provider,
                .account = account_norm,
                .scope = scope,
                .status = view.status,
                .loginSessionId = view.loginSessionId,
                .code = view.code,
                .expiresInSeconds = authExpiresInSeconds(view.expiresAtMs),
                .login = view,
            });
            const reply = if (std.ascii.eqlIgnoreCase(view.status, "pending"))
                try std.fmt.allocPrint(
                    allocator,
                    "Auth status: `{s}` (session `{s}`).\nOpen: {s}\nThen run: `/auth complete {s} {s}`",
                    .{ view.status, view.loginSessionId, view.verificationUriComplete, provider, view.code },
                )
            else
                try std.fmt.allocPrint(allocator, "Auth status: `{s}` (session `{s}`).", .{ view.status, view.loginSessionId });
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = reply,
                .provider = provider,
                .model = view.model,
                .login_session_id = view.loginSessionId,
                .login_code = view.code,
                .auth_status = view.status,
                .metadata_json = metadata_json,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "guest")) {
            var provider = default_provider;
            var account: []const u8 = "default";
            var session_token: []const u8 = "";
            var index: usize = 0;
            if (rest.len > 0 and isKnownProvider(rest[0])) {
                provider = normalizeProvider(rest[0]);
                index = 1;
            }
            while (index < rest.len) : (index += 1) {
                const token = std.mem.trim(u8, rest[index], " \t\r\n");
                if (token.len == 0) continue;
                if (session_token.len == 0 and looksLikeLoginSessionID(token)) {
                    session_token = token;
                    continue;
                }
                if (std.mem.eql(u8, normalizeAccount(account), "default")) account = token;
            }
            const bound_session = try self.getAuthBinding(allocator, target, provider, account);
            const login_session = if (std.mem.trim(u8, session_token, " \t\r\n").len > 0) session_token else bound_session;
            if (std.mem.trim(u8, login_session, " \t\r\n").len == 0) {
                const account_norm = normalizeAccount(account);
                const scope = try authScopeAlloc(allocator, provider, account_norm);
                defer allocator.free(scope);
                const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                    .type = "auth.guest",
                    .target = trimmed_target,
                    .provider = provider,
                    .account = account_norm,
                    .scope = scope,
                    .status = "none",
                    .@"error" = "missing_session",
                });
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "No pending auth session for `{s}` account `{s}`. Start with `/auth start {s} {s}`.", .{ provider, normalizeAccount(account), provider, normalizeAccount(account) }),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "pending",
                    .metadata_json = metadata_json,
                };
            }
            const completed = self.login_manager.complete(login_session, "") catch |err| switch (err) {
                error.InvalidCode => {
                    const account_norm = normalizeAccount(account);
                    const scope = try authScopeAlloc(allocator, provider, account_norm);
                    defer allocator.free(scope);
                    const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                        .type = "auth.guest",
                        .target = trimmed_target,
                        .provider = provider,
                        .account = account_norm,
                        .scope = scope,
                        .status = "rejected",
                        .@"error" = "invalid_code",
                        .loginSessionId = login_session,
                    });
                    return .{
                        .is_command = true,
                        .command_name = "auth",
                        .reply = try std.fmt.allocPrint(allocator, "Guest completion is not supported for `{s}`. Use `/auth complete {s} <code_or_url>`.", .{ provider, provider }),
                        .provider = provider,
                        .model = defaultModelForProvider(provider),
                        .login_session_id = login_session,
                        .login_code = "",
                        .auth_status = "rejected",
                        .metadata_json = metadata_json,
                    };
                },
                error.SessionExpired => {
                    const account_norm = normalizeAccount(account);
                    const scope = try authScopeAlloc(allocator, provider, account_norm);
                    defer allocator.free(scope);
                    const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                        .type = "auth.guest",
                        .target = trimmed_target,
                        .provider = provider,
                        .account = account_norm,
                        .scope = scope,
                        .status = "expired",
                        .@"error" = "session_expired",
                        .loginSessionId = login_session,
                    });
                    return .{
                        .is_command = true,
                        .command_name = "auth",
                        .reply = try allocator.dupe(u8, "Auth failed: session expired."),
                        .provider = provider,
                        .model = defaultModelForProvider(provider),
                        .login_session_id = login_session,
                        .login_code = "",
                        .auth_status = "expired",
                        .metadata_json = metadata_json,
                    };
                },
                error.SessionNotFound => {
                    const account_norm = normalizeAccount(account);
                    const scope = try authScopeAlloc(allocator, provider, account_norm);
                    defer allocator.free(scope);
                    const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                        .type = "auth.guest",
                        .target = trimmed_target,
                        .provider = provider,
                        .account = account_norm,
                        .scope = scope,
                        .status = "missing",
                        .@"error" = "session_not_found",
                        .loginSessionId = login_session,
                    });
                    return .{
                        .is_command = true,
                        .command_name = "auth",
                        .reply = try allocator.dupe(u8, "Auth failed: session not found."),
                        .provider = provider,
                        .model = defaultModelForProvider(provider),
                        .login_session_id = login_session,
                        .login_code = "",
                        .auth_status = "missing",
                        .metadata_json = metadata_json,
                    };
                },
            };
            try self.setAuthBinding(target, provider, account, completed.loginSessionId);
            const account_norm = normalizeAccount(account);
            const scope = try authScopeAlloc(allocator, provider, account_norm);
            defer allocator.free(scope);
            const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                .type = "auth.guest",
                .target = trimmed_target,
                .provider = provider,
                .account = account_norm,
                .scope = scope,
                .status = completed.status,
                .loginSessionId = completed.loginSessionId,
                .login = completed,
            });
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "Guest auth completed for `{s}` account `{s}`. Session `{s}` is `{s}`.", .{ provider, normalizeAccount(account), completed.loginSessionId, completed.status }),
                .provider = provider,
                .model = completed.model,
                .login_session_id = completed.loginSessionId,
                .login_code = "",
                .auth_status = completed.status,
                .metadata_json = metadata_json,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "complete")) {
            if (rest.len == 0) {
                return self.authInvalidOutcome(
                    allocator,
                    trimmed_target,
                    "auth.complete",
                    default_provider,
                    "default",
                    try allocator.dupe(u8, "Usage: `/auth complete <provider> <callback_url_or_code> [session_id] [account]`"),
                    "invalid_complete_args",
                    "invalid",
                    "",
                    null,
                );
            }

            var provider = default_provider;
            var code_token: []const u8 = "";
            var session_token: []const u8 = "";
            var account: []const u8 = "default";
            var index: usize = 0;

            if (rest.len > 0 and isKnownProvider(rest[0])) {
                provider = normalizeProvider(rest[0]);
                index = 1;
            }

            while (index < rest.len) : (index += 1) {
                const token = std.mem.trim(u8, rest[index], " \t\r\n");
                if (token.len == 0) continue;
                if (std.ascii.startsWithIgnoreCase(token, "--")) {
                    return self.authInvalidOutcome(allocator, trimmed_target, "auth.complete", provider, account, try std.fmt.allocPrint(allocator, "Unknown complete option `{s}`.", .{token}), "invalid_complete_args", "invalid", "", null);
                }
                if (code_token.len == 0) {
                    code_token = token;
                    continue;
                }
                if (session_token.len == 0 and looksLikeLoginSessionID(token)) {
                    session_token = token;
                    continue;
                }
                if (std.mem.eql(u8, normalizeAccount(account), "default")) {
                    account = token;
                    continue;
                }
                return self.authInvalidOutcome(allocator, trimmed_target, "auth.complete", provider, account, try allocator.dupe(u8, "Usage: `/auth complete <provider> <callback_url_or_code> [session_id] [account]`"), "invalid_complete_args", "invalid", "", null);
            }

            if (code_token.len == 0) {
                return self.authInvalidOutcome(allocator, trimmed_target, "auth.complete", provider, account, try allocator.dupe(u8, "Usage: `/auth complete <provider> <callback_url_or_code> [session_id] [account]`"), "invalid_complete_args", "invalid", "", null);
            }

            if (!isKnownProvider(rest[0])) {
                if (inferProviderFromAuthInput(code_token)) |inferred| {
                    provider = inferred;
                }
            }

            const bound_session = try self.getAuthBinding(allocator, target, provider, account);
            const login_session = if (std.mem.trim(u8, session_token, " \t\r\n").len > 0) session_token else bound_session;
            if (std.mem.trim(u8, login_session, " \t\r\n").len == 0) {
                const account_norm = normalizeAccount(account);
                const scope = try authScopeAlloc(allocator, provider, account_norm);
                defer allocator.free(scope);
                const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                    .type = "auth.complete",
                    .target = trimmed_target,
                    .provider = provider,
                    .account = account_norm,
                    .scope = scope,
                    .@"error" = "missing_session",
                });
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "No pending auth session for scope `{s}`. Run `/auth start {s}` first.", .{ scope, provider }),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "none",
                    .metadata_json = metadata_json,
                };
            }
            const code = web_login.extractAuthCode(code_token);
            if (std.mem.trim(u8, code, " \t\r\n").len == 0) {
                const account_norm = normalizeAccount(account);
                const scope = try authScopeAlloc(allocator, provider, account_norm);
                defer allocator.free(scope);
                if (self.login_manager.get(login_session)) |login| {
                    if (std.ascii.eqlIgnoreCase(login.status, "authorized")) {
                        const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                            .type = "auth.complete",
                            .target = trimmed_target,
                            .provider = provider,
                            .account = account_norm,
                            .scope = scope,
                            .status = login.status,
                            .loginSessionId = login.loginSessionId,
                            .login = login,
                        });
                        return .{
                            .is_command = true,
                            .command_name = "auth",
                            .reply = try std.fmt.allocPrint(allocator, "Auth already completed. Session `{s}` is `{s}`.", .{ login.loginSessionId, login.status }),
                            .provider = provider,
                            .model = login.model,
                            .login_session_id = login.loginSessionId,
                            .login_code = login.code,
                            .auth_status = login.status,
                            .metadata_json = metadata_json,
                        };
                    }
                }
                const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                    .type = "auth.complete",
                    .target = trimmed_target,
                    .provider = provider,
                    .account = account_norm,
                    .scope = scope,
                    .@"error" = "missing_code",
                    .loginSessionId = login_session,
                });
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Missing code. Usage: `/auth complete <provider> <callback_url_or_code> [session_id] [account]`"),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = login_session,
                    .login_code = "",
                    .auth_status = "pending",
                    .metadata_json = metadata_json,
                };
            }
            const completed = self.login_manager.complete(login_session, code) catch |err| switch (err) {
                error.InvalidCode => {
                    const account_norm = normalizeAccount(account);
                    const scope = try authScopeAlloc(allocator, provider, account_norm);
                    defer allocator.free(scope);
                    const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                        .type = "auth.complete",
                        .target = trimmed_target,
                        .provider = provider,
                        .account = account_norm,
                        .scope = scope,
                        .@"error" = "invalid login code",
                        .loginSessionId = login_session,
                    });
                    return .{
                        .is_command = true,
                        .command_name = "auth",
                        .reply = try allocator.dupe(u8, "Auth failed: invalid login code"),
                        .provider = provider,
                        .model = defaultModelForProvider(provider),
                        .login_session_id = login_session,
                        .login_code = "",
                        .auth_status = "rejected",
                        .metadata_json = metadata_json,
                    };
                },
                error.SessionExpired => {
                    const account_norm = normalizeAccount(account);
                    const scope = try authScopeAlloc(allocator, provider, account_norm);
                    defer allocator.free(scope);
                    const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                        .type = "auth.complete",
                        .target = trimmed_target,
                        .provider = provider,
                        .account = account_norm,
                        .scope = scope,
                        .@"error" = "login session expired",
                        .loginSessionId = login_session,
                    });
                    return .{
                        .is_command = true,
                        .command_name = "auth",
                        .reply = try allocator.dupe(u8, "Auth failed: login session expired"),
                        .provider = provider,
                        .model = defaultModelForProvider(provider),
                        .login_session_id = login_session,
                        .login_code = "",
                        .auth_status = "expired",
                        .metadata_json = metadata_json,
                    };
                },
                error.SessionNotFound => {
                    const account_norm = normalizeAccount(account);
                    const scope = try authScopeAlloc(allocator, provider, account_norm);
                    defer allocator.free(scope);
                    const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                        .type = "auth.complete",
                        .target = trimmed_target,
                        .provider = provider,
                        .account = account_norm,
                        .scope = scope,
                        .@"error" = "login session not found",
                        .loginSessionId = login_session,
                    });
                    return .{
                        .is_command = true,
                        .command_name = "auth",
                        .reply = try allocator.dupe(u8, "Auth failed: login session not found"),
                        .provider = provider,
                        .model = defaultModelForProvider(provider),
                        .login_session_id = login_session,
                        .login_code = "",
                        .auth_status = "missing",
                        .metadata_json = metadata_json,
                    };
                },
            };
            try self.setAuthBinding(target, provider, account, completed.loginSessionId);
            const account_norm = normalizeAccount(account);
            const scope = try authScopeAlloc(allocator, provider, account_norm);
            defer allocator.free(scope);
            const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                .type = "auth.complete",
                .target = trimmed_target,
                .provider = provider,
                .account = account_norm,
                .scope = scope,
                .status = completed.status,
                .loginSessionId = completed.loginSessionId,
                .code = completed.code,
                .login = completed,
            });
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "Auth completed. Session `{s}` is `{s}`.", .{ completed.loginSessionId, completed.status }),
                .provider = provider,
                .model = completed.model,
                .login_session_id = completed.loginSessionId,
                .login_code = completed.code,
                .auth_status = completed.status,
                .metadata_json = metadata_json,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "cancel") or std.ascii.eqlIgnoreCase(action, "logout")) {
            var provider = default_provider;
            var account: []const u8 = "default";
            var session_token: []const u8 = "";
            var index: usize = 0;
            if (rest.len > 0 and isKnownProvider(rest[0])) {
                provider = normalizeProvider(rest[0]);
                index = 1;
            }
            while (index < rest.len) : (index += 1) {
                const token = std.mem.trim(u8, rest[index], " \t\r\n");
                if (token.len == 0) continue;
                if (std.ascii.startsWithIgnoreCase(token, "--")) {
                    return self.authInvalidOutcome(allocator, trimmed_target, "auth.cancel", provider, account, try std.fmt.allocPrint(allocator, "Unknown status option `{s}`.", .{token}), "invalid_cancel_args", "invalid", "", null);
                }
                if (session_token.len == 0 and looksLikeLoginSessionID(token)) {
                    session_token = token;
                    continue;
                }
                if (std.mem.eql(u8, normalizeAccount(account), "default")) {
                    account = token;
                    continue;
                }
                return self.authInvalidOutcome(allocator, trimmed_target, "auth.cancel", provider, account, try allocator.dupe(u8, "Usage: `/auth status [provider] [account] [session_id]`"), "invalid_cancel_args", "invalid", "", null);
            }
            const bound_session = try self.getAuthBinding(allocator, target, provider, account);
            const login_session = if (std.mem.trim(u8, session_token, " \t\r\n").len > 0) session_token else bound_session;
            const has_login_session = std.mem.trim(u8, login_session, " \t\r\n").len > 0;
            const account_norm = normalizeAccount(account);
            const scope = try authScopeAlloc(allocator, provider, account_norm);
            defer allocator.free(scope);
            if (!has_login_session) {
                try self.clearAuthBinding(allocator, target, provider, account);
                const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                    .type = "auth.cancel",
                    .target = trimmed_target,
                    .provider = provider,
                    .account = account_norm,
                    .scope = scope,
                    .status = "none",
                });
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "No active auth session for this target."),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "none",
                    .metadata_json = metadata_json,
                };
            }
            const owned_login_session_id = if (std.mem.trim(u8, login_session, " \t\r\n").len > 0)
                try allocator.dupe(u8, login_session)
            else
                null;
            const login_session_label = if (owned_login_session_id) |value| value else login_session;
            const logout_session = login_session_label;
            const revoked = if (std.mem.trim(u8, logout_session, " \t\r\n").len > 0) self.login_manager.logout(logout_session) else false;
            try self.clearAuthBinding(allocator, target, provider, account);
            const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
                .type = "auth.cancel",
                .target = trimmed_target,
                .provider = provider,
                .account = account_norm,
                .scope = scope,
                .status = if (revoked) "cancelled" else "none",
                .loginSessionId = if (owned_login_session_id) |value| value else null,
                .revoked = revoked,
            });
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = if (std.mem.trim(u8, login_session_label, " \t\r\n").len > 0)
                    try std.fmt.allocPrint(allocator, "Auth session `{s}` cancelled.", .{login_session_label})
                else
                    try std.fmt.allocPrint(allocator, "Auth binding cleared for `{s}` account `{s}`.", .{ provider, normalizeAccount(account) }),
                .provider = provider,
                .model = defaultModelForProvider(provider),
                .login_session_id = if (owned_login_session_id) |value| value else "",
                .owned_login_session_id = owned_login_session_id,
                .login_code = "",
                .auth_status = "cancelled",
                .metadata_json = metadata_json,
            };
        }

        const metadata_json = try stringifyJsonAlloc(allocator, AuthCommandMetadata{
            .type = "auth.invalid",
            .target = trimmed_target,
            .provider = default_provider,
            .status = "invalid",
            .@"error" = "unknown_action",
        });
        return .{
            .is_command = true,
            .command_name = "auth",
            .reply = try allocator.dupe(u8, "Unknown `/auth` action. Use `/auth help` for full usage."),
            .provider = default_provider,
            .model = default_model,
            .login_session_id = "",
            .login_code = "",
            .auth_status = "invalid",
            .metadata_json = metadata_json,
        };
    }

    fn stringifyJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer);
        return out.toOwnedSlice();
    }

    fn authScopeAlloc(allocator: std.mem.Allocator, provider: []const u8, account: []const u8) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ normalizeProvider(provider), normalizeAccount(account) });
    }

    fn authExpiresInSeconds(expires_at_ms: i64) u32 {
        const remaining_ms = expires_at_ms - time_util.nowMs();
        if (remaining_ms <= 0) return 0;
        return @intCast(@divFloor(remaining_ms + 999, 1000));
    }

    fn buildAuthProvidersMetadataJson(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8) ![]u8 {
        const catalog = telegramAuthProviderCatalog();
        var providers = try allocator.alloc(AuthProviderMetadataEntry, catalog.len);
        defer allocator.free(providers);

        for (catalog, 0..) |entry, idx| {
            const profile = web_login.providerProfile(entry.id);
            providers[idx] = .{
                .id = entry.id,
                .providerId = entry.id,
                .name = entry.display_name,
                .displayName = entry.display_name,
                .aliases = entry.aliases,
                .verificationUrl = profile.verification_uri,
                .verificationUri = profile.verification_uri,
                .supportsBrowserSession = entry.supports_browser_session,
                .apiKeyConfigured = providerApiKeyConfigured(self, allocator, entry.id),
                .authMode = profile.auth_mode,
                .defaultModel = profile.default_model,
                .guestBypassSupported = profile.guest_bypass_supported,
                .popupBypassAction = profile.popup_bypass_action,
                .guestBypassHint = profile.guest_bypass_hint,
            };
        }

        return stringifyJsonAlloc(allocator, AuthCommandMetadata{
            .type = "auth.providers",
            .target = std.mem.trim(u8, target, " \t\r\n"),
            .providers = providers,
        });
    }

    fn buildAuthBridgeMetadataJson(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, provider_raw: []const u8) ![]u8 {
        const provider = normalizeProvider(provider_raw);
        const guidance = providerBridgeGuidance(provider);
        const summary = self.login_manager.status();
        const endpoint = std.mem.trim(u8, self.bridge_endpoint, " \t\r\n");
        const enabled = endpoint.len > 0;
        const probe = try lightpanda.probeEndpoint(allocator, endpoint);
        defer {
            allocator.free(probe.endpoint);
            allocator.free(probe.probeUrl);
            allocator.free(probe.errorText);
        }
        const bridge_status = bridgeProbeCompatStatus(probe);
        const reachable = bridgeProbeReachable(probe);

        return stringifyJsonAlloc(allocator, AuthCommandMetadata{
            .type = "auth.bridge",
            .target = std.mem.trim(u8, target, " \t\r\n"),
            .provider = provider,
            .bridge = .{
                .enabled = enabled,
                .status = bridge_status,
                .endpoint = probe.endpoint,
                .reachable = reachable,
                .httpStatus = probe.statusCode,
                .probeUrl = probe.probeUrl,
                .statusCode = probe.statusCode,
                .latencyMs = probe.latencyMs,
                .@"error" = probe.errorText,
                .sessions = summary,
                .guidance = guidance,
            },
        });
    }

    fn formatAuthProvidersMessage(self: *TelegramRuntime, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);

        try out.appendSlice(allocator, "Auth providers:");
        for (telegramAuthProviderCatalog(), 0..) |entry, idx| {
            const api_key_configured = providerApiKeyConfigured(self, allocator, entry.id);
            if (idx > 0) try out.appendSlice(allocator, ",");
            const line = try std.fmt.allocPrint(allocator, " {s} (browser:{s}, apiKey:{s})", .{
                entry.id,
                if (entry.supports_browser_session) "true" else "false",
                if (api_key_configured) "true" else "false",
            });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        }

        return out.toOwnedSlice(allocator);
    }

    fn formatBridgeStatusMessage(self: *TelegramRuntime, allocator: std.mem.Allocator, provider_raw: []const u8) ![]u8 {
        _ = provider_raw;
        const summary = self.login_manager.status();
        const endpoint = std.mem.trim(u8, self.bridge_endpoint, " \t\r\n");
        const probe = try lightpanda.probeEndpoint(allocator, endpoint);
        defer {
            allocator.free(probe.endpoint);
            allocator.free(probe.probeUrl);
            allocator.free(probe.errorText);
        }
        _ = summary;
        const bridge_status = bridgeProbeCompatStatus(probe);

        if (probe.errorText.len > 0) {
            return std.fmt.allocPrint(allocator, "Bridge `{s}` ({s}).\nProbe error: {s}", .{
                bridge_status,
                probe.endpoint,
                probe.errorText,
            });
        }
        return std.fmt.allocPrint(allocator, "Bridge `{s}` ({s}).", .{
            bridge_status,
            probe.endpoint,
        });
    }

    fn bridgeProbeCompatStatus(probe: lightpanda.BridgeProbe) []const u8 {
        if (std.mem.trim(u8, probe.endpoint, " \t\r\n").len == 0) return "missing-endpoint";
        if (probe.errorText.len > 0 and probe.statusCode == 0) return "unreachable";
        if (probe.statusCode >= 200 and probe.statusCode < 500) return "reachable";
        if (probe.statusCode > 0) return "unhealthy";
        return "unreachable";
    }

    fn bridgeProbeReachable(probe: lightpanda.BridgeProbe) bool {
        return probe.statusCode >= 200 and probe.statusCode < 500;
    }

    fn formatAuthUrlMessage(
        self: *TelegramRuntime,
        allocator: std.mem.Allocator,
        provider_raw: []const u8,
        account_norm: []const u8,
        view: web_login.SessionView,
    ) ![]u8 {
        _ = self;
        _ = provider_raw;
        _ = account_norm;
        return std.fmt.allocPrint(
            allocator,
            "Auth URL: {s}\nCode: `{s}`",
            .{ view.verificationUriComplete, view.code },
        );
    }

    fn enqueue(self: *TelegramRuntime, target: []const u8, session_id: []const u8, role: []const u8, kind: []const u8, message: []const u8) !void {
        const id = self.next_update_id;
        self.next_update_id += 1;
        try self.queue.append(self.allocator, .{
            .id = id,
            .to = try self.allocator.dupe(u8, target),
            .session_id = try self.allocator.dupe(u8, session_id),
            .role = try self.allocator.dupe(u8, role),
            .kind = try self.allocator.dupe(u8, kind),
            .message = try self.allocator.dupe(u8, message),
            .created_at_ms = time_util.nowMs(),
        });
        if (self.max_queue_entries > 0 and self.queue.items.len > self.max_queue_entries) {
            self.compactQueueFront(self.queue.items.len - self.max_queue_entries);
        }
        if (self.persistent) try self.persist();
    }

    fn setTargetModel(self: *TelegramRuntime, target: []const u8, provider: []const u8, model: []const u8) !void {
        const key = try self.allocator.dupe(u8, std.mem.trim(u8, target, " \t\r\n"));
        errdefer self.allocator.free(key);
        const value = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ normalizeProvider(provider), if (normalizeModel(model).len > 0) normalizeModel(model) else defaultModelForProvider(provider) });
        errdefer self.allocator.free(value);
        try self.setOrReplaceMapEntry(&self.target_models, key, value);
        if (self.persistent) try self.persist();
    }

    fn getTargetModel(self: *TelegramRuntime, target: []const u8) struct { provider: []const u8, model: []const u8 } {
        const key = std.mem.trim(u8, target, " \t\r\n");
        if (self.target_models.get(key)) |value| {
            if (std.mem.indexOfScalar(u8, value, '/')) |split| {
                return .{ .provider = value[0..split], .model = value[split + 1 ..] };
            }
        }
        return .{ .provider = "chatgpt", .model = "gpt-5.2" };
    }

    fn setAuthBinding(self: *TelegramRuntime, target: []const u8, provider: []const u8, account: []const u8, login_session_id: []const u8) !void {
        const key = try authBindingKey(self.allocator, target, provider, account);
        errdefer self.allocator.free(key);
        const account_is_default = std.mem.eql(u8, normalizeAccount(account), "default");
        if (std.mem.trim(u8, login_session_id, " \t\r\n").len == 0) {
            try self.setOrClearAuthBinding(key, "");
            if (account_is_default) {
                const legacy_key = try authBindingLegacyKey(self.allocator, target, provider);
                defer self.allocator.free(legacy_key);
                try self.setOrClearAuthBinding(legacy_key, "");
            }
            if (self.persistent) try self.persist();
            return;
        }
        const value = try self.allocator.dupe(u8, login_session_id);
        errdefer self.allocator.free(value);
        try self.setOrReplaceMapEntry(&self.auth_bindings, key, value);
        if (account_is_default) {
            const legacy_key = try authBindingLegacyKey(self.allocator, target, provider);
            const legacy_value = try self.allocator.dupe(u8, login_session_id);
            errdefer self.allocator.free(legacy_value);
            try self.setOrReplaceMapEntry(&self.auth_bindings, legacy_key, legacy_value);
        }
        if (self.persistent) try self.persist();
    }

    fn getAuthBinding(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, provider: []const u8, account: []const u8) ![]const u8 {
        const key = try authBindingKey(allocator, target, provider, account);
        defer allocator.free(key);
        if (self.auth_bindings.get(key)) |session| return session;

        const legacy_key = try authBindingLegacyKey(allocator, target, provider);
        defer allocator.free(legacy_key);
        if (self.auth_bindings.get(legacy_key)) |session| return session;
        return "";
    }

    fn clearAuthBinding(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, provider: []const u8, account: []const u8) !void {
        const key = try authBindingKey(allocator, target, provider, account);
        defer allocator.free(key);
        try self.setOrClearAuthBinding(key, "");

        if (std.mem.eql(u8, normalizeAccount(account), "default")) {
            const legacy_key = try authBindingLegacyKey(allocator, target, provider);
            defer allocator.free(legacy_key);
            try self.setOrClearAuthBinding(legacy_key, "");
        }
    }

    fn getAnyAuthBindingForProvider(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, provider: []const u8) ![]const u8 {
        const prefix = try std.fmt.allocPrint(allocator, "{s}::{s}::", .{
            std.mem.trim(u8, target, " \t\r\n"),
            normalizeProvider(provider),
        });
        defer allocator.free(prefix);
        var fallback: []const u8 = "";
        var it = self.auth_bindings.iterator();
        while (it.next()) |entry| {
            if (!std.ascii.startsWithIgnoreCase(entry.key_ptr.*, prefix)) continue;
            const session = entry.value_ptr.*;
            if (self.login_manager.get(session)) |view| {
                if (std.ascii.eqlIgnoreCase(view.status, "authorized")) return session;
            }
            if (fallback.len == 0) fallback = session;
        }
        return fallback;
    }

    fn setOrClearAuthBinding(self: *TelegramRuntime, key: []const u8, value: []const u8) !void {
        if (value.len == 0) {
            if (self.auth_bindings.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value);
            }
            if (self.persistent) try self.persist();
            return;
        }
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.setOrReplaceMapEntry(&self.auth_bindings, key_copy, value_copy);
        if (self.persistent) try self.persist();
    }

    fn setOrReplaceMapEntry(self: *TelegramRuntime, map: *std.StringHashMap([]u8), key: []u8, value: []u8) !void {
        if (map.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
        try map.put(key, value);
    }

    fn clearState(self: *TelegramRuntime) void {
        for (self.queue.items) |*entry| entry.deinit(self.allocator);
        self.queue.clearRetainingCapacity();

        var model_it = self.target_models.iterator();
        while (model_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.target_models.clearRetainingCapacity();

        var auth_it = self.auth_bindings.iterator();
        while (auth_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.auth_bindings.clearRetainingCapacity();

        self.next_update_id = 1;
        self.max_queue_entries = 4096;
    }

    fn load(self: *TelegramRuntime) !void {
        const path = self.state_path orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(raw);

        var parsed = try std.json.parseFromSlice(PersistedState, self.allocator, raw, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        self.clearState();

        self.max_queue_entries = parsed.value.maxQueueEntries;
        self.next_update_id = if (parsed.value.nextUpdateId == 0) 1 else parsed.value.nextUpdateId;
        self.tts_enabled = parsed.value.ttsEnabled;
        self.bridge_timeout_ms = std.math.clamp(
            if (parsed.value.bridgeTimeoutMs == 0) @as(u32, 15_000) else parsed.value.bridgeTimeoutMs,
            @as(u32, 500),
            @as(u32, 120_000),
        );

        if (parsed.value.ttsProvider.len > 0 and !std.mem.eql(u8, self.tts_provider, parsed.value.ttsProvider)) {
            const copied = try self.allocator.dupe(u8, parsed.value.ttsProvider);
            self.allocator.free(self.tts_provider);
            self.tts_provider = copied;
        }
        if (parsed.value.bridgeEndpoint.len > 0 and !std.mem.eql(u8, self.bridge_endpoint, parsed.value.bridgeEndpoint)) {
            const copied = try self.allocator.dupe(u8, parsed.value.bridgeEndpoint);
            self.allocator.free(self.bridge_endpoint);
            self.bridge_endpoint = copied;
        }

        for (parsed.value.targetModels) |entry| {
            const key = try self.allocator.dupe(u8, entry.key);
            errdefer self.allocator.free(key);
            const value = try self.allocator.dupe(u8, entry.value);
            errdefer self.allocator.free(value);
            try self.target_models.put(key, value);
        }

        for (parsed.value.authBindings) |entry| {
            const key = try self.allocator.dupe(u8, entry.key);
            errdefer self.allocator.free(key);
            const value = try self.allocator.dupe(u8, entry.value);
            errdefer self.allocator.free(value);
            try self.auth_bindings.put(key, value);
        }

        var max_seen_id: u64 = if (self.next_update_id == 0) 1 else self.next_update_id - 1;
        for (parsed.value.queue) |entry| {
            try self.queue.append(self.allocator, .{
                .id = entry.id,
                .to = try self.allocator.dupe(u8, entry.to),
                .session_id = try self.allocator.dupe(u8, entry.sessionId),
                .role = try self.allocator.dupe(u8, entry.role),
                .kind = try self.allocator.dupe(u8, entry.kind),
                .message = try self.allocator.dupe(u8, entry.message),
                .created_at_ms = entry.createdAtMs,
            });
            if (entry.id > max_seen_id) max_seen_id = entry.id;
        }
        if (self.next_update_id <= max_seen_id) self.next_update_id = max_seen_id + 1;
    }

    fn persist(self: *TelegramRuntime) !void {
        if (!self.persistent) return;
        const path = self.state_path orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();

        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        var targets = try self.allocator.alloc(PersistedMapEntry, self.target_models.count());
        defer self.allocator.free(targets);
        var target_idx: usize = 0;
        var target_it = self.target_models.iterator();
        while (target_it.next()) |entry| {
            targets[target_idx] = .{
                .key = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            };
            target_idx += 1;
        }

        var bindings = try self.allocator.alloc(PersistedMapEntry, self.auth_bindings.count());
        defer self.allocator.free(bindings);
        var bind_idx: usize = 0;
        var bind_it = self.auth_bindings.iterator();
        while (bind_it.next()) |entry| {
            bindings[bind_idx] = .{
                .key = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            };
            bind_idx += 1;
        }

        var queue = try self.allocator.alloc(PersistedQueuedMessage, self.queue.items.len);
        defer self.allocator.free(queue);
        for (self.queue.items, 0..) |entry, idx| {
            queue[idx] = .{
                .id = entry.id,
                .to = entry.to,
                .sessionId = entry.session_id,
                .role = entry.role,
                .kind = entry.kind,
                .message = entry.message,
                .createdAtMs = entry.created_at_ms,
            };
        }

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(.{
            .nextUpdateId = self.next_update_id,
            .maxQueueEntries = self.max_queue_entries,
            .ttsEnabled = self.tts_enabled,
            .ttsProvider = self.tts_provider,
            .bridgeEndpoint = self.bridge_endpoint,
            .bridgeTimeoutMs = self.bridge_timeout_ms,
            .targetModels = targets,
            .authBindings = bindings,
            .queue = queue,
        }, .{}, &out.writer);
        const payload = try out.toOwnedSlice();
        defer self.allocator.free(payload);

        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = payload,
        });
    }
};

fn getParamsObject(frame: std.json.Value) !std.json.Value {
    if (frame != .object) return error.InvalidParamsFrame;
    const params_value = frame.object.get("params") orelse return error.InvalidParamsFrame;
    if (params_value != .object) return error.InvalidParamsFrame;
    return params_value;
}

fn getOptionalString(params: std.json.Value, key: []const u8, fallback: []const u8) []const u8 {
    if (params.object.get(key)) |value| {
        if (value == .string) {
            const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
            if (trimmed.len > 0) return trimmed;
        }
    }
    return fallback;
}

fn getRequiredString(params: std.json.Value, key: []const u8, fallback_key: []const u8, err_tag: anyerror) ![]const u8 {
    const primary = getOptionalString(params, key, "");
    if (primary.len > 0) return primary;
    const fallback = getOptionalString(params, fallback_key, "");
    if (fallback.len > 0) return fallback;
    return err_tag;
}

fn getOptionalUsize(params: std.json.Value, key: []const u8, fallback: usize) usize {
    if (params.object.get(key)) |value| switch (value) {
        .integer => |raw| {
            if (raw > 0) return @as(usize, @intCast(raw));
        },
        .float => |raw| {
            if (raw > 0) return @as(usize, @intFromFloat(raw));
        },
        .string => |raw| {
            const trimmed = std.mem.trim(u8, raw, " \t\r\n");
            if (trimmed.len > 0) return std.fmt.parseInt(usize, trimmed, 10) catch fallback;
        },
        else => {},
    };
    return fallback;
}

fn authBindingLegacyKey(allocator: std.mem.Allocator, target: []const u8, provider: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ std.mem.trim(u8, target, " \t\r\n"), normalizeProvider(provider) });
}

fn authBindingKey(allocator: std.mem.Allocator, target: []const u8, provider: []const u8, account: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}::{s}::{s}", .{
        std.mem.trim(u8, target, " \t\r\n"),
        normalizeProvider(provider),
        normalizeAccount(account),
    });
}

fn normalizeAccount(account_raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, account_raw, " \t\r\n");
    return if (trimmed.len == 0) "default" else trimmed;
}

fn resolveStatePath(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, state_root, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "memory://telegram-runtime-state");
    if (isMemoryScheme(trimmed)) return allocator.dupe(u8, trimmed);
    if (std.mem.endsWith(u8, trimmed, ".json")) return allocator.dupe(u8, trimmed);
    return std.fs.path.join(allocator, &.{ trimmed, "telegram-runtime-state.json" });
}

fn shouldPersist(path: []const u8) bool {
    return !isMemoryScheme(path);
}

fn isMemoryScheme(path: []const u8) bool {
    const prefix = "memory://";
    if (path.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix);
}

fn looksLikeLoginSessionID(token_raw: []const u8) bool {
    const token = std.mem.trim(u8, token_raw, " \t\r\n");
    if (token.len == 0) return false;
    return std.ascii.startsWithIgnoreCase(token, "web-login-");
}

fn normalizeProvider(provider_raw: []const u8) []const u8 {
    return web_login.normalizeProviderAlias(provider_raw);
}

fn normalizeModel(model_raw: []const u8) []const u8 {
    return std.mem.trim(u8, model_raw, " \t\r\n");
}

fn maskSecretAlloc(allocator: std.mem.Allocator, value_raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, value_raw, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    if (trimmed.len <= 6) {
        const masked = try allocator.alloc(u8, trimmed.len);
        @memset(masked, '*');
        return masked;
    }

    var out = try allocator.alloc(u8, trimmed.len);
    @memcpy(out[0..3], trimmed[0..3]);
    @memset(out[3 .. trimmed.len - 3], '*');
    @memcpy(out[trimmed.len - 3 ..], trimmed[trimmed.len - 3 ..]);
    return out;
}

pub const TelegramModelDescriptor = struct {
    id: []const u8,
    provider: []const u8,
    name: []const u8,
    mode: []const u8,
    capability: []const u8,
    aliases: []const []const u8 = &.{},
};

const TelegramAuthProviderDescriptor = struct {
    id: []const u8,
    display_name: []const u8,
    aliases: []const []const u8,
    supports_browser_session: bool,
};

const TelegramModelChoice = struct {
    id: []const u8,
    provider: []const u8,
};

const ResolvedTelegramModelChoice = struct {
    id: []const u8,
    provider: []const u8,
    alias_used: ?[]const u8 = null,
};

const ParsedProviderScopedModelArgs = struct {
    provider: []const u8,
    model: []const u8,
    requested: ?[]const u8 = null,
    provider_scoped: bool,

    fn deinit(self: *ParsedProviderScopedModelArgs, allocator: std.mem.Allocator) void {
        if (self.requested) |requested| allocator.free(requested);
    }
};

fn telegramModelCatalog() []const TelegramModelDescriptor {
    return &[_]TelegramModelDescriptor{
        .{ .id = "gpt-5.2", .provider = "chatgpt", .name = "GPT-5.2", .mode = "auto", .capability = "reasoning", .aliases = &.{ "auto", "default", "gpt5-2", "gpt-5-2" } },
        .{ .id = "gpt-5.2-thinking", .provider = "chatgpt", .name = "GPT-5.2 Thinking", .mode = "thinking", .capability = "reasoning", .aliases = &.{ "extended", "extended-thinking", "reasoning" } },
        .{ .id = "gpt-5.2-pro", .provider = "chatgpt", .name = "GPT-5.2 Pro", .mode = "pro", .capability = "research", .aliases = &.{ "extended-pro", "research" } },
        .{ .id = "gpt-5.1-mini", .provider = "chatgpt", .name = "GPT-5.1 Mini", .mode = "instant", .capability = "fast-response", .aliases = &.{ "fast", "mini" } },
        .{ .id = "gpt-5.2", .provider = "codex", .name = "GPT-5.2 Codex", .mode = "pro", .capability = "coding", .aliases = &.{"codex"} },
        .{ .id = "claude-sonnet-4", .provider = "claude", .name = "Claude Sonnet 4", .mode = "thinking", .capability = "reasoning", .aliases = &.{ "sonnet-4", "claude-sonnet" } },
        .{ .id = "claude-opus-4", .provider = "claude", .name = "Claude Opus 4", .mode = "pro", .capability = "research", .aliases = &.{ "opus-4", "claude-opus" } },
        .{ .id = "gemini-2.5-pro", .provider = "gemini", .name = "Gemini 2.5 Pro", .mode = "pro", .capability = "reasoning", .aliases = &.{ "gemini-pro", "gemini-2.5" } },
        .{ .id = "qwen-max", .provider = "qwen", .name = "Qwen Max", .mode = "auto", .capability = "reasoning", .aliases = &.{ "qwen-default", "qwen-auto" } },
        .{ .id = "qwen3.5-397b-a17b", .provider = "qwen", .name = "Qwen 3.5 397B", .mode = "thinking", .capability = "reasoning", .aliases = &.{ "qwen35", "qwen3.5", "qwen-3.5" } },
        .{ .id = "qwen3.5-plus", .provider = "qwen", .name = "Qwen 3.5 Plus", .mode = "pro", .capability = "general", .aliases = &.{ "qwen-plus", "qwen-pro" } },
        .{ .id = "qwen3.5-flash", .provider = "qwen", .name = "Qwen 3.5 Flash", .mode = "instant", .capability = "fast-response", .aliases = &.{ "qwen-flash", "qwen-fast" } },
        .{ .id = "qwen3-0.6b", .provider = "qwen", .name = "Qwen 3 0.6B", .mode = "instant", .capability = "small-fast", .aliases = &.{ "qwen-0.6b", "qwen3-0.6b-instruct" } },
        .{ .id = "qwen3-1.7b", .provider = "qwen", .name = "Qwen 3 1.7B", .mode = "instant", .capability = "small-fast", .aliases = &.{ "qwen-1.7b", "qwen3-1.7b-instruct" } },
        .{ .id = "qwen3-4b", .provider = "qwen", .name = "Qwen 3 4B", .mode = "instant", .capability = "small-balanced", .aliases = &.{ "qwen-4b", "qwen3-4b-instruct" } },
        .{ .id = "qwen3-8b", .provider = "qwen", .name = "Qwen 3 8B", .mode = "thinking", .capability = "balanced", .aliases = &.{ "qwen-8b", "qwen3-8b-instruct" } },
        .{ .id = "glm-5", .provider = "zai", .name = "GLM-5", .mode = "thinking", .capability = "reasoning", .aliases = &.{ "zai-glm-5", "glm5", "glm-5" } },
        .{ .id = "mercury-2", .provider = "inception", .name = "Mercury 2", .mode = "thinking", .capability = "reasoning", .aliases = &.{ "mercury", "mercury2" } },
        .{ .id = "openrouter/auto", .provider = "openrouter", .name = "OpenRouter Auto", .mode = "auto", .capability = "routing", .aliases = &.{ "openrouter-auto", "router-auto" } },
        .{ .id = "openrouter/qwen/qwen3-coder:free", .provider = "openrouter", .name = "OpenRouter Qwen3 Coder Free", .mode = "instant", .capability = "coding", .aliases = &.{ "qwen3-coder-free", "openrouter-qwen3-coder-free" } },
        .{ .id = "opencode/default", .provider = "opencode", .name = "OpenCode Default", .mode = "auto", .capability = "coding", .aliases = &.{ "opencode-auto", "opencode-default" } },
        .{ .id = "opencode/qwen3-coder-30b-a3b-instruct", .provider = "opencode", .name = "OpenCode Qwen3 Coder 30B", .mode = "instant", .capability = "coding", .aliases = &.{ "qwen3-coder-30b-a3b-instruct", "opencode-coder-30b" } },
        .{ .id = "minimax-m2.5", .provider = "minimax", .name = "MiniMax M2.5", .mode = "auto", .capability = "general", .aliases = &.{ "minimax", "m2.5" } },
        .{ .id = "kimi-k2.5", .provider = "kimi", .name = "Kimi K2.5", .mode = "auto", .capability = "reasoning", .aliases = &.{ "kimi", "kimi-code" } },
        .{ .id = "glm-4.6", .provider = "zhipuai", .name = "GLM-4.6", .mode = "auto", .capability = "reasoning", .aliases = &.{ "zhipu", "zhipu-glm", "bigmodel-glm" } },
    };
}

fn telegramAuthProviderCatalog() []const TelegramAuthProviderDescriptor {
    return &[_]TelegramAuthProviderDescriptor{
        .{ .id = "chatgpt", .display_name = "ChatGPT", .aliases = &.{ "openai", "openai-chatgpt", "chatgpt-web", "chatgpt.com" }, .supports_browser_session = true },
        .{ .id = "codex", .display_name = "Codex", .aliases = &.{ "openai-codex", "codex-cli", "openai-codex-cli" }, .supports_browser_session = true },
        .{ .id = "claude", .display_name = "Claude", .aliases = &.{ "anthropic", "claude-cli", "claude-code", "claude-desktop" }, .supports_browser_session = false },
        .{ .id = "gemini", .display_name = "Gemini", .aliases = &.{ "google", "google-gemini", "google-gemini-cli", "gemini-cli" }, .supports_browser_session = false },
        .{ .id = "qwen", .display_name = "Qwen", .aliases = &.{ "qwen-portal", "qwen-cli", "qwen-chat", "qwen35", "qwen3.5", "qwen-3.5", "copaw", "qwen-copaw", "qwen-agent" }, .supports_browser_session = true },
        .{ .id = "minimax", .display_name = "MiniMax", .aliases = &.{ "minimax-portal", "minimax-cli" }, .supports_browser_session = false },
        .{ .id = "kimi", .display_name = "Kimi", .aliases = &.{ "kimi-code", "kimi-coding", "kimi-for-coding" }, .supports_browser_session = true },
        .{ .id = "opencode", .display_name = "OpenCode", .aliases = &.{ "opencode-zen", "opencode-ai", "opencode-go", "opencode_free", "opencodefree" }, .supports_browser_session = false },
        .{ .id = "zhipuai", .display_name = "Zhipu AI", .aliases = &.{ "zhipu", "zhipu-ai", "bigmodel", "bigmodel-cn", "zhipuai-coding", "zhipu-coding" }, .supports_browser_session = false },
        .{ .id = "openrouter", .display_name = "OpenRouter", .aliases = &.{"openrouter-ai"}, .supports_browser_session = true },
        .{ .id = "zai", .display_name = "Z.ai", .aliases = &.{ "z.ai", "z-ai", "zaiweb", "zai-web", "glm", "glm5", "glm-5" }, .supports_browser_session = true },
        .{ .id = "inception", .display_name = "Inception", .aliases = &.{ "inception-labs", "inceptionlabs", "mercury", "mercury2", "mercury-2" }, .supports_browser_session = true },
    };
}

fn normalizeModelAliasAlloc(allocator: std.mem.Allocator, model_raw: []const u8) ![]u8 {
    const trimmed = normalizeModel(model_raw);
    var normalized = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |ch, idx| {
        const lower = std.ascii.toLower(ch);
        normalized[idx] = switch (lower) {
            '_', '.', ' ', '/' => '-',
            else => lower,
        };
    }
    return normalized;
}

fn parseProviderScopedModelArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !ParsedProviderScopedModelArgs {
    if (args.len == 0) {
        return .{
            .provider = "",
            .model = "",
            .requested = null,
            .provider_scoped = false,
        };
    }

    const first = std.mem.trim(u8, args[0], " \t\r\n");
    if (first.len == 0) {
        return .{
            .provider = "",
            .model = "",
            .requested = null,
            .provider_scoped = false,
        };
    }

    if (std.mem.indexOfScalar(u8, first, '/')) |split| {
        const provider_raw = std.mem.trim(u8, first[0..split], " \t\r\n");
        const provider = if (provider_raw.len == 0) "" else normalizeProvider(provider_raw);
        const requested = if (args.len > 1) try std.mem.join(allocator, " ", args) else null;
        const joined_model = if (args.len > 1)
            std.mem.trim(u8, requested.?[split + 1 ..], " \t\r\n")
        else
            normalizeModel(first[split + 1 ..]);
        return .{
            .provider = provider,
            .model = joined_model,
            .requested = requested,
            .provider_scoped = true,
        };
    }

    if (args.len >= 2) {
        const provider = normalizeProvider(first);
        const requested = try std.mem.join(allocator, " ", args);
        const model = std.mem.trim(u8, requested[first.len..], " \t\r\n");
        return .{
            .provider = provider,
            .model = model,
            .requested = requested,
            .provider_scoped = true,
        };
    }

    return .{
        .provider = "",
        .model = "",
        .requested = null,
        .provider_scoped = false,
    };
}

fn modelAliasMatches(allocator: std.mem.Allocator, candidate: []const u8, normalized_requested: []const u8) !bool {
    const normalized = try normalizeModelAliasAlloc(allocator, candidate);
    defer allocator.free(normalized);
    return std.mem.eql(u8, normalized, normalized_requested);
}

fn isKnownModelProviderInCatalog(catalog: []const TelegramModelDescriptor, provider_raw: []const u8) bool {
    const provider = normalizeProvider(provider_raw);
    if (provider.len == 0) return false;
    for (catalog) |descriptor| {
        if (std.ascii.eqlIgnoreCase(descriptor.provider, provider)) return true;
    }
    return false;
}

fn isKnownModelProvider(provider_raw: []const u8) bool {
    return isKnownModelProviderInCatalog(telegramModelCatalog(), provider_raw);
}

fn listTelegramModelProvidersFromCatalogAlloc(allocator: std.mem.Allocator, catalog: []const TelegramModelDescriptor) ![]const []const u8 {
    var providers: std.ArrayList([]const u8) = .empty;
    defer providers.deinit(allocator);

    for (catalog) |descriptor| {
        var seen = false;
        for (providers.items) |existing| {
            if (std.mem.eql(u8, existing, descriptor.provider)) {
                seen = true;
                break;
            }
        }
        if (!seen) try providers.append(allocator, descriptor.provider);
    }

    std.mem.sort([]const u8, providers.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    return providers.toOwnedSlice(allocator);
}

fn listTelegramModelProvidersAlloc(allocator: std.mem.Allocator) ![]const []const u8 {
    return listTelegramModelProvidersFromCatalogAlloc(allocator, telegramModelCatalog());
}

fn listTelegramModelIDsFromCatalogAlloc(
    allocator: std.mem.Allocator,
    catalog: []const TelegramModelDescriptor,
    provider_filter_raw: []const u8,
) ![]const []const u8 {
    const provider_filter = blk: {
        const trimmed = std.mem.trim(u8, provider_filter_raw, " \t\r\n");
        break :blk if (trimmed.len == 0) "" else normalizeProvider(trimmed);
    };
    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(allocator);

    for (catalog) |descriptor| {
        if (provider_filter.len > 0 and !std.ascii.eqlIgnoreCase(descriptor.provider, provider_filter)) continue;
        var seen = false;
        for (ids.items) |existing| {
            if (std.ascii.eqlIgnoreCase(existing, descriptor.id)) {
                seen = true;
                break;
            }
        }
        if (!seen) try ids.append(allocator, descriptor.id);
    }

    return ids.toOwnedSlice(allocator);
}

fn listTelegramModelIDsAlloc(allocator: std.mem.Allocator, provider_filter_raw: []const u8) ![]const []const u8 {
    return listTelegramModelIDsFromCatalogAlloc(allocator, telegramModelCatalog(), provider_filter_raw);
}

fn listTelegramModelDescriptorsFromCatalogAlloc(
    allocator: std.mem.Allocator,
    catalog: []const TelegramModelDescriptor,
    provider_filter_raw: []const u8,
) ![]TelegramModelDescriptor {
    const provider_filter = blk: {
        const trimmed = std.mem.trim(u8, provider_filter_raw, " \t\r\n");
        break :blk if (trimmed.len == 0) "" else normalizeProvider(trimmed);
    };
    var descriptors: std.ArrayList(TelegramModelDescriptor) = .empty;
    defer descriptors.deinit(allocator);

    for (catalog) |descriptor| {
        if (provider_filter.len > 0 and !std.ascii.eqlIgnoreCase(descriptor.provider, provider_filter)) continue;
        try descriptors.append(allocator, descriptor);
    }

    return descriptors.toOwnedSlice(allocator);
}

fn listTelegramModelDescriptorsAlloc(allocator: std.mem.Allocator, provider_filter_raw: []const u8) ![]TelegramModelDescriptor {
    return listTelegramModelDescriptorsFromCatalogAlloc(allocator, telegramModelCatalog(), provider_filter_raw);
}

fn resolveTelegramModelChoiceDetailedInCatalog(
    allocator: std.mem.Allocator,
    catalog: []const TelegramModelDescriptor,
    model_raw: []const u8,
) !?ResolvedTelegramModelChoice {
    const normalized_requested = try normalizeModelAliasAlloc(allocator, model_raw);
    defer allocator.free(normalized_requested);
    if (normalized_requested.len == 0) return null;

    for (catalog) |descriptor| {
        if (try modelAliasMatches(allocator, descriptor.id, normalized_requested)) {
            return .{ .id = descriptor.id, .provider = descriptor.provider };
        }
    }

    const requested = normalizeModel(model_raw);
    for (catalog) |descriptor| {
        if (descriptor.mode.len > 0 and try modelAliasMatches(allocator, descriptor.mode, normalized_requested)) {
            return .{ .id = descriptor.id, .provider = descriptor.provider, .alias_used = requested };
        }
        if (descriptor.name.len > 0 and try modelAliasMatches(allocator, descriptor.name, normalized_requested)) {
            return .{ .id = descriptor.id, .provider = descriptor.provider, .alias_used = requested };
        }
        for (descriptor.aliases) |alias| {
            if (try modelAliasMatches(allocator, alias, normalized_requested)) {
                return .{ .id = descriptor.id, .provider = descriptor.provider, .alias_used = requested };
            }
        }
    }

    return null;
}

fn resolveTelegramModelChoiceDetailed(allocator: std.mem.Allocator, model_raw: []const u8) !?ResolvedTelegramModelChoice {
    return resolveTelegramModelChoiceDetailedInCatalog(allocator, telegramModelCatalog(), model_raw);
}

fn resolveTelegramModelChoice(allocator: std.mem.Allocator, model_raw: []const u8) !?TelegramModelChoice {
    const resolved = try resolveTelegramModelChoiceDetailedInCatalog(allocator, telegramModelCatalog(), model_raw) orelse return null;
    return .{ .id = resolved.id, .provider = resolved.provider };
}

fn resolveTelegramModelChoiceForProvider(
    allocator: std.mem.Allocator,
    provider_raw: []const u8,
    model_raw: []const u8,
) !?TelegramModelChoice {
    const resolved = try resolveTelegramModelChoiceForProviderDetailed(allocator, provider_raw, model_raw) orelse return null;
    return .{ .id = resolved.id, .provider = resolved.provider };
}

fn resolveTelegramModelChoiceForProviderDetailed(
    allocator: std.mem.Allocator,
    provider_raw: []const u8,
    model_raw: []const u8,
) !?ResolvedTelegramModelChoice {
    return resolveTelegramModelChoiceForProviderDetailedInCatalog(allocator, telegramModelCatalog(), provider_raw, model_raw);
}

fn resolveTelegramModelChoiceForProviderDetailedInCatalog(
    allocator: std.mem.Allocator,
    catalog: []const TelegramModelDescriptor,
    provider_raw: []const u8,
    model_raw: []const u8,
) !?ResolvedTelegramModelChoice {
    const provider = normalizeProvider(provider_raw);
    const normalized_requested = try normalizeModelAliasAlloc(allocator, model_raw);
    defer allocator.free(normalized_requested);
    if (provider.len == 0 or normalized_requested.len == 0) return null;

    for (catalog) |descriptor| {
        if (!std.ascii.eqlIgnoreCase(descriptor.provider, provider)) continue;
        if (try modelAliasMatches(allocator, descriptor.id, normalized_requested)) {
            return .{ .id = descriptor.id, .provider = descriptor.provider };
        }
        if (std.mem.indexOfScalar(u8, descriptor.id, '/')) |split| {
            const scoped_id = descriptor.id[split + 1 ..];
            if (scoped_id.len > 0 and try modelAliasMatches(allocator, scoped_id, normalized_requested)) {
                return .{ .id = descriptor.id, .provider = descriptor.provider };
            }
        }
        if (descriptor.mode.len > 0 and try modelAliasMatches(allocator, descriptor.mode, normalized_requested)) {
            return .{ .id = descriptor.id, .provider = descriptor.provider, .alias_used = normalizeModel(model_raw) };
        }
        if (descriptor.name.len > 0 and try modelAliasMatches(allocator, descriptor.name, normalized_requested)) {
            return .{ .id = descriptor.id, .provider = descriptor.provider, .alias_used = normalizeModel(model_raw) };
        }
        for (descriptor.aliases) |alias| {
            if (try modelAliasMatches(allocator, alias, normalized_requested)) {
                return .{ .id = descriptor.id, .provider = descriptor.provider, .alias_used = normalizeModel(model_raw) };
            }
        }
    }

    return null;
}

fn nextTelegramModelChoiceInCatalog(catalog: []const TelegramModelDescriptor, current_model_raw: []const u8) TelegramModelChoice {
    const current_model = normalizeModel(current_model_raw);
    if (catalog.len == 0) return .{ .id = "gpt-5.2", .provider = "chatgpt" };

    var current_index: ?usize = null;
    for (catalog, 0..) |descriptor, idx| {
        if (std.ascii.eqlIgnoreCase(descriptor.id, current_model)) {
            current_index = idx;
            break;
        }
    }

    const next_index = if (current_index) |idx| (idx + 1) % catalog.len else 0;
    return .{ .id = catalog[next_index].id, .provider = catalog[next_index].provider };
}

fn nextTelegramModelChoice(current_model_raw: []const u8) TelegramModelChoice {
    return nextTelegramModelChoiceInCatalog(telegramModelCatalog(), current_model_raw);
}

fn modelRefForDisplayAlloc(allocator: std.mem.Allocator, provider_raw: []const u8, model_raw: []const u8) ![]u8 {
    const provider = normalizeProvider(provider_raw);
    const model = normalizeModel(model_raw);
    if (provider.len > 0 and model.len > provider.len + 1 and std.mem.startsWith(u8, model, provider) and model[provider.len] == '/') {
        return allocator.dupe(u8, model);
    }
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ provider, model });
}

fn defaultModelForProviderInCatalog(catalog: []const TelegramModelDescriptor, provider_raw: []const u8) ?[]const u8 {
    const provider = normalizeProvider(provider_raw);
    if (provider.len == 0) return null;
    for (catalog) |descriptor| {
        if (std.ascii.eqlIgnoreCase(descriptor.provider, provider)) return descriptor.id;
    }
    return null;
}

fn defaultModelForProvider(provider_raw: []const u8) []const u8 {
    return defaultModelForProviderInCatalog(telegramModelCatalog(), provider_raw) orelse "gpt-5.2";
}

fn isKnownProvider(provider_raw: []const u8) bool {
    const normalized = normalizeProvider(provider_raw);
    for ([_][]const u8{ "chatgpt", "codex", "claude", "gemini", "openrouter", "opencode", "qwen", "zai", "inception", "minimax", "kimi", "zhipuai" }) |entry| {
        if (std.ascii.eqlIgnoreCase(normalized, entry)) return true;
    }
    return false;
}

fn inferProviderFromAuthInput(input_raw: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, input_raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (!std.mem.containsAtLeast(u8, trimmed, 1, "://")) return null;

    if (containsIgnoreCase(trimmed, "chat.qwen.ai")) return "qwen";
    if (containsIgnoreCase(trimmed, "chat.z.ai")) return "zai";
    if (containsIgnoreCase(trimmed, "inceptionlabs.ai")) return "inception";
    if (containsIgnoreCase(trimmed, "chatgpt.com")) return "chatgpt";
    if (containsIgnoreCase(trimmed, "claude.ai")) return "claude";
    if (containsIgnoreCase(trimmed, "aistudio.google.com")) return "gemini";
    if (containsIgnoreCase(trimmed, "openrouter.ai")) return "openrouter";
    if (containsIgnoreCase(trimmed, "opencode.ai")) return "opencode";
    return null;
}

fn providerBridgeGuidance(provider_raw: []const u8) []const u8 {
    const provider = normalizeProvider(provider_raw);
    if (std.ascii.eqlIgnoreCase(provider, "qwen")) {
        return "Browser bridge: lightpanda\nProvider: qwen\nFlow: open https://chat.qwen.ai and if popup appears click 'Stay logged out'.\nThen run: /auth guest qwen [account]";
    }
    if (std.ascii.eqlIgnoreCase(provider, "zai")) {
        return "Browser bridge: lightpanda\nProvider: zai (glm-5)\nFlow: open https://chat.z.ai and click 'Stay logged out' on login prompts.\nThen run: /auth guest zai [account]";
    }
    if (std.ascii.eqlIgnoreCase(provider, "inception")) {
        return "Browser bridge: lightpanda\nProvider: inception (mercury-2)\nFlow: open https://chat.inceptionlabs.ai and stay in guest mode.\nThen run: /auth guest inception [account]";
    }
    return "Browser bridge: lightpanda\nFlow: start auth and complete with callback URL or code.\nCommand: /auth complete <provider> <callback_url_or_code> [session_id] [account]";
}

fn providerApiKeyConfigured(self: *TelegramRuntime, allocator: std.mem.Allocator, provider_raw: []const u8) bool {
    const resolved = resolveProviderApiKey(self, allocator, provider_raw) catch return false;
    if (resolved) |value| {
        allocator.free(value);
        return true;
    }
    return false;
}

fn resolveProviderApiKey(self: *TelegramRuntime, allocator: std.mem.Allocator, provider_raw: []const u8) !?[]u8 {
    const provider = normalizeProvider(provider_raw);

    if (self.provider_api_key_resolver) |resolver| {
        if (self.provider_api_key_resolver_ctx) |ctx| {
            if (try resolver(ctx, allocator, provider)) |value| {
                const trimmed = std.mem.trim(u8, value, " \t\r\n");
                if (trimmed.len > 0) {
                    if (trimmed.ptr == value.ptr and trimmed.len == value.len) return value;
                    defer allocator.free(value);
                    return try allocator.dupe(u8, trimmed);
                }
                allocator.free(value);
            }
        }
    }

    if (std.ascii.eqlIgnoreCase(provider, "chatgpt") or std.ascii.eqlIgnoreCase(provider, "codex")) {
        return envFirstValueAlloc(allocator, &[_][]const u8{
            "OPENAI_API_KEY",
            "OPENCLAW_ZIG_OPENAI_API_KEY",
            "OPENCLAW_GO_OPENAI_API_KEY",
            "OPENCLAW_RS_OPENAI_API_KEY",
            "OPENCLAW_ZIG_BROWSER_OPENAI_API_KEY",
        });
    }
    if (std.ascii.eqlIgnoreCase(provider, "claude")) {
        return envFirstValueAlloc(allocator, &[_][]const u8{
            "ANTHROPIC_API_KEY",
            "OPENCLAW_ZIG_ANTHROPIC_API_KEY",
            "OPENCLAW_GO_ANTHROPIC_API_KEY",
            "OPENCLAW_RS_ANTHROPIC_API_KEY",
            "OPENCLAW_ZIG_BROWSER_ANTHROPIC_API_KEY",
        });
    }
    if (std.ascii.eqlIgnoreCase(provider, "gemini")) {
        return envFirstValueAlloc(allocator, &[_][]const u8{
            "GOOGLE_API_KEY",
            "GEMINI_API_KEY",
            "OPENCLAW_ZIG_GEMINI_API_KEY",
            "OPENCLAW_GO_GEMINI_API_KEY",
            "OPENCLAW_RS_GEMINI_API_KEY",
            "OPENCLAW_ZIG_BROWSER_GEMINI_API_KEY",
        });
    }
    if (std.ascii.eqlIgnoreCase(provider, "openrouter")) {
        return envFirstValueAlloc(allocator, &[_][]const u8{
            "OPENROUTER_API_KEY",
            "OPENROUTER_KEY",
            "OPENCLAW_ZIG_OPENROUTER_API_KEY",
            "OPENCLAW_GO_OPENROUTER_API_KEY",
            "OPENCLAW_RS_OPENROUTER_API_KEY",
        });
    }
    if (std.ascii.eqlIgnoreCase(provider, "opencode")) {
        return envFirstValueAlloc(allocator, &[_][]const u8{
            "OPENCODE_API_KEY",
            "OPENCODE_ZEN_API_KEY",
            "OPENCLAW_ZIG_OPENCODE_API_KEY",
            "OPENCLAW_GO_OPENCODE_API_KEY",
            "OPENCLAW_RS_OPENCODE_API_KEY",
        });
    }

    return null;
}

fn envFirstValueAlloc(allocator: std.mem.Allocator, names: []const []const u8) !?[]u8 {
    for (names) |name| {
        const raw = std.process.Environ.getAlloc(process_environ, allocator, name) catch |err| switch (err) {
            error.EnvironmentVariableMissing => continue,
            error.InvalidWtf8 => continue,
            else => continue,
        };
        defer allocator.free(raw);
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
    }
    return null;
}

fn normalizeTtsProvider(raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return "";
    if (std.ascii.eqlIgnoreCase(trimmed, "openai-voice")) return "openai";
    if (std.ascii.eqlIgnoreCase(trimmed, "native")) return "edge";
    if (std.ascii.eqlIgnoreCase(trimmed, "openai")) return "openai";
    if (std.ascii.eqlIgnoreCase(trimmed, "elevenlabs")) return "elevenlabs";
    if (std.ascii.eqlIgnoreCase(trimmed, "kittentts")) return "kittentts";
    if (std.ascii.eqlIgnoreCase(trimmed, "edge")) return "edge";
    return trimmed;
}

fn ttsProviderMetadataId(raw: []const u8) []const u8 {
    const provider = normalizeTtsProvider(raw);
    if (std.ascii.eqlIgnoreCase(provider, "edge")) return "native";
    if (std.ascii.eqlIgnoreCase(provider, "openai")) return "openai-voice";
    return provider;
}

fn ttsProviderMetadataName(provider_raw: []const u8) []const u8 {
    const provider = ttsProviderMetadataId(provider_raw);
    if (std.ascii.eqlIgnoreCase(provider, "native")) return "Native Synth";
    if (std.ascii.eqlIgnoreCase(provider, "openai-voice")) return "OpenAI Voice";
    if (std.ascii.eqlIgnoreCase(provider, "kittentts")) return "KittenTTS";
    if (std.ascii.eqlIgnoreCase(provider, "elevenlabs")) return "ElevenLabs";
    return provider;
}

fn isSupportedTtsProvider(raw: []const u8) bool {
    const provider = normalizeTtsProvider(raw);
    if (provider.len == 0) return false;
    return std.ascii.eqlIgnoreCase(provider, "openai") or
        std.ascii.eqlIgnoreCase(provider, "elevenlabs") or
        std.ascii.eqlIgnoreCase(provider, "kittentts") or
        std.ascii.eqlIgnoreCase(provider, "edge");
}

fn envHasValue(allocator: std.mem.Allocator, name: []const u8) bool {
    const raw = std.process.Environ.getAlloc(process_environ, allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return false,
        error.InvalidWtf8 => return false,
        else => return false,
    };
    defer allocator.free(raw);
    return std.mem.trim(u8, raw, " \t\r\n").len > 0;
}

fn envHasAnyValue(allocator: std.mem.Allocator, names: []const []const u8) bool {
    for (names) |name| {
        if (envHasValue(allocator, name)) return true;
    }
    return false;
}

fn ttsProviderAvailable(allocator: std.mem.Allocator, provider_raw: []const u8) bool {
    const provider = normalizeTtsProvider(provider_raw);
    if (std.ascii.eqlIgnoreCase(provider, "edge")) return true;
    if (std.ascii.eqlIgnoreCase(provider, "openai")) return ttsProviderApiKeyAvailable(allocator, "openai");
    if (std.ascii.eqlIgnoreCase(provider, "elevenlabs")) return ttsProviderApiKeyAvailable(allocator, "elevenlabs");
    if (std.ascii.eqlIgnoreCase(provider, "kittentts")) return kittenttsBinaryAvailable(allocator);
    return false;
}

fn ttsProviderReason(allocator: std.mem.Allocator, provider_raw: []const u8) []const u8 {
    const provider = normalizeTtsProvider(provider_raw);
    if (std.ascii.eqlIgnoreCase(provider, "edge")) return "built-in synthetic fallback";
    if (std.ascii.eqlIgnoreCase(provider, "openai")) {
        return if (ttsProviderApiKeyAvailable(allocator, "openai")) "api key available" else "api key missing";
    }
    if (std.ascii.eqlIgnoreCase(provider, "elevenlabs")) {
        return if (ttsProviderApiKeyAvailable(allocator, "elevenlabs")) "api key available" else "api key missing";
    }
    if (std.ascii.eqlIgnoreCase(provider, "kittentts")) {
        return if (kittenttsBinaryAvailable(allocator)) "kittentts binary available" else "kittentts binary not found";
    }
    return "";
}

fn buildTtsProviderCatalogAlloc(allocator: std.mem.Allocator) ![]TtsProviderMetadataEntry {
    const provider_ids = [_][]const u8{ "native", "openai-voice", "kittentts", "elevenlabs" };
    var providers = try allocator.alloc(TtsProviderMetadataEntry, provider_ids.len);
    for (provider_ids, 0..) |provider_id, idx| {
        providers[idx] = .{
            .id = provider_id,
            .name = ttsProviderMetadataName(provider_id),
            .enabled = ttsProviderAvailable(allocator, provider_id),
            .available = ttsProviderAvailable(allocator, provider_id),
            .requiresAuth = if (std.ascii.eqlIgnoreCase(provider_id, "elevenlabs")) true else null,
            .reason = ttsProviderReason(allocator, provider_id),
        };
    }
    return providers;
}

fn buildTelegramTtsAudioRefAlloc(allocator: std.mem.Allocator, provider_raw: []const u8, output_format: []const u8) ![]u8 {
    const provider = ttsProviderMetadataId(provider_raw);
    const format = if (std.mem.trim(u8, output_format, " \t\r\n").len > 0) output_format else "wav";
    return std.fmt.allocPrint(allocator, "memory://tts/{s}-{d}.{s}", .{ provider, time_util.nowMs(), format });
}

fn formatTtsProviderSummaryAlloc(
    allocator: std.mem.Allocator,
    providers: []const TtsProviderMetadataEntry,
) ![]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |entry| allocator.free(entry);
        lines.deinit(allocator);
    }

    for (providers) |provider| {
        try lines.append(allocator, try std.fmt.allocPrint(allocator, "{s} ({any})", .{ provider.id, provider.enabled }));
    }

    return std.mem.join(allocator, ", ", lines.items);
}

fn ttsProviderApiKeyAvailable(allocator: std.mem.Allocator, provider_raw: []const u8) bool {
    const provider = normalizeTtsProvider(provider_raw);
    if (std.ascii.eqlIgnoreCase(provider, "openai")) {
        return envHasAnyValue(allocator, &[_][]const u8{
            "OPENAI_API_KEY",
            "OPENCLAW_ZIG_TTS_OPENAI_API_KEY",
            "OPENCLAW_GO_TTS_OPENAI_API_KEY",
            "OPENCLAW_RS_TTS_OPENAI_API_KEY",
        });
    }
    if (std.ascii.eqlIgnoreCase(provider, "elevenlabs")) {
        return envHasAnyValue(allocator, &[_][]const u8{
            "ELEVENLABS_API_KEY",
            "OPENCLAW_ZIG_TTS_ELEVENLABS_API_KEY",
            "OPENCLAW_GO_TTS_ELEVENLABS_API_KEY",
            "OPENCLAW_RS_TTS_ELEVENLABS_API_KEY",
        });
    }
    return false;
}

fn kittenttsBinaryAvailable(allocator: std.mem.Allocator) bool {
    return envHasAnyValue(allocator, &[_][]const u8{
        "OPENCLAW_ZIG_KITTENTTS_BIN",
        "OPENCLAW_GO_KITTENTTS_BIN",
        "OPENCLAW_GO_TTS_KITTENTTS_BIN",
        "OPENCLAW_RS_KITTENTTS_BIN",
    });
}

fn resolveTtsSource(allocator: std.mem.Allocator, provider_used: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(provider_used, "openai") and ttsProviderApiKeyAvailable(allocator, "openai")) return "remote";
    if (std.ascii.eqlIgnoreCase(provider_used, "elevenlabs") and ttsProviderApiKeyAvailable(allocator, "elevenlabs")) return "remote";
    if (std.ascii.eqlIgnoreCase(provider_used, "kittentts") and kittenttsBinaryAvailable(allocator)) return "offline-local";
    return "simulated";
}

fn synthesizeTelegramTtsClipBase64(
    allocator: std.mem.Allocator,
    text: []const u8,
    provider_used: []const u8,
    source: []const u8,
) ![]u8 {
    var audio = std.ArrayList(u8).empty;
    defer audio.deinit(allocator);
    try audio.appendSlice(allocator, "RIFF");
    try audio.appendSlice(allocator, provider_used);
    try audio.appendSlice(allocator, ":");
    try audio.appendSlice(allocator, source);
    try audio.appendSlice(allocator, ":");
    const clip_text_len = @min(text.len, 1024);
    try audio.appendSlice(allocator, text[0..clip_text_len]);
    const raw = try audio.toOwnedSlice(allocator);
    defer allocator.free(raw);

    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(raw.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, raw);
    return encoded;
}

fn base64DecodedLen(encoded: []const u8) usize {
    if (encoded.len == 0) return 0;
    var padding: usize = 0;
    if (encoded.len >= 1 and encoded[encoded.len - 1] == '=') padding += 1;
    if (encoded.len >= 2 and encoded[encoded.len - 2] == '=') padding += 1;
    return (encoded.len / 4) * 3 - padding;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var idx: usize = 0;
    while (idx + needle.len <= haystack.len) : (idx += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[idx .. idx + needle.len], needle)) return true;
    }
    return false;
}

test "telegram runtime model command lifecycle" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    const set_frame =
        \\{"id":"tg-model","method":"send","params":{"channel":"telegram","to":"room-a","sessionId":"sess-a","message":"/model qwen/qwen3-coder"}}
    ;
    var set_result = try runtime.sendFromFrame(allocator, set_frame);
    defer set_result.deinit(allocator);
    try std.testing.expect(set_result.command);
    try std.testing.expect(std.mem.eql(u8, set_result.commandName, "model"));
    try std.testing.expect(std.mem.eql(u8, set_result.replySource, "command"));
    try std.testing.expect(std.mem.eql(u8, set_result.provider, "qwen"));
    try std.testing.expect(std.mem.eql(u8, set_result.model, "qwen3-coder"));

    var status_result = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-status\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-a\",\"sessionId\":\"sess-a\",\"message\":\"/model\"}}");
    defer status_result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, status_result.reply, "Available providers:") != null);

    var list_result = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-list\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-a\",\"sessionId\":\"sess-a\",\"message\":\"/model list chatgpt\"}}");
    defer list_result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, list_result.reply, "Models for `chatgpt`") != null);
    try std.testing.expect(std.mem.indexOf(u8, list_result.reply, "gpt-5.2") != null);

    var provider_default = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-provider-default\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-a\",\"sessionId\":\"sess-a\",\"message\":\"/model chatgpt\"}}");
    defer provider_default.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, provider_default.provider, "chatgpt"));
    try std.testing.expect(std.mem.eql(u8, provider_default.model, "gpt-5.2"));

    var alias_result = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-alias\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-a\",\"sessionId\":\"sess-a\",\"message\":\"/model pro\"}}");
    defer alias_result.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, alias_result.provider, "chatgpt"));
    try std.testing.expect(std.mem.eql(u8, alias_result.model, "gpt-5.2-pro"));

    var next_result = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-next\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-a\",\"sessionId\":\"sess-a\",\"message\":\"/model next\"}}");
    defer next_result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, next_result.reply, "Model advanced to") != null);
    try std.testing.expect(std.mem.eql(u8, next_result.provider, "chatgpt"));
    try std.testing.expect(std.mem.eql(u8, next_result.model, "gpt-5.1-mini"));
}

test "telegram runtime model command supports custom overrides and provider scoped catalog ids" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;

    var slash_scoped = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-openrouter\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-models\",\"sessionId\":\"sess-models\",\"message\":\"/model openrouter/qwen/qwen3-coder:free\"}}");
    defer slash_scoped.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, slash_scoped.provider, "openrouter"));
    try std.testing.expect(std.mem.eql(u8, slash_scoped.model, "openrouter/qwen/qwen3-coder:free"));

    var custom_override = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-custom\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-models\",\"sessionId\":\"sess-models\",\"message\":\"/model qwen edge-experimental\"}}");
    defer custom_override.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, custom_override.provider, "qwen"));
    try std.testing.expect(std.mem.eql(u8, custom_override.model, "edge-experimental"));
    try std.testing.expect(std.mem.indexOf(u8, custom_override.reply, "custom model override applied") != null);
}

test "telegram runtime model command uses injected catalog resolver" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const injected_catalog = [_]TelegramModelDescriptor{
        .{ .id = "deepseek/deepseek-chat", .provider = "deepseek", .name = "DeepSeek Chat", .mode = "auto", .capability = "reasoning", .aliases = &.{ "deepseek-chat", "chat" } },
        .{ .id = "deepseek/deepseek-reasoner", .provider = "deepseek", .name = "DeepSeek Reasoner", .mode = "thinking", .capability = "reasoning", .aliases = &.{"reasoner"} },
        .{ .id = "gpt-5.2", .provider = "chatgpt", .name = "GPT-5.2", .mode = "auto", .capability = "reasoning", .aliases = &.{ "auto", "default" } },
    };
    var resolver_ctx: TestModelCatalogContext = .{
        .descriptors = injected_catalog[0..],
    };
    runtime.setModelCatalogResolver(@ptrCast(&resolver_ctx), testModelCatalogResolver);

    const allocator = std.testing.allocator;

    var list = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-list-injected\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-dyn\",\"sessionId\":\"sess-dyn\",\"message\":\"/model list deepseek\"}}");
    defer list.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, list.reply, "Models for `deepseek`") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.reply, "deepseek/deepseek-chat") != null);

    var provider_default = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-provider-injected\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-dyn\",\"sessionId\":\"sess-dyn\",\"message\":\"/model deepseek\"}}");
    defer provider_default.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, provider_default.provider, "deepseek"));
    try std.testing.expect(std.mem.eql(u8, provider_default.model, "deepseek/deepseek-chat"));
    try std.testing.expect(std.mem.indexOf(u8, provider_default.reply, "for `room-dyn`") != null);

    var alias_set = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-alias-injected\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-dyn\",\"sessionId\":\"sess-dyn\",\"message\":\"/model reasoner\"}}");
    defer alias_set.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, alias_set.provider, "deepseek"));
    try std.testing.expect(std.mem.eql(u8, alias_set.model, "deepseek/deepseek-reasoner"));
}

test "telegram runtime model command rejects missing provider in provider scoped syntax" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var invalid = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-missing-provider\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-model\",\"sessionId\":\"sess-invalid-model\",\"message\":\"/model /edge-experimental\"}}");
    defer invalid.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, invalid.authStatus, "invalid"));
    try std.testing.expect(std.mem.eql(u8, invalid.provider, "chatgpt"));
    try std.testing.expect(std.mem.eql(u8, invalid.model, "gpt-5.2"));
    try std.testing.expect(std.mem.indexOf(u8, invalid.reply, "Provider is required. Usage: `/model <provider>/<model>` or `/model <provider> <model>`.") != null);
}

test "telegram runtime tts command lifecycle" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var status = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-tts-status\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-tts\",\"sessionId\":\"sess-tts\",\"message\":\"/tts status\"}}");
    defer status.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, status.reply, "TTS is `") != null);

    var provider = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-tts-provider\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-tts\",\"sessionId\":\"sess-tts\",\"message\":\"/tts provider kittentts\"}}");
    defer provider.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, provider.reply, "TTS provider set to `kittentts`") != null);

    var off = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-tts-off\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-tts\",\"sessionId\":\"sess-tts\",\"message\":\"/tts off\"}}");
    defer off.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, off.reply, "TTS disabled") != null);

    var speak_disabled = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-tts-speak-disabled\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-tts\",\"sessionId\":\"sess-tts\",\"message\":\"/tts speak hello\"}}");
    defer speak_disabled.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, speak_disabled.reply, "TTS is disabled") != null);

    var on = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-tts-on\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-tts\",\"sessionId\":\"sess-tts\",\"message\":\"/tts on\"}}");
    defer on.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, on.reply, "TTS enabled") != null);

    var speak = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-tts-speak\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-tts\",\"sessionId\":\"sess-tts\",\"message\":\"/tts speak hello from zig\"}}");
    defer speak.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, speak.reply, "TTS synthesized `") != null);
    try std.testing.expect(std.mem.eql(u8, speak.commandName, "tts"));
    try std.testing.expect(speak.audioAvailable);
    try std.testing.expect(std.mem.eql(u8, speak.audioFormat, "wav"));
    try std.testing.expect(speak.audioBase64.len > 0);
    try std.testing.expect(speak.audioBytes > 0);
    try std.testing.expect(std.mem.eql(u8, speak.audioProviderUsed, "kittentts"));
    try std.testing.expect(std.mem.indexOf(u8, speak.audioSource, "offline-local") != null or std.mem.indexOf(u8, speak.audioSource, "simulated") != null);

    var poll = try runtime.pollFromFrame(allocator, "{\"id\":\"tg-tts-poll\",\"method\":\"poll\",\"params\":{\"channel\":\"telegram\",\"limit\":20}}");
    defer poll.deinit(allocator);
    var saw_audio_clip = false;
    for (poll.updates) |update| {
        if (std.mem.eql(u8, update.kind, "audio_clip")) {
            saw_audio_clip = true;
            break;
        }
    }
    try std.testing.expect(saw_audio_clip);
}

test "telegram runtime auth command and reply poll lifecycle" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    const start_frame =
        \\{"id":"tg-auth-start","method":"send","params":{"channel":"telegram","to":"room-b","sessionId":"sess-b","message":"/auth start chatgpt"}}
    ;
    var start_result = try runtime.sendFromFrame(allocator, start_frame);
    defer start_result.deinit(allocator);
    try std.testing.expect(start_result.loginSessionId.len > 0);
    try std.testing.expect(start_result.loginCode.len > 0);

    const complete_frame = try std.fmt.allocPrint(allocator, "{{\"id\":\"tg-auth-complete\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-b\",\"sessionId\":\"sess-b\",\"message\":\"/auth complete chatgpt {s} {s}\"}}}}", .{ start_result.loginCode, start_result.loginSessionId });
    defer allocator.free(complete_frame);
    var complete_result = try runtime.sendFromFrame(allocator, complete_frame);
    defer complete_result.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, complete_result.authStatus, "authorized"));
    try std.testing.expect(std.mem.indexOf(u8, complete_result.reply, "Auth completed. Session `") != null);

    const chat_frame =
        \\{"id":"tg-chat","method":"send","params":{"channel":"telegram","to":"room-b","sessionId":"sess-b","message":"hello"}}
    ;
    var chat_result = try runtime.sendFromFrame(allocator, chat_frame);
    defer chat_result.deinit(allocator);
    const bridge_or_echo = std.mem.eql(u8, chat_result.replySource, "bridge_completion") or std.mem.eql(u8, chat_result.replySource, "runtime_echo");
    try std.testing.expect(bridge_or_echo);
    if (std.mem.eql(u8, chat_result.replySource, "runtime_echo")) {
        try std.testing.expect(std.mem.indexOf(u8, chat_result.reply, "OpenClaw Zig") != null);
    }
    try std.testing.expect(chat_result.audioAvailable);
    try std.testing.expect(chat_result.audioBase64.len > 0);
    try std.testing.expect(std.mem.eql(u8, chat_result.audioFormat, "wav"));

    const poll_frame =
        \\{"id":"tg-poll","method":"poll","params":{"channel":"telegram","limit":10}}
    ;
    var poll_result = try runtime.pollFromFrame(allocator, poll_frame);
    defer poll_result.deinit(allocator);
    try std.testing.expect(poll_result.count >= 1);
    var saw_audio_clip = false;
    for (poll_result.updates) |update| {
        if (std.mem.eql(u8, update.kind, "audio_clip")) {
            saw_audio_clip = true;
            break;
        }
    }
    try std.testing.expect(saw_audio_clip);
}

test "telegram runtime unauthorized chat marks auth_required reply source" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var model_set = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-required-model\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-auth-required\",\"sessionId\":\"sess-auth-required\",\"message\":\"/model qwen/qwen-max\"}}");
    defer model_set.deinit(allocator);
    var chat = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-required\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-auth-required\",\"sessionId\":\"sess-auth-required\",\"message\":\"hello before auth\"}}");
    defer chat.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, chat.replySource, "auth_required"));
    try std.testing.expect(std.mem.indexOf(u8, chat.reply, "Auth required") != null);
}

const TestProviderApiKeyContext = struct {
    provider: []const u8,
    api_key: []const u8,
};

const TestProviderApiKeyStoreContext = struct {
    allocator: std.mem.Allocator,
    provider: ?[]u8 = null,
    api_key: ?[]u8 = null,

    fn deinit(self: *TestProviderApiKeyStoreContext) void {
        if (self.provider) |value| self.allocator.free(value);
        if (self.api_key) |value| self.allocator.free(value);
        self.provider = null;
        self.api_key = null;
    }
};

const TestModelCatalogContext = struct {
    descriptors: []const TelegramModelDescriptor,
};

fn testProviderApiKeyResolver(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    provider_raw: []const u8,
) !?[]u8 {
    const typed: *const TestProviderApiKeyContext = @ptrCast(@alignCast(ctx));
    const provider = normalizeProvider(provider_raw);
    if (!std.ascii.eqlIgnoreCase(provider, typed.provider)) return null;
    return try allocator.dupe(u8, typed.api_key);
}

fn testModelCatalogResolver(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    _: []const u8,
) ![]TelegramModelDescriptor {
    const typed: *const TestModelCatalogContext = @ptrCast(@alignCast(ctx));
    return allocator.dupe(TelegramModelDescriptor, typed.descriptors);
}

fn testProviderApiKeySetter(
    ctx: *anyopaque,
    _: std.mem.Allocator,
    provider_raw: []const u8,
    api_key_raw: []const u8,
) !bool {
    const typed: *TestProviderApiKeyStoreContext = @ptrCast(@alignCast(ctx));
    const provider = normalizeProvider(provider_raw);
    const api_key = std.mem.trim(u8, api_key_raw, " \t\r\n");
    if (provider.len == 0 or api_key.len == 0) return false;

    const provider_copy = try typed.allocator.dupe(u8, provider);
    errdefer typed.allocator.free(provider_copy);
    const api_key_copy = try typed.allocator.dupe(u8, api_key);
    errdefer typed.allocator.free(api_key_copy);

    if (typed.provider) |value| typed.allocator.free(value);
    if (typed.api_key) |value| typed.allocator.free(value);
    typed.provider = provider_copy;
    typed.api_key = api_key_copy;
    return true;
}

fn testStoredProviderApiKeyResolver(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    provider_raw: []const u8,
) !?[]u8 {
    const typed: *const TestProviderApiKeyStoreContext = @ptrCast(@alignCast(ctx));
    const provider = typed.provider orelse return null;
    const api_key = typed.api_key orelse return null;
    if (!std.ascii.eqlIgnoreCase(normalizeProvider(provider_raw), provider)) return null;
    return @as(?[]u8, try allocator.dupe(u8, api_key));
}

test "telegram runtime set api key command stores provider secret and updates auth providers reply" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    var store_ctx: TestProviderApiKeyStoreContext = .{ .allocator = std.testing.allocator };
    defer store_ctx.deinit();
    runtime.setProviderApiKeySetter(@ptrCast(&store_ctx), testProviderApiKeySetter);
    runtime.setProviderApiKeyResolver(@ptrCast(&store_ctx), testStoredProviderApiKeyResolver);

    const allocator = std.testing.allocator;
    var set_result = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-set-key\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-set\",\"sessionId\":\"sess-set\",\"message\":\"/set api key openrouter openrouter_test_key_123\"}}");
    defer set_result.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, set_result.commandName, "set"));
    try std.testing.expect(std.mem.eql(u8, set_result.provider, "openrouter"));
    try std.testing.expect(std.mem.indexOf(u8, set_result.reply, "Provider API key saved for `openrouter`") != null);
    const set_metadata = set_result.metadataJson orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, set_metadata, "\"type\":\"set.api_key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_metadata, "\"provider\":\"openrouter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_metadata, "\"stored\":true") != null);
    try std.testing.expect(std.mem.eql(u8, store_ctx.provider.?, "openrouter"));
    try std.testing.expect(std.mem.eql(u8, store_ctx.api_key.?, "openrouter_test_key_123"));

    var providers = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-set-key-providers\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-set\",\"sessionId\":\"sess-set\",\"message\":\"/auth providers\"}}");
    defer providers.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, providers.reply, "openrouter (browser:true, apiKey:true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, providers.reply, "apiKey:true") != null);
}

test "telegram runtime uses provider api key when no authorized browser session exists" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    var resolver_ctx: TestProviderApiKeyContext = .{
        .provider = "chatgpt",
        .api_key = "sk-telegram-test",
    };
    runtime.setProviderApiKeyResolver(@ptrCast(&resolver_ctx), testProviderApiKeyResolver);

    const allocator = std.testing.allocator;
    var chat = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-api-key\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-api-key\",\"sessionId\":\"sess-api-key\",\"message\":\"hello with api key\"}}");
    defer chat.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, chat.replySource, "auth_required"));
    try std.testing.expect(std.mem.eql(u8, chat.authStatus, "authorized"));
    if (std.mem.eql(u8, chat.replySource, "bridge_completion")) {
        try std.testing.expect(chat.providerApiKeyUsed);
    } else {
        try std.testing.expect(!chat.providerApiKeyUsed);
    }
    try std.testing.expect(std.mem.eql(u8, chat.provider, "chatgpt"));
}

test "telegram runtime send accepts webchat and cli channel aliases" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var webchat = try runtime.sendFromFrame(allocator, "{\"id\":\"send-web\",\"method\":\"send\",\"params\":{\"channel\":\"web\",\"to\":\"room-web\",\"sessionId\":\"sess-web\",\"message\":\"hello web alias\"}}");
    defer webchat.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, webchat.channel, "webchat"));
    try std.testing.expect(std.mem.eql(u8, webchat.to, "room-web"));
    try std.testing.expect(std.mem.eql(u8, webchat.sessionId, "sess-web"));

    var cli = try runtime.sendFromFrame(allocator, "{\"id\":\"send-cli\",\"method\":\"send\",\"params\":{\"channel\":\"console\",\"to\":\"room-cli\",\"sessionId\":\"sess-cli\",\"message\":\"hello cli alias\"}}");
    defer cli.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, cli.channel, "cli"));
    try std.testing.expect(std.mem.eql(u8, cli.to, "room-cli"));
    try std.testing.expect(std.mem.eql(u8, cli.sessionId, "sess-cli"));
}

test "telegram runtime send and poll reject unsupported channels" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    try std.testing.expectError(
        error.UnsupportedChannel,
        runtime.sendFromFrame(std.testing.allocator, "{\"id\":\"send-unsupported\",\"method\":\"send\",\"params\":{\"channel\":\"matrix\",\"message\":\"hello\"}}"),
    );
    try std.testing.expectError(
        error.UnsupportedChannel,
        runtime.pollFromFrame(std.testing.allocator, "{\"id\":\"poll-cli\",\"method\":\"poll\",\"params\":{\"channel\":\"cli\",\"limit\":10}}"),
    );
}

test "telegram runtime poll compacts queue front in one pass and keeps ordering" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    try runtime.enqueue("room-opt", "sess-opt", "assistant", "assistant_reply", "m1");
    try runtime.enqueue("room-opt", "sess-opt", "assistant", "assistant_reply", "m2");
    try runtime.enqueue("room-opt", "sess-opt", "assistant", "assistant_reply", "m3");

    var poll_first = try runtime.pollFromFrame(allocator, "{\"id\":\"tg-poll-opt-1\",\"method\":\"poll\",\"params\":{\"channel\":\"telegram\",\"limit\":2}}");
    defer poll_first.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), poll_first.count);
    try std.testing.expectEqual(@as(usize, 1), poll_first.remaining);
    try std.testing.expect(std.mem.eql(u8, poll_first.updates[0].message, "m1"));
    try std.testing.expect(std.mem.eql(u8, poll_first.updates[1].message, "m2"));

    var poll_second = try runtime.pollFromFrame(allocator, "{\"id\":\"tg-poll-opt-2\",\"method\":\"poll\",\"params\":{\"channel\":\"telegram\",\"limit\":5}}");
    defer poll_second.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), poll_second.count);
    try std.testing.expectEqual(@as(usize, 0), poll_second.remaining);
    try std.testing.expect(std.mem.eql(u8, poll_second.updates[0].message, "m3"));
}

test "telegram runtime queue retention keeps newest entries under cap" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();
    runtime.max_queue_entries = 3;

    const allocator = std.testing.allocator;
    try runtime.enqueue("room-cap", "sess-cap", "assistant", "assistant_reply", "m1");
    try runtime.enqueue("room-cap", "sess-cap", "assistant", "assistant_reply", "m2");
    try runtime.enqueue("room-cap", "sess-cap", "assistant", "assistant_reply", "m3");
    try runtime.enqueue("room-cap", "sess-cap", "assistant", "assistant_reply", "m4");
    try runtime.enqueue("room-cap", "sess-cap", "assistant", "assistant_reply", "m5");

    var poll = try runtime.pollFromFrame(allocator, "{\"id\":\"tg-poll-cap\",\"method\":\"poll\",\"params\":{\"channel\":\"telegram\",\"limit\":10}}");
    defer poll.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), poll.count);
    try std.testing.expectEqual(@as(usize, 0), poll.remaining);
    try std.testing.expect(std.mem.eql(u8, poll.updates[0].message, "m3"));
    try std.testing.expect(std.mem.eql(u8, poll.updates[1].message, "m4"));
    try std.testing.expect(std.mem.eql(u8, poll.updates[2].message, "m5"));
}

test "telegram runtime qwen guest auth lifecycle" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    const model_frame =
        \\{"id":"tg-model-qwen","method":"send","params":{"channel":"telegram","to":"room-qwen","sessionId":"sess-qwen","message":"/model qwen/qwen-max"}}
    ;
    var model_result = try runtime.sendFromFrame(allocator, model_frame);
    defer model_result.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, model_result.provider, "qwen"));

    const start_frame =
        \\{"id":"tg-auth-start-qwen","method":"send","params":{"channel":"telegram","to":"room-qwen","sessionId":"sess-qwen","message":"/auth start qwen"}}
    ;
    var start_result = try runtime.sendFromFrame(allocator, start_frame);
    defer start_result.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, start_result.provider, "qwen"));
    try std.testing.expect(std.mem.indexOf(u8, start_result.reply, "Auth started for `qwen`.") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_result.reply, "If prompted, use code `") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_result.reply, "Then run: `/auth complete qwen ") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_result.reply, "/auth guest qwen") == null);

    const guest_frame =
        \\{"id":"tg-auth-guest-qwen","method":"send","params":{"channel":"telegram","to":"room-qwen","sessionId":"sess-qwen","message":"/auth guest qwen"}}
    ;
    var guest_result = try runtime.sendFromFrame(allocator, guest_frame);
    defer guest_result.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, guest_result.authStatus, "authorized"));

    const chat_frame =
        \\{"id":"tg-chat-qwen","method":"send","params":{"channel":"telegram","to":"room-qwen","sessionId":"sess-qwen","message":"hello qwen"}}
    ;
    var chat_result = try runtime.sendFromFrame(allocator, chat_frame);
    defer chat_result.deinit(allocator);
    const bridge_or_echo = std.mem.eql(u8, chat_result.replySource, "bridge_completion") or std.mem.eql(u8, chat_result.replySource, "runtime_echo");
    try std.testing.expect(bridge_or_echo);
    if (std.mem.eql(u8, chat_result.replySource, "runtime_echo")) {
        try std.testing.expect(std.mem.indexOf(u8, chat_result.reply, "OpenClaw Zig (qwen/") != null);
    }
}

test "telegram runtime uses latest authorized session fallback when selected provider is unauthenticated" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var auth_start = try runtime.sendFromFrame(
        allocator,
        "{\"id\":\"tg-fallback-auth-start\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-fallback\",\"sessionId\":\"sess-fallback\",\"message\":\"/auth start chatgpt\"}}",
    );
    defer auth_start.deinit(allocator);
    try std.testing.expect(auth_start.loginCode.len > 0);
    try std.testing.expect(auth_start.loginSessionId.len > 0);

    const auth_complete_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-fallback-auth-complete\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-fallback\",\"sessionId\":\"sess-fallback\",\"message\":\"/auth complete chatgpt {s} {s}\"}}}}",
        .{ auth_start.loginCode, auth_start.loginSessionId },
    );
    defer allocator.free(auth_complete_frame);
    var auth_complete = try runtime.sendFromFrame(allocator, auth_complete_frame);
    defer auth_complete.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, auth_complete.authStatus, "authorized"));

    var model_set = try runtime.sendFromFrame(
        allocator,
        "{\"id\":\"tg-fallback-model\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-fallback\",\"sessionId\":\"sess-fallback\",\"message\":\"/model qwen/qwen-max\"}}",
    );
    defer model_set.deinit(allocator);

    var chat = try runtime.sendFromFrame(
        allocator,
        "{\"id\":\"tg-fallback-chat\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-fallback\",\"sessionId\":\"sess-fallback\",\"message\":\"hello fallback bridge\"}}",
    );
    defer chat.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, chat.authStatus, "authorized"));
    try std.testing.expect(!std.mem.eql(u8, chat.replySource, "auth_required"));
}

test "telegram runtime auth complete infers provider from callback URL" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    const start_frame =
        \\{"id":"tg-auth-start-zai","method":"send","params":{"channel":"telegram","to":"room-zai","sessionId":"sess-zai","message":"/auth start zai"}}
    ;
    var start_result = try runtime.sendFromFrame(allocator, start_frame);
    defer start_result.deinit(allocator);
    try std.testing.expect(start_result.loginSessionId.len > 0);

    const callback_url = try std.fmt.allocPrint(allocator, "https://chat.z.ai/oauth/callback?code={s}", .{start_result.loginCode});
    defer allocator.free(callback_url);
    const complete_frame = try std.fmt.allocPrint(allocator, "{{\"id\":\"tg-auth-complete-zai\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-zai\",\"sessionId\":\"sess-zai\",\"message\":\"/auth complete {s}\"}}}}", .{callback_url});
    defer allocator.free(complete_frame);
    var complete_result = try runtime.sendFromFrame(allocator, complete_frame);
    defer complete_result.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, complete_result.provider, "zai"));
    try std.testing.expect(std.mem.eql(u8, complete_result.authStatus, "authorized"));
}

test "telegram runtime normalizes additional provider aliases" {
    try std.testing.expect(std.mem.eql(u8, normalizeProvider("openai-codex-cli"), "codex"));
    try std.testing.expect(std.mem.eql(u8, normalizeProvider("minimax-cli"), "minimax"));
    try std.testing.expect(std.mem.eql(u8, normalizeProvider("kimi-coding"), "kimi"));
    try std.testing.expect(std.mem.eql(u8, normalizeProvider("bigmodel"), "zhipuai"));
    try std.testing.expect(std.mem.eql(u8, normalizeProvider("qwen-chat-free"), "qwen"));
    try std.testing.expect(std.mem.eql(u8, normalizeProvider("glm-5-chat-free"), "zai"));
    try std.testing.expect(std.mem.eql(u8, normalizeProvider("mercury-2-chat-free"), "inception"));
    try std.testing.expect(std.mem.eql(u8, defaultModelForProvider("zhipu-ai"), "glm-4.6"));
    try std.testing.expect(isKnownProvider("zhipuai-coding"));
}

test "telegram runtime auth supports account scope and force restart" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var model_set = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-qwen-acc\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"/model qwen/qwen-max\"}}");
    defer model_set.deinit(allocator);

    var start_mobile = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-start-mobile\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"/auth start qwen mobile\"}}");
    defer start_mobile.deinit(allocator);
    try std.testing.expect(start_mobile.loginSessionId.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, start_mobile.reply, "Auth started for `qwen` account `mobile`.") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_mobile.reply, "If prompted, use code `") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_mobile.reply, "Then run: `/auth complete qwen ") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_mobile.reply, " mobile`") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_mobile.reply, "/auth guest") == null);
    const start_mobile_metadata = start_mobile.metadataJson orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, start_mobile_metadata, "\"expiresAt\":\"") != null);
    const mobile_session_1 = try allocator.dupe(u8, start_mobile.loginSessionId);
    defer allocator.free(mobile_session_1);

    var start_mobile_repeat = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-start-mobile-repeat\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"/auth start qwen mobile\"}}");
    defer start_mobile_repeat.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, start_mobile_repeat.loginSessionId, mobile_session_1));
    try std.testing.expect(std.mem.indexOf(u8, start_mobile_repeat.reply, "Auth already pending for `qwen` account `mobile`.") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_mobile_repeat.reply, "Then run: `/auth complete qwen ") != null);
    try std.testing.expect(std.mem.indexOf(u8, start_mobile_repeat.reply, "Use `--force` to replace session.") == null);
    try std.testing.expect(std.mem.indexOf(u8, start_mobile_repeat.reply, "/auth guest") == null);
    const start_mobile_repeat_metadata = start_mobile_repeat.metadataJson orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, start_mobile_repeat_metadata, "\"expiresAt\":\"") != null);

    var start_mobile_force = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-start-mobile-force\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"/auth start qwen mobile --force\"}}");
    defer start_mobile_force.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, start_mobile_force.loginSessionId, mobile_session_1));

    var status_mobile = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-status-mobile\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"/auth status qwen mobile\"}}");
    defer status_mobile.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, status_mobile.loginSessionId, start_mobile_force.loginSessionId));
    try std.testing.expect(std.mem.indexOf(u8, status_mobile.reply, "Open: https://chat.qwen.ai/?openclaw_code=") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_mobile.reply, "Then run: `/auth complete qwen ") != null);
    try std.testing.expect(std.mem.indexOf(u8, status_mobile.reply, " mobile`") == null);

    var start_desktop = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-start-desktop\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"/auth start qwen desktop\"}}");
    defer start_desktop.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, start_desktop.loginSessionId, start_mobile_force.loginSessionId));

    var guest_mobile = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-guest-mobile\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"/auth guest qwen mobile\"}}");
    defer guest_mobile.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, guest_mobile.authStatus, "authorized"));

    var chat_mobile = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-chat-mobile\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"hello after mobile auth\"}}");
    defer chat_mobile.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, chat_mobile.reply, "OpenClaw Zig (qwen/") != null);
}

test "telegram runtime auth bridge and providers help keep compact go-style replies with rich metadata" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    var resolver_ctx: TestProviderApiKeyContext = .{
        .provider = "qwen",
        .api_key = "qwen-secret",
    };
    runtime.setProviderApiKeyResolver(@ptrCast(&resolver_ctx), testProviderApiKeyResolver);
    std.testing.allocator.free(runtime.bridge_endpoint);
    runtime.bridge_endpoint = try std.testing.allocator.dupe(u8, "http://127.0.0.1:1");

    const allocator = std.testing.allocator;
    var start = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-start-bridge\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-help\",\"sessionId\":\"sess-help\",\"message\":\"/auth start qwen mobile\"}}");
    defer start.deinit(allocator);

    var providers = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-providers\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-help\",\"sessionId\":\"sess-help\",\"message\":\"/auth providers\"}}");
    defer providers.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, providers.reply, "Auth providers:") != null);
    try std.testing.expect(std.mem.indexOf(u8, providers.reply, "qwen (browser:true, apiKey:true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, providers.reply, "apiKey:true") != null);
    try std.testing.expect(std.mem.indexOf(u8, providers.reply, "zai (browser:true, apiKey:false)") != null);

    var help = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-help\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-help\",\"sessionId\":\"sess-help\",\"message\":\"/auth help\"}}");
    defer help.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "Auth command usage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "`/auth providers`") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "`/auth status [provider] [account] [session_id]`") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "`/auth bridge`") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "`/auth` (start default provider)") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "`/auth wait <provider> [session_id] [account] [--timeout <seconds>]`") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "`/auth complete <provider> <callback_url_or_code> [session_id] [account]`") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "`/auth complete <code> [session_id]`") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "`/auth cancel [provider] [account] [session_id]`") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "`/auth url <provider> [account] [session_id]`") != null);
    try std.testing.expect(std.mem.indexOf(u8, help.reply, "`/auth guest <provider> [account] [session_id]`") != null);

    var bridge_qwen = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-bridge-qwen\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-help\",\"sessionId\":\"sess-help\",\"message\":\"/auth bridge qwen\"}}");
    defer bridge_qwen.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, bridge_qwen.reply, "Bridge `unreachable` (http://127.0.0.1:1).") != null);
    try std.testing.expect(std.mem.indexOf(u8, bridge_qwen.reply, "Probe error: probe failed: ConnectionRefused") != null);
    const bridge_qwen_metadata = bridge_qwen.metadataJson orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, bridge_qwen_metadata, "\"guidance\":\"Browser bridge: lightpanda") != null);
    try std.testing.expect(std.mem.indexOf(u8, bridge_qwen_metadata, "\"reachable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, bridge_qwen_metadata, "\"httpStatus\":0") != null);
}

test "telegram runtime auth link command surfaces pending qwen session details" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var start = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-start-link-qwen\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-link\",\"sessionId\":\"sess-link\",\"message\":\"/auth start qwen mobile\"}}");
    defer start.deinit(allocator);
    try std.testing.expect(start.loginSessionId.len > 0);
    try std.testing.expect(start.loginCode.len > 0);

    var link = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-link-qwen\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-link\",\"sessionId\":\"sess-link\",\"message\":\"/auth link qwen mobile\"}}");
    defer link.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, link.authStatus, "pending"));
    try std.testing.expect(std.mem.indexOf(u8, link.reply, "Auth URL: https://chat.qwen.ai/?openclaw_code=") != null);
    try std.testing.expect(std.mem.indexOf(u8, link.reply, "Status: `") == null);
    try std.testing.expect(std.mem.indexOf(u8, link.reply, "Session: `") == null);
    try std.testing.expect(std.mem.indexOf(u8, link.reply, "/auth guest qwen mobile") == null);
    try std.testing.expect(std.mem.indexOf(u8, link.reply, start.loginCode) != null);
    try std.testing.expect(std.mem.indexOf(u8, link.metadataJson.?, "\"type\":\"auth.url\"") != null);
}

test "telegram runtime auth open alias surfaces chatgpt completion command" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var start = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-start-link-chatgpt\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-link-chatgpt\",\"sessionId\":\"sess-link-chatgpt\",\"message\":\"/auth start chatgpt\"}}");
    defer start.deinit(allocator);
    try std.testing.expect(start.loginSessionId.len > 0);
    try std.testing.expect(start.loginCode.len > 0);

    var open = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-open-chatgpt\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-link-chatgpt\",\"sessionId\":\"sess-link-chatgpt\",\"message\":\"/auth open chatgpt\"}}");
    defer open.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, open.authStatus, "pending"));
    try std.testing.expect(std.mem.indexOf(u8, open.reply, "Auth URL: https://chatgpt.com/?openclaw_code=") != null);
    try std.testing.expect(std.mem.indexOf(u8, open.reply, "Status: `") == null);
    try std.testing.expect(std.mem.indexOf(u8, open.reply, "Session: `") == null);
    try std.testing.expect(std.mem.indexOf(u8, open.reply, start.loginCode) != null);
    try std.testing.expect(std.mem.indexOf(u8, open.metadataJson.?, "\"type\":\"auth.url\"") != null);
}

test "telegram runtime auth link and open aliases use url-style missing replies" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;

    var link_none = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-link-none\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-link-none\",\"sessionId\":\"sess-link-none\",\"message\":\"/auth link qwen mobile\"}}");
    defer link_none.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, link_none.authStatus, "none"));
    try std.testing.expect(std.mem.indexOf(u8, link_none.reply, "No active auth flow. Run `/auth start <provider>` first.") != null);
    try std.testing.expect(std.mem.indexOf(u8, link_none.metadataJson.?, "\"type\":\"auth.url\"") != null);

    try runtime.setAuthBinding("room-open-missing", "chatgpt", "default", "web-login-stale");
    var open_missing = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-open-missing\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-open-missing\",\"sessionId\":\"sess-open-missing\",\"message\":\"/auth open chatgpt\"}}");
    defer open_missing.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, open_missing.authStatus, "missing"));
    try std.testing.expect(std.mem.indexOf(u8, open_missing.reply, "Auth session expired or missing. Run `/auth` again.") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_missing.metadataJson.?, "\"type\":\"auth.url\"") != null);

    const cleared = try runtime.getAuthBinding(allocator, "room-open-missing", "chatgpt", "default");
    try std.testing.expect(cleared.len == 0);
}

test "telegram runtime auth url alias surfaces session details" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var start = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-start-url-qwen\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-url\",\"sessionId\":\"sess-url\",\"message\":\"/auth start qwen mobile\"}}");
    defer start.deinit(allocator);
    try std.testing.expect(start.loginSessionId.len > 0);
    try std.testing.expect(start.loginCode.len > 0);

    var url = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-url-qwen\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-url\",\"sessionId\":\"sess-url\",\"message\":\"/auth url qwen mobile\"}}");
    defer url.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, url.authStatus, "pending"));
    try std.testing.expect(std.mem.indexOf(u8, url.reply, "Auth URL: https://chat.qwen.ai/?openclaw_code=") != null);
    try std.testing.expect(std.mem.indexOf(u8, url.reply, "Status: `") == null);
    try std.testing.expect(std.mem.indexOf(u8, url.reply, "Session: `") == null);
    try std.testing.expect(std.mem.indexOf(u8, url.reply, "Scope: `") == null);
    try std.testing.expect(std.mem.indexOf(u8, url.reply, "Guest mode: supported") == null);
    try std.testing.expect(std.mem.indexOf(u8, url.reply, start.loginCode) != null);
}

test "telegram runtime auth url clears stale binding when session is missing" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    try runtime.setAuthBinding("room-url-missing", "qwen", "mobile", "web-login-stale");

    var url = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-url-missing\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-url-missing\",\"sessionId\":\"sess-url-missing\",\"message\":\"/auth url qwen mobile\"}}");
    defer url.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, url.authStatus, "missing"));
    try std.testing.expect(std.mem.indexOf(u8, url.reply, "Auth session expired or missing. Run `/auth` again.") != null);
    try std.testing.expect(url.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, url.metadataJson.?, "\"type\":\"auth.url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, url.metadataJson.?, "\"status\":\"missing\"") != null);

    const cleared = try runtime.getAuthBinding(allocator, "room-url-missing", "qwen", "mobile");
    try std.testing.expect(cleared.len == 0);
}

test "telegram runtime auth status clears stale binding when session is missing" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    try runtime.setAuthBinding("room-status-missing", "qwen", "mobile", "web-login-stale");

    var status = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-status-missing\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-status-missing\",\"sessionId\":\"sess-status-missing\",\"message\":\"/auth status qwen mobile\"}}");
    defer status.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, status.authStatus, "missing"));
    try std.testing.expect(std.mem.indexOf(u8, status.reply, "Auth session expired or missing. Run `/auth start <provider>` again.") != null);
    try std.testing.expect(status.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, status.metadataJson.?, "\"type\":\"auth.status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status.metadataJson.?, "\"status\":\"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status.metadataJson.?, "\"loginSessionId\":\"web-login-stale\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status.metadataJson.?, "\"error\":") == null);

    const cleared = try runtime.getAuthBinding(allocator, "room-status-missing", "qwen", "mobile");
    try std.testing.expect(cleared.len == 0);
}

test "telegram runtime auth status and wait without session use go-style replies" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;

    var status = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-status-none\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-status-none\",\"sessionId\":\"sess-status-none\",\"message\":\"/auth status qwen mobile\"}}");
    defer status.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, status.authStatus, "none"));
    try std.testing.expect(std.mem.indexOf(u8, status.reply, "No active auth flow for `room-status-none` in scope `qwen/mobile`.") != null);
    try std.testing.expect(status.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, status.metadataJson.?, "\"type\":\"auth.status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status.metadataJson.?, "\"status\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status.metadataJson.?, "\"error\":") == null);

    var wait = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-wait-none\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-wait-none\",\"sessionId\":\"sess-wait-none\",\"message\":\"/auth wait qwen mobile --timeout 15\"}}");
    defer wait.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, wait.authStatus, "missing"));
    try std.testing.expect(std.mem.indexOf(u8, wait.reply, "No auth session selected for scope `qwen/mobile`. Start with `/auth start qwen`.") != null);
    try std.testing.expect(wait.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, wait.metadataJson.?, "\"type\":\"auth.wait\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wait.metadataJson.?, "\"error\":\"missing_session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wait.metadataJson.?, "\"status\":") == null);
}

test "telegram runtime auth wait missing session uses go-style bridge error" {
    var login = web_login.LoginManager.init(std.testing.allocator, 10);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;

    try runtime.setAuthBinding("room-wait-missing", "qwen", "mobile", "web-login-stale");
    var wait_missing = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-wait-stale\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-wait-missing\",\"sessionId\":\"sess-wait-missing\",\"message\":\"/auth wait qwen mobile --timeout 1\"}}");
    defer wait_missing.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, wait_missing.authStatus, "missing"));
    try std.testing.expect(std.mem.indexOf(u8, wait_missing.reply, "Auth wait failed: login session not found") != null);
    try std.testing.expect(wait_missing.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, wait_missing.metadataJson.?, "\"error\":\"login session not found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, wait_missing.metadataJson.?, "\"status\":") == null);
}

test "telegram runtime auth complete missing session and bridge errors use go-style replies" {
    var login = web_login.LoginManager.init(std.testing.allocator, 10);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;

    var complete_missing = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-complete-missing\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-complete-missing\",\"sessionId\":\"sess-complete-missing\",\"message\":\"/auth complete qwen OC-123 mobile\"}}");
    defer complete_missing.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, complete_missing.authStatus, "none"));
    try std.testing.expect(std.mem.indexOf(u8, complete_missing.reply, "No pending auth session for scope `qwen/mobile`. Run `/auth start qwen` first.") != null);
    try std.testing.expect(complete_missing.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_missing.metadataJson.?, "\"error\":\"missing_session\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_missing.metadataJson.?, "\"status\":") == null);

    var start_invalid = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-complete-invalid-start\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-complete-invalid\",\"sessionId\":\"sess-complete-invalid\",\"message\":\"/auth start qwen mobile\"}}");
    defer start_invalid.deinit(allocator);
    const invalid_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-complete-invalid\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-complete-invalid\",\"sessionId\":\"sess-complete-invalid\",\"message\":\"/auth complete qwen WRONG {s} mobile\"}}}}",
        .{start_invalid.loginSessionId},
    );
    defer allocator.free(invalid_frame);
    var complete_invalid = try runtime.sendFromFrame(allocator, invalid_frame);
    defer complete_invalid.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, complete_invalid.authStatus, "rejected"));
    try std.testing.expect(std.mem.indexOf(u8, complete_invalid.reply, "Auth failed: invalid login code") != null);
    try std.testing.expect(complete_invalid.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_invalid.metadataJson.?, "\"error\":\"invalid login code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_invalid.metadataJson.?, "\"status\":") == null);

    const missing_code_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-complete-missing-code\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-complete-invalid\",\"sessionId\":\"sess-complete-invalid\",\"message\":\"/auth complete qwen guest {s} mobile\"}}}}",
        .{start_invalid.loginSessionId},
    );
    defer allocator.free(missing_code_frame);
    var complete_missing_code = try runtime.sendFromFrame(allocator, missing_code_frame);
    defer complete_missing_code.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, complete_missing_code.authStatus, "pending"));
    try std.testing.expect(std.mem.indexOf(u8, complete_missing_code.reply, "Missing code. Usage: `/auth complete <provider> <callback_url_or_code> [session_id] [account]`") != null);
    try std.testing.expect(complete_missing_code.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_missing_code.metadataJson.?, "\"error\":\"missing_code\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_missing_code.metadataJson.?, "\"loginSessionId\":\"") != null);

    const authorize_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-complete-authorize-first\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-complete-invalid\",\"sessionId\":\"sess-complete-invalid\",\"message\":\"/auth complete qwen {s} {s} mobile\"}}}}",
        .{ start_invalid.loginCode, start_invalid.loginSessionId },
    );
    defer allocator.free(authorize_frame);
    var authorize_first = try runtime.sendFromFrame(allocator, authorize_frame);
    defer authorize_first.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, authorize_first.authStatus, "authorized"));

    const already_complete_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-complete-authorized-empty\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-complete-invalid\",\"sessionId\":\"sess-complete-invalid\",\"message\":\"/auth complete qwen guest {s} mobile\"}}}}",
        .{start_invalid.loginSessionId},
    );
    defer allocator.free(already_complete_frame);
    var already_complete = try runtime.sendFromFrame(allocator, already_complete_frame);
    defer already_complete.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, already_complete.authStatus, "authorized"));
    try std.testing.expect(std.mem.indexOf(u8, already_complete.reply, "Auth already completed. Session `") != null);
    try std.testing.expect(already_complete.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, already_complete.metadataJson.?, "\"status\":\"authorized\"") != null);

    try runtime.setAuthBinding("room-complete-stale", "qwen", "mobile", "web-login-stale");
    var complete_stale = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-complete-stale\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-complete-stale\",\"sessionId\":\"sess-complete-stale\",\"message\":\"/auth complete qwen OC-123 mobile\"}}");
    defer complete_stale.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, complete_stale.authStatus, "missing"));
    try std.testing.expect(std.mem.indexOf(u8, complete_stale.reply, "Auth failed: login session not found") != null);
    try std.testing.expect(complete_stale.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_stale.metadataJson.?, "\"error\":\"login session not found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_stale.metadataJson.?, "\"status\":") == null);

    var start_expired = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-complete-expired-start\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-complete-expired\",\"sessionId\":\"sess-complete-expired\",\"message\":\"/auth start qwen mobile\"}}");
    defer start_expired.deinit(allocator);
    const expire_deadline_ms = time_util.nowMs() + 20;
    while (time_util.nowMs() <= expire_deadline_ms) {}
    const expired_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-complete-expired\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-complete-expired\",\"sessionId\":\"sess-complete-expired\",\"message\":\"/auth complete qwen {s} {s} mobile\"}}}}",
        .{ start_expired.loginCode, start_expired.loginSessionId },
    );
    defer allocator.free(expired_frame);
    var complete_expired = try runtime.sendFromFrame(allocator, expired_frame);
    defer complete_expired.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, complete_expired.authStatus, "expired"));
    try std.testing.expect(std.mem.indexOf(u8, complete_expired.reply, "Auth failed: login session expired") != null);
    try std.testing.expect(complete_expired.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_expired.metadataJson.?, "\"error\":\"login session expired\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_expired.metadataJson.?, "\"status\":") == null);
}

test "telegram runtime auth cancel revokes scoped session" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var start = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-start-cancel-qwen\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-cancel\",\"sessionId\":\"sess-cancel\",\"message\":\"/auth start qwen mobile\"}}");
    defer start.deinit(allocator);
    try std.testing.expect(start.loginSessionId.len > 0);

    var cancel = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-cancel-qwen\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-cancel\",\"sessionId\":\"sess-cancel\",\"message\":\"/auth cancel qwen mobile\"}}");
    defer cancel.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, cancel.authStatus, "cancelled"));
    try std.testing.expect(std.mem.eql(u8, cancel.loginSessionId, start.loginSessionId));
    try std.testing.expect(std.mem.indexOf(u8, cancel.reply, "Auth session `web-login-") != null);
    try std.testing.expect(std.mem.indexOf(u8, cancel.reply, "` cancelled.") != null);
    try std.testing.expect(std.mem.indexOf(u8, cancel.reply, "for `qwen` account `mobile`") == null);

    const status_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-status-cancel-qwen\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-cancel\",\"sessionId\":\"sess-cancel\",\"message\":\"/auth status qwen {s} mobile\"}}}}",
        .{start.loginSessionId},
    );
    defer allocator.free(status_frame);
    var status = try runtime.sendFromFrame(allocator, status_frame);
    defer status.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, status.authStatus, "rejected"));
    try std.testing.expect(std.mem.indexOf(u8, status.reply, "Auth status: `rejected`") != null);
}

test "telegram runtime auth cancel explicit rejected session reports revoked false" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var start = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-start-cancel-revoked\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-cancel-revoked\",\"sessionId\":\"sess-cancel-revoked\",\"message\":\"/auth start qwen mobile\"}}");
    defer start.deinit(allocator);

    const first_cancel_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-first-cancel-revoked\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-cancel-revoked\",\"sessionId\":\"sess-cancel-revoked\",\"message\":\"/auth cancel qwen mobile {s}\"}}}}",
        .{start.loginSessionId},
    );
    defer allocator.free(first_cancel_frame);
    var first_cancel = try runtime.sendFromFrame(allocator, first_cancel_frame);
    defer first_cancel.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, first_cancel.metadataJson.?, "\"revoked\":true") != null);

    const second_cancel_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-second-cancel-revoked\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-cancel-revoked\",\"sessionId\":\"sess-cancel-revoked\",\"message\":\"/auth cancel qwen mobile {s}\"}}}}",
        .{start.loginSessionId},
    );
    defer allocator.free(second_cancel_frame);
    var second_cancel = try runtime.sendFromFrame(allocator, second_cancel_frame);
    defer second_cancel.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, second_cancel.authStatus, "cancelled"));
    try std.testing.expect(second_cancel.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, second_cancel.metadataJson.?, "\"type\":\"auth.cancel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_cancel.metadataJson.?, "\"revoked\":false") != null);
}

test "telegram runtime wait supports session keyword and bounded timeout flag" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var start = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-start-wait-session\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-wait-session\",\"sessionId\":\"sess-wait-session\",\"message\":\"/auth start qwen mobile\"}}");
    defer start.deinit(allocator);

    const wait_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-wait-session-keyword\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-wait-session\",\"sessionId\":\"sess-wait-session\",\"message\":\"/auth wait qwen session {s} mobile --timeout=1\"}}}}",
        .{start.loginSessionId},
    );
    defer allocator.free(wait_frame);
    var wait = try runtime.sendFromFrame(allocator, wait_frame);
    defer wait.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, wait.authStatus, "pending"));
    try std.testing.expect(std.mem.eql(u8, wait.loginSessionId, start.loginSessionId));
    try std.testing.expect(std.mem.indexOf(u8, wait.reply, "Auth wait result: `pending`") != null);
}

test "telegram runtime auth parser rejects invalid options and trailing args" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var start = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-start-invalid-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth start qwen mobile\"}}");
    defer start.deinit(allocator);

    var bad_start_option = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-bad-start-option-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth start qwen mobile --bogus\"}}");
    defer bad_start_option.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, bad_start_option.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, bad_start_option.reply, "Unknown start option `--bogus`.") != null);
    try std.testing.expect(bad_start_option.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_start_option.metadataJson.?, "\"type\":\"auth.start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_start_option.metadataJson.?, "\"error\":\"invalid_start_args\"") != null);

    var bad_start_usage = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-bad-start-usage-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth start qwen mobile extra\"}}");
    defer bad_start_usage.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, bad_start_usage.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, bad_start_usage.reply, "Usage: `/auth start <provider> [account] [--force]`") != null);
    try std.testing.expect(bad_start_usage.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_start_usage.metadataJson.?, "\"type\":\"auth.start\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_start_usage.metadataJson.?, "\"error\":\"invalid_start_args\"") != null);

    var bad_status = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-bad-status-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth status qwen mobile --bogus\"}}");
    defer bad_status.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, bad_status.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, bad_status.reply, "Unknown status option `--bogus`") != null);
    try std.testing.expect(bad_status.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_status.metadataJson.?, "\"type\":\"auth.status\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_status.metadataJson.?, "\"error\":\"invalid_status_args\"") != null);

    var status_usage = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-status-usage-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth status qwen mobile extra\"}}");
    defer status_usage.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, status_usage.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, status_usage.reply, "Usage: `/auth status [provider] [account] [session_id]`") != null);
    try std.testing.expect(status_usage.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, status_usage.metadataJson.?, "\"error\":\"invalid_status_args\"") != null);

    var bad_url = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-bad-url-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth url qwen mobile --bogus\"}}");
    defer bad_url.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, bad_url.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, bad_url.reply, "Unknown status option `--bogus`") != null);
    try std.testing.expect(bad_url.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_url.metadataJson.?, "\"type\":\"auth.url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_url.metadataJson.?, "\"error\":\"invalid_url_args\"") != null);

    var url_usage = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-url-usage-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth link qwen mobile extra\"}}");
    defer url_usage.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, url_usage.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, url_usage.reply, "Usage: `/auth status [provider] [account] [session_id]`") != null);
    try std.testing.expect(url_usage.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, url_usage.metadataJson.?, "\"type\":\"auth.url\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, url_usage.metadataJson.?, "\"error\":\"invalid_url_args\"") != null);

    var bad_wait = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-bad-wait-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth wait qwen mobile --timeout 0\"}}");
    defer bad_wait.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, bad_wait.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, bad_wait.reply, "Timeout must be an integer between 1 and 900 seconds.") != null);
    try std.testing.expect(bad_wait.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_wait.metadataJson.?, "\"type\":\"auth.wait\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_wait.metadataJson.?, "\"error\":\"invalid_timeout\"") != null);

    var wait_usage = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-wait-usage-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth wait session\"}}");
    defer wait_usage.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, wait_usage.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, wait_usage.reply, "Usage: `/auth wait <provider> [session_id] [account] [--timeout <seconds>]`") != null);
    try std.testing.expect(wait_usage.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, wait_usage.metadataJson.?, "\"error\":\"invalid_wait_args\"") != null);

    var bad_wait_option = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-bad-wait-option-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth wait qwen mobile --bogus\"}}");
    defer bad_wait_option.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, bad_wait_option.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, bad_wait_option.reply, "Unknown wait option `--bogus`.") != null);
    try std.testing.expect(bad_wait_option.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_wait_option.metadataJson.?, "\"type\":\"auth.wait\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_wait_option.metadataJson.?, "\"error\":\"invalid_wait_args\"") != null);

    const bad_complete_frame = try std.fmt.allocPrint(
        allocator,
        "{{\"id\":\"tg-bad-complete-auth\",\"method\":\"send\",\"params\":{{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth complete qwen {s} {s} mobile extra\"}}}}",
        .{ start.loginCode, start.loginSessionId },
    );
    defer allocator.free(bad_complete_frame);
    var bad_complete = try runtime.sendFromFrame(allocator, bad_complete_frame);
    defer bad_complete.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, bad_complete.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, bad_complete.reply, "Usage: `/auth complete <provider> <callback_url_or_code> [session_id] [account]`") != null);
    try std.testing.expect(bad_complete.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_complete.metadataJson.?, "\"type\":\"auth.complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_complete.metadataJson.?, "\"error\":\"invalid_complete_args\"") != null);

    var bad_cancel = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-bad-cancel-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth cancel qwen mobile --bogus\"}}");
    defer bad_cancel.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, bad_cancel.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, bad_cancel.reply, "Unknown status option `--bogus`") != null);
    try std.testing.expect(bad_cancel.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_cancel.metadataJson.?, "\"type\":\"auth.cancel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_cancel.metadataJson.?, "\"error\":\"invalid_cancel_args\"") != null);

    var cancel_usage = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-cancel-usage-auth\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-invalid-auth\",\"sessionId\":\"sess-invalid-auth\",\"message\":\"/auth cancel qwen mobile extra\"}}");
    defer cancel_usage.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, cancel_usage.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, cancel_usage.reply, "Usage: `/auth status [provider] [account] [session_id]`") != null);
    try std.testing.expect(cancel_usage.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, cancel_usage.metadataJson.?, "\"type\":\"auth.cancel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cancel_usage.metadataJson.?, "\"error\":\"invalid_cancel_args\"") != null);
}

test "telegram runtime auth invalid action and complete usage use go-style help text" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;

    var invalid = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-invalid-action\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-auth-invalid\",\"sessionId\":\"sess-auth-invalid\",\"message\":\"/auth nonsense\"}}");
    defer invalid.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, invalid.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, invalid.reply, "Unknown `/auth` action. Use `/auth help` for full usage.") != null);
    try std.testing.expect(invalid.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, invalid.metadataJson.?, "\"error\":\"unknown_action\"") != null);

    var complete_usage = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-complete-usage\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-auth-invalid\",\"sessionId\":\"sess-auth-invalid\",\"message\":\"/auth complete\"}}");
    defer complete_usage.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, complete_usage.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, complete_usage.reply, "Usage: `/auth complete <provider> <callback_url_or_code> [session_id] [account]`") != null);
    try std.testing.expect(complete_usage.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, complete_usage.metadataJson.?, "\"error\":\"invalid_complete_args\"") != null);

    var provider_only_usage = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-complete-provider-only\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-auth-invalid\",\"sessionId\":\"sess-auth-invalid\",\"message\":\"/auth complete qwen\"}}");
    defer provider_only_usage.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, provider_only_usage.authStatus, "invalid"));
    try std.testing.expect(std.mem.indexOf(u8, provider_only_usage.reply, "Usage: `/auth complete <provider> <callback_url_or_code> [session_id] [account]`") != null);
    try std.testing.expect(provider_only_usage.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, provider_only_usage.metadataJson.?, "\"error\":\"invalid_complete_args\"") != null);
}

test "telegram runtime cancel without active session returns none status metadata" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var cancel = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-cancel-none\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-cancel-none\",\"sessionId\":\"sess-cancel-none\",\"message\":\"/auth cancel qwen mobile\"}}");
    defer cancel.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, cancel.authStatus, "none"));
    try std.testing.expect(std.mem.indexOf(u8, cancel.reply, "No active auth session for this target.") != null);
    try std.testing.expect(cancel.metadataJson != null);
    try std.testing.expect(std.mem.indexOf(u8, cancel.metadataJson.?, "\"type\":\"auth.cancel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cancel.metadataJson.?, "\"status\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, cancel.metadataJson.?, "\"revoked\"") == null);
}

test "telegram runtime wait supports positional timeout with account" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var model_set = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-model-wait\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-wait\",\"sessionId\":\"sess-wait\",\"message\":\"/model qwen/qwen-max\"}}");
    defer model_set.deinit(allocator);
    var start = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-start-wait\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-wait\",\"sessionId\":\"sess-wait\",\"message\":\"/auth start qwen mobile\"}}");
    defer start.deinit(allocator);

    var wait = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-wait-positional\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-wait\",\"sessionId\":\"sess-wait\",\"message\":\"/auth wait qwen mobile 45\"}}");
    defer wait.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, wait.reply, "Auth wait result: `pending`") != null);
}

test "telegram runtime completion budget keeps system and newest user turn" {
    const allocator = std.testing.allocator;
    var messages: std.ArrayList(lightpanda.CompletionMessage) = .empty;
    defer {
        for (messages.items) |entry| {
            allocator.free(entry.role);
            allocator.free(entry.content);
        }
        messages.deinit(allocator);
    }

    const old_user = try allocator.alloc(u8, 3000);
    defer allocator.free(old_user);
    @memset(old_user, 'a');
    const old_assistant = try allocator.alloc(u8, 3000);
    defer allocator.free(old_assistant);
    @memset(old_assistant, 'b');
    const latest_user = try allocator.alloc(u8, 3000);
    defer allocator.free(latest_user);
    @memset(latest_user, 'z');

    try TelegramRuntime.appendCompletionMessage(allocator, &messages, "system", "system context");
    try TelegramRuntime.appendCompletionMessage(allocator, &messages, "user", old_user);
    try TelegramRuntime.appendCompletionMessage(allocator, &messages, "assistant", old_assistant);
    try TelegramRuntime.appendCompletionMessage(allocator, &messages, "user", latest_user);
    try TelegramRuntime.trimCompletionMessagesToBudget(allocator, &messages, 128);

    try std.testing.expect(messages.items.len >= 2);
    try std.testing.expect(std.ascii.eqlIgnoreCase(messages.items[0].role, "system"));
    try std.testing.expect(std.ascii.eqlIgnoreCase(messages.items[messages.items.len - 1].role, "user"));
    try std.testing.expect(TelegramRuntime.completionMessagesTotalChars(messages.items) <= 128);
    try std.testing.expect(messages.items[messages.items.len - 1].content.len > 0);
    try std.testing.expect(messages.items[messages.items.len - 1].content[0] == 'z');
}

test "telegram runtime persistence roundtrip restores model auth binding and queue" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    {
        var login = web_login.LoginManager.init(allocator, 5 * 60 * 1000);
        defer login.deinit();
        try login.configurePersistence(root);

        var runtime = TelegramRuntime.init(allocator, &login);
        defer runtime.deinit();
        try runtime.configurePersistence(root);

        var model_set = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-persist-model\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-persist\",\"sessionId\":\"sess-persist\",\"message\":\"/model qwen/qwen-max\"}}");
        defer model_set.deinit(allocator);
        try std.testing.expect(std.mem.eql(u8, model_set.provider, "qwen"));

        var start = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-persist-start\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-persist\",\"sessionId\":\"sess-persist\",\"message\":\"/auth start qwen mobile\"}}");
        defer start.deinit(allocator);
        try std.testing.expect(start.loginSessionId.len > 0);

        var guest = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-persist-guest\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-persist\",\"sessionId\":\"sess-persist\",\"message\":\"/auth guest qwen mobile\"}}");
        defer guest.deinit(allocator);
        try std.testing.expect(std.mem.eql(u8, guest.authStatus, "authorized"));

        var chat = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-persist-chat\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-persist\",\"sessionId\":\"sess-persist\",\"message\":\"hello after restart\"}}");
        defer chat.deinit(allocator);
        try std.testing.expect(chat.queueDepth > 0);
    }

    {
        var login = web_login.LoginManager.init(allocator, 5 * 60 * 1000);
        defer login.deinit();
        try login.configurePersistence(root);

        var runtime = TelegramRuntime.init(allocator, &login);
        defer runtime.deinit();
        try runtime.configurePersistence(root);

        const status = runtime.status();
        try std.testing.expect(status.targetCount > 0);
        try std.testing.expect(status.authBindingCount > 0);
        try std.testing.expect(status.queueDepth > 0);

        var auth_status = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-persist-status\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-persist\",\"sessionId\":\"sess-persist\",\"message\":\"/auth status qwen mobile\"}}");
        defer auth_status.deinit(allocator);
        try std.testing.expect(std.mem.eql(u8, auth_status.authStatus, "authorized"));

        var model_check = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-persist-model-check\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-persist\",\"sessionId\":\"sess-persist\",\"message\":\"/model\"}}");
        defer model_check.deinit(allocator);
        try std.testing.expect(std.mem.indexOf(u8, model_check.reply, "qwen/") != null);

        var poll = try runtime.pollFromFrame(allocator, "{\"id\":\"tg-persist-poll\",\"method\":\"poll\",\"params\":{\"channel\":\"telegram\",\"limit\":20}}");
        defer poll.deinit(allocator);
        try std.testing.expect(poll.count > 0);
    }
}
