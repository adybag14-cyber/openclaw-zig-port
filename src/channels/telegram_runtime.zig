const std = @import("std");
const lightpanda = @import("../bridge/lightpanda.zig");
const web_login = @import("../bridge/web_login.zig");
const time_util = @import("../util/time.zig");

var process_environ: std.process.Environ = std.process.Environ.empty;

pub const RuntimeError = error{
    InvalidParamsFrame,
    MissingMessage,
    UnsupportedChannel,
};

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
    }
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
    state_path: ?[]u8,
    persistent: bool,

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
            .state_path = null,
            .persistent = false,
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

    pub fn status(self: *TelegramRuntime) StatusView {
        return .{
            .enabled = true,
            .status = "ready",
            .queueDepth = self.queue.items.len,
            .targetCount = self.target_models.count(),
            .authBindingCount = self.auth_bindings.count(),
        };
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
        defer if (outcome.audio_base64) |audio| allocator.free(audio);
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
        login_code: []const u8,
        auth_status: []const u8,
        bridge_used: bool = false,
        audio_base64: ?[]u8 = null,
        audio_format: []const u8 = "",
        audio_bytes: usize = 0,
        audio_provider_used: []const u8 = "",
        audio_source: []const u8 = "",
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

        var bridge_used = false;
        const reply = blk: {
            if (authorized) {
                if (try self.tryGenerateBridgeReply(allocator, provider, model, login_session, message)) |generated| {
                    bridge_used = true;
                    break :blk generated;
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
            .provider = provider,
            .model = model,
            .login_session_id = login_session,
            .login_code = "",
            .auth_status = if (authorized) "authorized" else auth_status,
            .bridge_used = bridge_used,
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
            .queueDepth = self.queue.items.len,
        };
    }

    fn tryGenerateBridgeReply(
        self: *TelegramRuntime,
        allocator: std.mem.Allocator,
        provider: []const u8,
        model: []const u8,
        login_session_id: []const u8,
        message: []const u8,
    ) !?[]u8 {
        const trimmed_message = std.mem.trim(u8, message, " \t\r\n");
        if (trimmed_message.len == 0) return null;

        const completion = lightpanda.complete("lightpanda", provider, model, "") catch return null;

        var completion_messages: std.ArrayList(lightpanda.CompletionMessage) = .empty;
        defer {
            for (completion_messages.items) |entry| {
                allocator.free(entry.role);
                allocator.free(entry.content);
            }
            completion_messages.deinit(allocator);
        }

        const role_copy = try allocator.dupe(u8, "user");
        errdefer allocator.free(role_copy);
        const content_copy = try allocator.dupe(u8, trimmed_message);
        errdefer allocator.free(content_copy);
        try completion_messages.append(allocator, .{
            .role = role_copy,
            .content = content_copy,
        });

        var execution = lightpanda.executeCompletion(
            allocator,
            self.bridge_endpoint,
            self.bridge_timeout_ms,
            completion.provider,
            completion.model,
            completion_messages.items,
            null,
            null,
            login_session_id,
            "",
        ) catch return null;
        defer execution.deinit(allocator);

        if (!execution.ok) return null;
        const assistant_text = std.mem.trim(u8, execution.assistantText, " \t\r\n");
        if (assistant_text.len == 0) return null;
        return try allocator.dupe(u8, assistant_text);
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
            return .{ .is_command = true, .command_name = "help", .reply = try allocator.dupe(u8, "Commands: /model, /auth, /tts, /start, /help"), .provider = "chatgpt", .model = "gpt-5.2", .login_session_id = "", .login_code = "", .auth_status = "ok" };
        }

        var command = tokens.items[0];
        if (command.len > 0 and command[0] == '/') command = command[1..];
        if (std.mem.indexOfScalar(u8, command, '@')) |at| command = command[0..at];

        const args = if (tokens.items.len > 1) tokens.items[1..] else &[_][]const u8{};
        if (std.ascii.eqlIgnoreCase(command, "help") or std.ascii.eqlIgnoreCase(command, "start")) {
            return .{
                .is_command = true,
                .command_name = "help",
                .reply = try allocator.dupe(u8, "Commands: /model, /auth, /tts, /start, /help"),
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
        if (std.ascii.eqlIgnoreCase(command, "tts")) {
            return self.handleTtsCommand(allocator, target, args);
        }
        return .{
            .is_command = true,
            .command_name = "unknown",
            .reply = try std.fmt.allocPrint(allocator, "Unknown command `{s}`. Supported: /model, /auth, /tts, /start, /help", .{command}),
            .provider = self.getTargetModel(target).provider,
            .model = self.getTargetModel(target).model,
            .login_session_id = "",
            .login_code = "",
            .auth_status = "ok",
        };
    }

    fn handleModelCommand(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, args: []const []const u8) !SendOutcome {
        if (args.len == 0 or std.ascii.eqlIgnoreCase(args[0], "status")) {
            const model_sel = self.getTargetModel(target);
            return .{
                .is_command = true,
                .command_name = "model",
                .reply = try std.fmt.allocPrint(allocator, "Current model: `{s}/{s}`", .{ model_sel.provider, model_sel.model }),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }
        if (std.ascii.eqlIgnoreCase(args[0], "reset")) {
            try self.setTargetModel(target, "chatgpt", "gpt-5.2");
            return .{
                .is_command = true,
                .command_name = "model",
                .reply = try allocator.dupe(u8, "Model reset to `chatgpt/gpt-5.2`."),
                .provider = "chatgpt",
                .model = "gpt-5.2",
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }

        var provider = self.getTargetModel(target).provider;
        var model = self.getTargetModel(target).model;
        if (std.mem.indexOfScalar(u8, args[0], '/')) |split| {
            provider = normalizeProvider(args[0][0..split]);
            model = normalizeModel(args[0][split + 1 ..]);
        } else if (args.len >= 2) {
            provider = normalizeProvider(args[0]);
            model = normalizeModel(args[1]);
        } else {
            model = normalizeModel(args[0]);
        }
        if (provider.len == 0) provider = "chatgpt";
        if (model.len == 0) model = defaultModelForProvider(provider);
        try self.setTargetModel(target, provider, model);
        return .{
            .is_command = true,
            .command_name = "model",
            .reply = try std.fmt.allocPrint(allocator, "Model set to `{s}/{s}`.", .{ provider, model }),
            .provider = provider,
            .model = model,
            .login_session_id = "",
            .login_code = "",
            .auth_status = "ok",
        };
    }

    fn handleTtsCommand(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, args: []const []const u8) !SendOutcome {
        const model_sel = self.getTargetModel(target);
        const action = if (args.len == 0) "help" else args[0];
        const rest = if (args.len > 1) args[1..] else &[_][]const u8{};

        if (std.ascii.eqlIgnoreCase(action, "help")) {
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try allocator.dupe(u8, "TTS command usage:\n/tts status\n/tts providers\n/tts provider <openai|elevenlabs|kittentts|edge>\n/tts on\n/tts off\n/tts speak <text>\n/tts help"),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "status")) {
            const has_openai_key = ttsProviderApiKeyAvailable(allocator, "openai");
            const has_elevenlabs_key = ttsProviderApiKeyAvailable(allocator, "elevenlabs");
            const has_kittentts_bin = kittenttsBinaryAvailable(allocator);
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try std.fmt.allocPrint(
                    allocator,
                    "TTS status: {s}\nProvider: {s}\nFallback: edge\nOpenAI key: {s}\nElevenLabs key: {s}\nKittenTTS binary: {s}",
                    .{
                        if (self.tts_enabled) "enabled" else "disabled",
                        self.tts_provider,
                        if (has_openai_key) "yes" else "no",
                        if (has_elevenlabs_key) "yes" else "no",
                        if (has_kittentts_bin) "yes" else "no",
                    },
                ),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "providers")) {
            const has_openai_key = ttsProviderApiKeyAvailable(allocator, "openai");
            const has_elevenlabs_key = ttsProviderApiKeyAvailable(allocator, "elevenlabs");
            const has_kittentts_bin = kittenttsBinaryAvailable(allocator);
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try std.fmt.allocPrint(
                    allocator,
                    "TTS providers (active: {s}):\n- openai ({s})\n- elevenlabs ({s})\n- kittentts ({s})\n- edge (configured)",
                    .{
                        self.tts_provider,
                        if (has_openai_key) "configured" else "not configured",
                        if (has_elevenlabs_key) "configured" else "not configured",
                        if (has_kittentts_bin) "configured" else "not configured",
                    },
                ),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "on") or std.ascii.eqlIgnoreCase(action, "enable")) {
            self.tts_enabled = true;
            if (self.persistent) try self.persist();
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try allocator.dupe(u8, "TTS enabled. New replies will include a Telegram audio clip when synthesis succeeds."),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "off") or std.ascii.eqlIgnoreCase(action, "disable")) {
            self.tts_enabled = false;
            if (self.persistent) try self.persist();
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try allocator.dupe(u8, "TTS disabled."),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "provider")) {
            const provider = if (rest.len > 0) normalizeTtsProvider(rest[0]) else "";
            if (!isSupportedTtsProvider(provider)) {
                return .{
                    .is_command = true,
                    .command_name = "tts",
                    .reply = try allocator.dupe(u8, "Usage: /tts provider <openai|elevenlabs|kittentts|edge>"),
                    .provider = model_sel.provider,
                    .model = model_sel.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "invalid",
                };
            }
            self.allocator.free(self.tts_provider);
            self.tts_provider = try self.allocator.dupe(u8, provider);
            if (self.persistent) try self.persist();
            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try std.fmt.allocPrint(allocator, "TTS provider set: {s}", .{self.tts_provider}),
                .provider = model_sel.provider,
                .model = model_sel.model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }

        if (std.ascii.eqlIgnoreCase(action, "speak")) {
            const text = if (rest.len > 0) try std.mem.join(allocator, " ", rest) else try allocator.dupe(u8, "");
            defer allocator.free(text);
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len == 0) {
                return .{
                    .is_command = true,
                    .command_name = "tts",
                    .reply = try allocator.dupe(u8, "Usage: /tts speak <text>"),
                    .provider = model_sel.provider,
                    .model = model_sel.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "invalid",
                };
            }
            if (!self.tts_enabled) {
                return .{
                    .is_command = true,
                    .command_name = "tts",
                    .reply = try allocator.dupe(u8, "TTS is disabled. Run `/tts on` first."),
                    .provider = model_sel.provider,
                    .model = model_sel.model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "ok",
                };
            }

            const provider_used = normalizeTtsProvider(self.tts_provider);
            const source = resolveTtsSource(allocator, provider_used);
            const audio_base64 = try synthesizeTelegramTtsClipBase64(allocator, trimmed, provider_used, source);

            return .{
                .is_command = true,
                .command_name = "tts",
                .reply = try std.fmt.allocPrint(allocator, "TTS clip sent (providerUsed: {s}, source: {s}).", .{ provider_used, source }),
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
            };
        }

        return .{
            .is_command = true,
            .command_name = "tts",
            .reply = try std.fmt.allocPrint(allocator, "Unknown /tts subcommand `{s}`.\n\nTTS command usage:\n/tts status\n/tts providers\n/tts provider <openai|elevenlabs|kittentts|edge>\n/tts on\n/tts off\n/tts speak <text>\n/tts help", .{action}),
            .provider = model_sel.provider,
            .model = model_sel.model,
            .login_session_id = "",
            .login_code = "",
            .auth_status = "invalid",
        };
    }

    fn handleAuthCommand(self: *TelegramRuntime, allocator: std.mem.Allocator, target: []const u8, args: []const []const u8) !SendOutcome {
        const model_sel = self.getTargetModel(target);
        const default_provider = normalizeProvider(model_sel.provider);
        const default_model = normalizeModel(model_sel.model);
        const action = if (args.len == 0) "start" else args[0];
        const rest = if (args.len > 1) args[1..] else &[_][]const u8{};

        if (std.ascii.eqlIgnoreCase(action, "help")) {
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try allocator.dupe(u8, "Usage: /auth [start|status|wait|link|open|complete|guest|cancel|providers|bridge]\nExamples:\n/auth start qwen mobile --force\n/auth link qwen mobile\n/auth wait qwen mobile --timeout 45\n/auth complete qwen <callback_url_or_code> <session_id> mobile"),
                .provider = default_provider,
                .model = default_model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "providers")) {
            const provider_lines =
                \\chatgpt (mode:device_code, guest:false)
                \\codex (mode:device_code, guest:false)
                \\claude (mode:device_code, guest:false)
                \\gemini (mode:device_code, guest:false)
                \\openrouter (mode:api_key_or_oauth, guest:false)
                \\opencode (mode:api_key_or_oauth, guest:false)
                \\qwen (mode:guest_or_code, guest:true, popup:Stay logged out)
                \\zai/glm-5 (mode:guest_or_code, guest:true, popup:Stay logged out)
                \\inception/mercury-2 (mode:guest_or_code, guest:true, popup:Stay logged out)
                \\minimax (mode:device_code, guest:false)
                \\kimi (mode:device_code, guest:false)
                \\zhipuai (mode:device_code, guest:false)
            ;
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "Auth providers:\n{s}", .{provider_lines}),
                .provider = default_provider,
                .model = default_model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "bridge")) {
            const bridge_provider = if (rest.len > 0 and isKnownProvider(rest[0])) normalizeProvider(rest[0]) else default_provider;
            const guidance = providerBridgeGuidance(bridge_provider);
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "{s}", .{guidance}),
                .provider = bridge_provider,
                .model = defaultModelForProvider(bridge_provider),
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "link") or std.ascii.eqlIgnoreCase(action, "open")) {
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
                if (std.mem.eql(u8, normalizeAccount(account), "default")) {
                    account = token;
                    continue;
                }
            }

            const bound_session = try self.getAuthBinding(allocator, target, provider, account);
            const login_session = if (std.mem.trim(u8, session_token, " \t\r\n").len > 0) session_token else bound_session;
            if (std.mem.trim(u8, login_session, " \t\r\n").len == 0) {
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "No active auth session for `{s}` account `{s}`. Start with `/auth start {s} {s}`.", .{ provider, normalizeAccount(account), provider, normalizeAccount(account) }),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "pending",
                };
            }

            const view = self.login_manager.get(login_session) orelse return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try allocator.dupe(u8, "Auth session not found."),
                .provider = provider,
                .model = defaultModelForProvider(provider),
                .login_session_id = login_session,
                .login_code = "",
                .auth_status = "missing",
            };
            const account_norm = normalizeAccount(account);
            const account_is_default = std.mem.eql(u8, account_norm, "default");
            const reply = if (view.guestBypassSupported)
                (if (account_is_default)
                    try std.fmt.allocPrint(
                        allocator,
                        "Auth link for `{s}`.\nStatus: `{s}`\nSession: `{s}`\nOpen: {s}\nCode: `{s}`\nThen run `/auth guest {s}` or `/auth complete {s} <callback_url_or_code> {s}`.",
                        .{ provider, view.status, view.loginSessionId, view.verificationUriComplete, view.code, provider, provider, view.loginSessionId },
                    )
                else
                    try std.fmt.allocPrint(
                        allocator,
                        "Auth link for `{s}` account `{s}`.\nStatus: `{s}`\nSession: `{s}`\nOpen: {s}\nCode: `{s}`\nThen run `/auth guest {s} {s}` or `/auth complete {s} <callback_url_or_code> {s} {s}`.",
                        .{ provider, account_norm, view.status, view.loginSessionId, view.verificationUriComplete, view.code, provider, account_norm, provider, view.loginSessionId, account_norm },
                    ))
            else
                (if (account_is_default)
                    try std.fmt.allocPrint(
                        allocator,
                        "Auth link for `{s}`.\nStatus: `{s}`\nSession: `{s}`\nOpen: {s}\nCode: `{s}`\nThen run `/auth complete {s} <callback_url_or_code> {s}`.",
                        .{ provider, view.status, view.loginSessionId, view.verificationUriComplete, view.code, provider, view.loginSessionId },
                    )
                else
                    try std.fmt.allocPrint(
                        allocator,
                        "Auth link for `{s}` account `{s}`.\nStatus: `{s}`\nSession: `{s}`\nOpen: {s}\nCode: `{s}`\nThen run `/auth complete {s} <callback_url_or_code> {s} {s}`.",
                        .{ provider, account_norm, view.status, view.loginSessionId, view.verificationUriComplete, view.code, provider, view.loginSessionId, account_norm },
                    ));
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = reply,
                .provider = provider,
                .model = view.model,
                .login_session_id = view.loginSessionId,
                .login_code = view.code,
                .auth_status = view.status,
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
                    return .{
                        .is_command = true,
                        .command_name = "auth",
                        .reply = try std.fmt.allocPrint(allocator, "Unknown option `{s}`. Usage: /auth start <provider> [account] [--force]", .{token}),
                        .provider = provider,
                        .model = defaultModelForProvider(provider),
                        .login_session_id = "",
                        .login_code = "",
                        .auth_status = "invalid",
                    };
                }
                if (std.mem.eql(u8, account, "default")) {
                    account = token;
                    continue;
                }
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Usage: /auth start <provider> [account] [--force]"),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "invalid",
                };
            }

            const model = if (std.ascii.eqlIgnoreCase(provider, default_provider)) default_model else defaultModelForProvider(provider);
            const existing_session = try self.getAuthBinding(allocator, target, provider, account);
            if (!force and existing_session.len > 0) {
                if (self.login_manager.get(existing_session)) |existing| {
                    if (std.ascii.eqlIgnoreCase(existing.status, "pending") or std.ascii.eqlIgnoreCase(existing.status, "authorized")) {
                        const account_norm = normalizeAccount(account);
                        const account_is_default = std.mem.eql(u8, account_norm, "default");
                        const reply = if (existing.guestBypassSupported)
                            (if (account_is_default)
                                try std.fmt.allocPrint(allocator, "Auth already {s} for `{s}`.\nOpen: {s}\nThen run `/auth guest {s}` or `/auth complete {s} <callback_url_or_code>`.\nUse `--force` to replace session.", .{ existing.status, provider, existing.verificationUriComplete, provider, provider })
                            else
                                try std.fmt.allocPrint(allocator, "Auth already {s} for `{s}` account `{s}`.\nOpen: {s}\nThen run `/auth guest {s} {s}` or `/auth complete {s} <callback_url_or_code> {s}`.\nUse `--force` to replace session.", .{ existing.status, provider, account_norm, existing.verificationUriComplete, provider, account_norm, provider, account_norm }))
                        else
                            (if (account_is_default)
                                try std.fmt.allocPrint(allocator, "Auth already {s} for `{s}`.\nOpen: {s}\nThen run `/auth complete {s} <callback_url_or_code>`.\nUse `--force` to replace session.", .{ existing.status, provider, existing.verificationUriComplete, provider })
                            else
                                try std.fmt.allocPrint(allocator, "Auth already {s} for `{s}` account `{s}`.\nOpen: {s}\nThen run `/auth complete {s} <callback_url_or_code> {s}`.\nUse `--force` to replace session.", .{ existing.status, provider, account_norm, existing.verificationUriComplete, provider, account_norm }));
                        return .{
                            .is_command = true,
                            .command_name = "auth",
                            .reply = reply,
                            .provider = provider,
                            .model = existing.model,
                            .login_session_id = existing.loginSessionId,
                            .login_code = existing.code,
                            .auth_status = existing.status,
                        };
                    }
                }
            }

            const started = try self.login_manager.start(provider, model);
            try self.setAuthBinding(target, provider, account, started.loginSessionId);
            const account_norm = normalizeAccount(account);
            const account_is_default = std.mem.eql(u8, account_norm, "default");
            const reply = if (started.guestBypassSupported)
                (if (account_is_default)
                    try std.fmt.allocPrint(allocator, "Auth started for `{s}`.\nOpen: {s}\n{s}\nThen run `/auth guest {s}` (or `/auth complete {s} <callback_url_or_code>`).", .{ provider, started.verificationUriComplete, started.guestBypassHint, provider, provider })
                else
                    try std.fmt.allocPrint(allocator, "Auth started for `{s}` account `{s}`.\nOpen: {s}\n{s}\nThen run `/auth guest {s} {s}` (or `/auth complete {s} <callback_url_or_code> {s}`).", .{ provider, account_norm, started.verificationUriComplete, started.guestBypassHint, provider, account_norm, provider, account_norm }))
            else
                (if (account_is_default)
                    try std.fmt.allocPrint(allocator, "Auth started for `{s}`.\nOpen: {s}\nThen run `/auth complete {s} <callback_url_or_code>`", .{ provider, started.verificationUriComplete, provider })
                else
                    try std.fmt.allocPrint(allocator, "Auth started for `{s}` account `{s}`.\nOpen: {s}\nThen run `/auth complete {s} <callback_url_or_code> {s}`", .{ provider, account_norm, started.verificationUriComplete, provider, account_norm }));
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = reply,
                .provider = provider,
                .model = model,
                .login_session_id = started.loginSessionId,
                .login_code = started.code,
                .auth_status = started.status,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "status") or std.ascii.eqlIgnoreCase(action, "wait")) {
            var provider = default_provider;
            var account: []const u8 = "default";
            var session_token: []const u8 = "";
            var timeout_secs: u32 = 30;
            var index: usize = 0;
            if (rest.len > 0 and isKnownProvider(rest[0])) {
                provider = normalizeProvider(rest[0]);
                index = 1;
            }
            while (index < rest.len) : (index += 1) {
                const token = std.mem.trim(u8, rest[index], " \t\r\n");
                if (token.len == 0) continue;
                if (std.ascii.eqlIgnoreCase(token, "--timeout")) {
                    if (index + 1 >= rest.len) {
                        return .{
                            .is_command = true,
                            .command_name = "auth",
                            .reply = try allocator.dupe(u8, "Missing value for --timeout."),
                            .provider = provider,
                            .model = defaultModelForProvider(provider),
                            .login_session_id = "",
                            .login_code = "",
                            .auth_status = "invalid",
                        };
                    }
                    timeout_secs = std.fmt.parseInt(u32, std.mem.trim(u8, rest[index + 1], " \t\r\n"), 10) catch 30;
                    index += 1;
                    continue;
                }
                if (std.ascii.startsWithIgnoreCase(token, "--")) continue;
                if (std.ascii.eqlIgnoreCase(action, "wait") and session_token.len == 0 and std.mem.eql(u8, normalizeAccount(account), "default")) {
                    if (std.fmt.parseInt(u32, token, 10)) |parsed_timeout| {
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
            }

            const bound_session = try self.getAuthBinding(allocator, target, provider, account);
            const login_session = if (std.mem.trim(u8, session_token, " \t\r\n").len > 0) session_token else bound_session;
            if (std.mem.trim(u8, login_session, " \t\r\n").len == 0) {
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "No active auth session for `{s}` account `{s}`.", .{ provider, normalizeAccount(account) }),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "pending",
                };
            }

            if (std.ascii.eqlIgnoreCase(action, "wait")) {
                const timeout_ms: u32 = timeout_secs * 1000;
                const waited = self.login_manager.wait(login_session, timeout_ms) catch |err| switch (err) {
                    error.SessionNotFound => return .{
                        .is_command = true,
                        .command_name = "auth",
                        .reply = try allocator.dupe(u8, "Auth wait failed: session not found."),
                        .provider = provider,
                        .model = defaultModelForProvider(provider),
                        .login_session_id = login_session,
                        .login_code = "",
                        .auth_status = "missing",
                    },
                    error.SessionExpired => return .{
                        .is_command = true,
                        .command_name = "auth",
                        .reply = try allocator.dupe(u8, "Auth wait failed: session expired."),
                        .provider = provider,
                        .model = defaultModelForProvider(provider),
                        .login_session_id = login_session,
                        .login_code = "",
                        .auth_status = "expired",
                    },
                    error.InvalidCode => unreachable,
                };
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "Auth wait result: `{s}` (session `{s}`).", .{ waited.status, waited.loginSessionId }),
                    .provider = provider,
                    .model = waited.model,
                    .login_session_id = waited.loginSessionId,
                    .login_code = waited.code,
                    .auth_status = waited.status,
                };
            }

            const view = self.login_manager.get(login_session) orelse return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try allocator.dupe(u8, "Auth session not found."),
                .provider = provider,
                .model = defaultModelForProvider(provider),
                .login_session_id = login_session,
                .login_code = "",
                .auth_status = "missing",
            };
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "Auth status: `{s}` (session `{s}`).", .{ view.status, view.loginSessionId }),
                .provider = provider,
                .model = view.model,
                .login_session_id = view.loginSessionId,
                .login_code = view.code,
                .auth_status = view.status,
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
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "No pending auth session for `{s}` account `{s}`. Start with `/auth start {s} {s}`.", .{ provider, normalizeAccount(account), provider, normalizeAccount(account) }),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "pending",
                };
            }
            const completed = self.login_manager.complete(login_session, "") catch |err| switch (err) {
                error.InvalidCode => return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "Guest completion is not supported for `{s}`. Use `/auth complete {s} <code_or_url>`.", .{ provider, provider }),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = login_session,
                    .login_code = "",
                    .auth_status = "rejected",
                },
                error.SessionExpired => return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Auth failed: session expired."),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = login_session,
                    .login_code = "",
                    .auth_status = "expired",
                },
                error.SessionNotFound => return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Auth failed: session not found."),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = login_session,
                    .login_code = "",
                    .auth_status = "missing",
                },
            };
            try self.setAuthBinding(target, provider, account, completed.loginSessionId);
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "Guest auth completed for `{s}` account `{s}`. Session `{s}` is `{s}`.", .{ provider, normalizeAccount(account), completed.loginSessionId, completed.status }),
                .provider = provider,
                .model = completed.model,
                .login_session_id = completed.loginSessionId,
                .login_code = "",
                .auth_status = completed.status,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "complete")) {
            if (rest.len == 0) {
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Missing code. Usage: /auth complete <provider> <callback_url_or_code> [session_id] [account]"),
                    .provider = default_provider,
                    .model = default_model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "pending",
                };
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
            }

            if (code_token.len == 0) {
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Missing code. Usage: /auth complete <provider> <callback_url_or_code> [session_id] [account]"),
                    .provider = default_provider,
                    .model = default_model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "pending",
                };
            }

            if (!isKnownProvider(rest[0])) {
                if (inferProviderFromAuthInput(code_token)) |inferred| {
                    provider = inferred;
                }
            }

            const bound_session = try self.getAuthBinding(allocator, target, provider, account);
            const login_session = if (std.mem.trim(u8, session_token, " \t\r\n").len > 0) session_token else bound_session;
            if (std.mem.trim(u8, login_session, " \t\r\n").len == 0) {
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "No pending auth session for `{s}` account `{s}`. Start with `/auth start {s} {s}`.", .{ provider, normalizeAccount(account), provider, normalizeAccount(account) }),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "pending",
                };
            }

            const code = web_login.extractAuthCode(code_token);
            const completed = self.login_manager.complete(login_session, code) catch |err| switch (err) {
                error.InvalidCode => return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = if (web_login.supportsGuestBypass(provider))
                        try std.fmt.allocPrint(allocator, "Auth failed: invalid code. For `{s}` you can also run `/auth guest {s}` after choosing 'Stay logged out'.", .{ provider, provider })
                    else
                        try allocator.dupe(u8, "Auth failed: invalid code."),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = login_session,
                    .login_code = "",
                    .auth_status = "rejected",
                },
                error.SessionExpired => return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Auth failed: session expired."),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = login_session,
                    .login_code = "",
                    .auth_status = "expired",
                },
                error.SessionNotFound => return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try allocator.dupe(u8, "Auth failed: session not found."),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = login_session,
                    .login_code = "",
                    .auth_status = "missing",
                },
            };
            try self.setAuthBinding(target, provider, account, completed.loginSessionId);
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "Auth completed for `{s}` account `{s}`. Session `{s}` is `{s}`.", .{ provider, normalizeAccount(account), completed.loginSessionId, completed.status }),
                .provider = provider,
                .model = completed.model,
                .login_session_id = completed.loginSessionId,
                .login_code = completed.code,
                .auth_status = completed.status,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "cancel") or std.ascii.eqlIgnoreCase(action, "logout")) {
            var provider = default_provider;
            var account: []const u8 = "default";
            var index: usize = 0;
            if (rest.len > 0 and isKnownProvider(rest[0])) {
                provider = normalizeProvider(rest[0]);
                index = 1;
            }
            if (index < rest.len) account = rest[index];
            try self.clearAuthBinding(allocator, target, provider, account);
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "Auth binding cleared for `{s}` account `{s}`.", .{ provider, normalizeAccount(account) }),
                .provider = provider,
                .model = defaultModelForProvider(provider),
                .login_session_id = "",
                .login_code = "",
                .auth_status = "cancelled",
            };
        }

        return .{
            .is_command = true,
            .command_name = "auth",
            .reply = try allocator.dupe(u8, "Unknown `/auth` action. Use `/auth help`."),
            .provider = default_provider,
            .model = default_model,
            .login_session_id = "",
            .login_code = "",
            .auth_status = "invalid",
        };
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
    const trimmed = std.mem.trim(u8, provider_raw, " \t\r\n");
    if (trimmed.len == 0) return "chatgpt";
    if (std.ascii.eqlIgnoreCase(trimmed, "openai") or std.ascii.eqlIgnoreCase(trimmed, "openai-chatgpt") or std.ascii.eqlIgnoreCase(trimmed, "chatgpt.com") or std.ascii.eqlIgnoreCase(trimmed, "chatgpt-web")) return "chatgpt";
    if (std.ascii.eqlIgnoreCase(trimmed, "openai-codex") or std.ascii.eqlIgnoreCase(trimmed, "codex-cli") or std.ascii.eqlIgnoreCase(trimmed, "openai-codex-cli")) return "codex";
    if (std.ascii.eqlIgnoreCase(trimmed, "anthropic") or std.ascii.eqlIgnoreCase(trimmed, "claude-cli") or std.ascii.eqlIgnoreCase(trimmed, "claude-code") or std.ascii.eqlIgnoreCase(trimmed, "claude-desktop")) return "claude";
    if (std.ascii.eqlIgnoreCase(trimmed, "google") or std.ascii.eqlIgnoreCase(trimmed, "google-gemini") or std.ascii.eqlIgnoreCase(trimmed, "google-gemini-cli") or std.ascii.eqlIgnoreCase(trimmed, "gemini-cli")) return "gemini";
    if (std.ascii.eqlIgnoreCase(trimmed, "qwen-portal") or std.ascii.eqlIgnoreCase(trimmed, "qwen-chat") or std.ascii.eqlIgnoreCase(trimmed, "qwen-cli") or std.ascii.eqlIgnoreCase(trimmed, "qwen35") or std.ascii.eqlIgnoreCase(trimmed, "qwen3.5") or std.ascii.eqlIgnoreCase(trimmed, "qwen-3.5") or std.ascii.eqlIgnoreCase(trimmed, "copaw") or std.ascii.eqlIgnoreCase(trimmed, "qwen-copaw") or std.ascii.eqlIgnoreCase(trimmed, "qwen-agent") or std.ascii.eqlIgnoreCase(trimmed, "qwen-free") or std.ascii.eqlIgnoreCase(trimmed, "qwen-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "qwen-free-chat")) return "qwen";
    if (std.ascii.eqlIgnoreCase(trimmed, "minimax-portal") or std.ascii.eqlIgnoreCase(trimmed, "minimax-cli")) return "minimax";
    if (std.ascii.eqlIgnoreCase(trimmed, "kimi-code") or std.ascii.eqlIgnoreCase(trimmed, "kimi-coding") or std.ascii.eqlIgnoreCase(trimmed, "kimi-for-coding")) return "kimi";
    if (std.ascii.eqlIgnoreCase(trimmed, "zhipu") or std.ascii.eqlIgnoreCase(trimmed, "zhipu-ai") or std.ascii.eqlIgnoreCase(trimmed, "bigmodel") or std.ascii.eqlIgnoreCase(trimmed, "bigmodel-cn") or std.ascii.eqlIgnoreCase(trimmed, "zhipuai-coding") or std.ascii.eqlIgnoreCase(trimmed, "zhipu-coding")) return "zhipuai";
    if (std.ascii.eqlIgnoreCase(trimmed, "z.ai") or std.ascii.eqlIgnoreCase(trimmed, "z-ai") or std.ascii.eqlIgnoreCase(trimmed, "zaiweb") or std.ascii.eqlIgnoreCase(trimmed, "zai-web") or std.ascii.eqlIgnoreCase(trimmed, "glm") or std.ascii.eqlIgnoreCase(trimmed, "glm-5") or std.ascii.eqlIgnoreCase(trimmed, "glm5") or std.ascii.eqlIgnoreCase(trimmed, "zai-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "glm-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "glm5-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "glm-5-chat-free")) return "zai";
    if (std.ascii.eqlIgnoreCase(trimmed, "inception-labs") or std.ascii.eqlIgnoreCase(trimmed, "inceptionlabs") or std.ascii.eqlIgnoreCase(trimmed, "mercury") or std.ascii.eqlIgnoreCase(trimmed, "mercury2") or std.ascii.eqlIgnoreCase(trimmed, "mercury-2") or std.ascii.eqlIgnoreCase(trimmed, "inception-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "mercury-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "mercury2-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "mercury-2-chat-free")) return "inception";
    return trimmed;
}

fn normalizeModel(model_raw: []const u8) []const u8 {
    return std.mem.trim(u8, model_raw, " \t\r\n");
}

fn defaultModelForProvider(provider_raw: []const u8) []const u8 {
    const provider = normalizeProvider(provider_raw);
    if (std.ascii.eqlIgnoreCase(provider, "codex")) return "gpt-5.2";
    if (std.ascii.eqlIgnoreCase(provider, "claude")) return "claude-sonnet-4";
    if (std.ascii.eqlIgnoreCase(provider, "gemini")) return "gemini-2.5-pro";
    if (std.ascii.eqlIgnoreCase(provider, "openrouter")) return "openrouter/auto";
    if (std.ascii.eqlIgnoreCase(provider, "opencode")) return "opencode/default";
    if (std.ascii.eqlIgnoreCase(provider, "qwen")) return "qwen-max";
    if (std.ascii.eqlIgnoreCase(provider, "minimax")) return "minimax-m2.5";
    if (std.ascii.eqlIgnoreCase(provider, "kimi")) return "kimi-k2.5";
    if (std.ascii.eqlIgnoreCase(provider, "zhipuai")) return "glm-4.6";
    if (std.ascii.eqlIgnoreCase(provider, "zai")) return "glm-5";
    if (std.ascii.eqlIgnoreCase(provider, "inception")) return "mercury-2";
    return "gpt-5.2";
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
}

test "telegram runtime tts command lifecycle" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var status = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-tts-status\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-tts\",\"sessionId\":\"sess-tts\",\"message\":\"/tts status\"}}");
    defer status.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, status.reply, "TTS status:") != null);

    var provider = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-tts-provider\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-tts\",\"sessionId\":\"sess-tts\",\"message\":\"/tts provider kittentts\"}}");
    defer provider.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, provider.reply, "TTS provider set: kittentts") != null);

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
    try std.testing.expect(std.mem.indexOf(u8, speak.reply, "TTS clip sent") != null);
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
    var chat = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-required\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-auth-required\",\"sessionId\":\"sess-auth-required\",\"message\":\"hello before auth\"}}");
    defer chat.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, chat.replySource, "auth_required"));
    try std.testing.expect(std.mem.indexOf(u8, chat.reply, "Auth required") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, start_result.reply, "/auth guest qwen") != null);

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
    const mobile_session_1 = try allocator.dupe(u8, start_mobile.loginSessionId);
    defer allocator.free(mobile_session_1);

    var start_mobile_repeat = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-start-mobile-repeat\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"/auth start qwen mobile\"}}");
    defer start_mobile_repeat.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, start_mobile_repeat.loginSessionId, mobile_session_1));
    try std.testing.expect(std.mem.indexOf(u8, start_mobile_repeat.reply, "Auth already") != null);

    var start_mobile_force = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-start-mobile-force\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"/auth start qwen mobile --force\"}}");
    defer start_mobile_force.deinit(allocator);
    try std.testing.expect(!std.mem.eql(u8, start_mobile_force.loginSessionId, mobile_session_1));

    var status_mobile = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-status-mobile\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-acc\",\"sessionId\":\"sess-acc\",\"message\":\"/auth status qwen mobile\"}}");
    defer status_mobile.deinit(allocator);
    try std.testing.expect(std.mem.eql(u8, status_mobile.loginSessionId, start_mobile_force.loginSessionId));

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

test "telegram runtime auth bridge and providers help include guest guidance" {
    var login = web_login.LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer login.deinit();
    var runtime = TelegramRuntime.init(std.testing.allocator, &login);
    defer runtime.deinit();

    const allocator = std.testing.allocator;
    var providers = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-providers\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-help\",\"sessionId\":\"sess-help\",\"message\":\"/auth providers\"}}");
    defer providers.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, providers.reply, "qwen (mode:guest_or_code") != null);
    try std.testing.expect(std.mem.indexOf(u8, providers.reply, "zai/glm-5") != null);

    var bridge_qwen = try runtime.sendFromFrame(allocator, "{\"id\":\"tg-auth-bridge-qwen\",\"method\":\"send\",\"params\":{\"channel\":\"telegram\",\"to\":\"room-help\",\"sessionId\":\"sess-help\",\"message\":\"/auth bridge qwen\"}}");
    defer bridge_qwen.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, bridge_qwen.reply, "Stay logged out") != null);
    try std.testing.expect(std.mem.indexOf(u8, bridge_qwen.reply, "/auth guest qwen") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, link.reply, "Auth link for `qwen` account `mobile`.") != null);
    try std.testing.expect(std.mem.indexOf(u8, link.reply, "Open: https://chat.qwen.ai/?openclaw_code=") != null);
    try std.testing.expect(std.mem.indexOf(u8, link.reply, "/auth guest qwen mobile") != null);
    try std.testing.expect(std.mem.indexOf(u8, link.reply, start.loginCode) != null);
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
    try std.testing.expect(std.mem.indexOf(u8, open.reply, "Auth link for `chatgpt`.") != null);
    try std.testing.expect(std.mem.indexOf(u8, open.reply, "/auth complete chatgpt <callback_url_or_code>") != null);
    try std.testing.expect(std.mem.indexOf(u8, open.reply, start.loginCode) != null);
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
