const std = @import("std");
const web_login = @import("../bridge/web_login.zig");
const time_util = @import("../util/time.zig");

pub const RuntimeError = error{
    InvalidParamsFrame,
    MissingMessage,
    UnsupportedChannel,
};

pub const SendResult = struct {
    status: []const u8,
    accepted: bool,
    channel: []u8,
    to: []u8,
    sessionId: []u8,
    command: bool,
    commandName: []u8,
    reply: []u8,
    provider: []u8,
    model: []u8,
    loginSessionId: []u8,
    loginCode: []u8,
    authStatus: []u8,
    queueDepth: usize,

    pub fn deinit(self: *SendResult, allocator: std.mem.Allocator) void {
        allocator.free(self.channel);
        allocator.free(self.to);
        allocator.free(self.sessionId);
        allocator.free(self.commandName);
        allocator.free(self.reply);
        allocator.free(self.provider);
        allocator.free(self.model);
        allocator.free(self.loginSessionId);
        allocator.free(self.loginCode);
        allocator.free(self.authStatus);
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

pub const TelegramRuntime = struct {
    allocator: std.mem.Allocator,
    login_manager: *web_login.LoginManager,
    queue: std.ArrayList(QueuedMessage),
    target_models: std.StringHashMap([]u8),
    auth_bindings: std.StringHashMap([]u8),
    next_update_id: u64,

    pub fn init(allocator: std.mem.Allocator, login_manager: *web_login.LoginManager) TelegramRuntime {
        return .{
            .allocator = allocator,
            .login_manager = login_manager,
            .queue = .empty,
            .target_models = std.StringHashMap([]u8).init(allocator),
            .auth_bindings = std.StringHashMap([]u8).init(allocator),
            .next_update_id = 1,
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

    pub fn sendFromFrame(self: *TelegramRuntime, allocator: std.mem.Allocator, frame_json: []const u8) !SendResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame_json, .{});
        defer parsed.deinit();
        const params = try getParamsObject(parsed.value);

        const channel = getOptionalString(params, "channel", "telegram");
        if (!std.ascii.eqlIgnoreCase(channel, "telegram")) return error.UnsupportedChannel;
        const target = getOptionalString(params, "to", "default");
        const session_id = getOptionalString(params, "sessionId", "tg-chat-default");
        const message = try getRequiredString(params, "message", "text", error.MissingMessage);

        const outcome = try self.handleSendMessage(allocator, target, session_id, std.mem.trim(u8, message, " \t\r\n"));
        defer allocator.free(outcome.reply);
        return self.makeSendResult(allocator, channel, target, session_id, outcome);
    }

    pub fn pollFromFrame(self: *TelegramRuntime, allocator: std.mem.Allocator, frame_json: []const u8) !PollResult {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, frame_json, .{});
        defer parsed.deinit();
        const params = try getParamsObject(parsed.value);
        const channel = getOptionalString(params, "channel", "telegram");
        if (!std.ascii.eqlIgnoreCase(channel, "telegram")) return error.UnsupportedChannel;
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
            var popped = self.queue.orderedRemove(0);
            defer popped.deinit(self.allocator);
            updates[idx] = .{
                .id = popped.id,
                .channel = try allocator.dupe(u8, "telegram"),
                .to = try allocator.dupe(u8, popped.to),
                .sessionId = try allocator.dupe(u8, popped.session_id),
                .role = try allocator.dupe(u8, popped.role),
                .kind = try allocator.dupe(u8, popped.kind),
                .message = try allocator.dupe(u8, popped.message),
                .createdAtMs = popped.created_at_ms,
            };
        }

        return .{
            .status = "ok",
            .channel = try allocator.dupe(u8, "telegram"),
            .count = count,
            .remaining = self.queue.items.len,
            .updates = updates,
        };
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
            try self.enqueue(target, session_id, "assistant", "command_reply", command.reply);
            return command;
        }

        const model_sel = self.getTargetModel(target);
        const provider = model_sel.provider;
        const model = model_sel.model;
        const key = try authBindingKey(allocator, target, provider);
        defer allocator.free(key);

        var login_session: []const u8 = "";
        var auth_status: []const u8 = "pending";
        var authorized = false;
        if (self.auth_bindings.get(key)) |session| {
            login_session = session;
            if (self.login_manager.get(session)) |view| {
                auth_status = view.status;
                authorized = std.ascii.eqlIgnoreCase(view.status, "authorized");
            }
        }

        const reply = if (authorized)
            try std.fmt.allocPrint(allocator, "OpenClaw Zig ({s}/{s}) assistant: {s}", .{ provider, model, message })
        else if (web_login.supportsGuestBypass(provider))
            try std.fmt.allocPrint(allocator, "Auth required for `{s}/{s}`. Run `/auth start {s}`, choose 'Stay logged out' in browser popup, then run `/auth guest {s}` (or `/auth complete {s} guest`).", .{ provider, model, provider, provider, provider })
        else
            try std.fmt.allocPrint(allocator, "Auth required for `{s}/{s}`. Run `/auth start {s}` then `/auth complete {s} <code_or_url>`.", .{ provider, model, provider, provider });

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
        return .{
            .status = "accepted",
            .accepted = true,
            .channel = try allocator.dupe(u8, channel),
            .to = try allocator.dupe(u8, target),
            .sessionId = try allocator.dupe(u8, session_id),
            .command = outcome.is_command,
            .commandName = try allocator.dupe(u8, outcome.command_name),
            .reply = try allocator.dupe(u8, outcome.reply),
            .provider = try allocator.dupe(u8, outcome.provider),
            .model = try allocator.dupe(u8, outcome.model),
            .loginSessionId = try allocator.dupe(u8, outcome.login_session_id),
            .loginCode = try allocator.dupe(u8, outcome.login_code),
            .authStatus = try allocator.dupe(u8, outcome.auth_status),
            .queueDepth = self.queue.items.len,
        };
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
            return .{ .is_command = true, .command_name = "help", .reply = try allocator.dupe(u8, "Commands: /model, /auth, /start, /help"), .provider = "chatgpt", .model = "gpt-5.2", .login_session_id = "", .login_code = "", .auth_status = "ok" };
        }

        var command = tokens.items[0];
        if (command.len > 0 and command[0] == '/') command = command[1..];
        if (std.mem.indexOfScalar(u8, command, '@')) |at| command = command[0..at];

        const args = if (tokens.items.len > 1) tokens.items[1..] else &[_][]const u8{};
        if (std.ascii.eqlIgnoreCase(command, "help") or std.ascii.eqlIgnoreCase(command, "start")) {
            return .{
                .is_command = true,
                .command_name = "help",
                .reply = try allocator.dupe(u8, "Commands: /model, /auth, /start, /help"),
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
        return .{
            .is_command = true,
            .command_name = "unknown",
            .reply = try std.fmt.allocPrint(allocator, "Unknown command `{s}`. Supported: /model, /auth, /start, /help", .{command}),
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
                .reply = try allocator.dupe(u8, "Usage: /auth [start|status|wait|complete|guest|cancel|providers|bridge]"),
                .provider = default_provider,
                .model = default_model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "providers")) {
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try allocator.dupe(u8, "Auth providers: chatgpt, codex, claude, gemini, openrouter, opencode, qwen, zai(glm-5), inception(mercury-2), minimax, kimi, zhipuai"),
                .provider = default_provider,
                .model = default_model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "bridge")) {
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try allocator.dupe(u8, "Browser bridge: lightpanda"),
                .provider = default_provider,
                .model = default_model,
                .login_session_id = "",
                .login_code = "",
                .auth_status = "ok",
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "start")) {
            const provider = if (rest.len > 0 and isKnownProvider(rest[0])) normalizeProvider(rest[0]) else default_provider;
            const model = if (std.ascii.eqlIgnoreCase(provider, default_provider)) default_model else defaultModelForProvider(provider);
            const started = try self.login_manager.start(provider, model);
            try self.setAuthBinding(target, provider, started.loginSessionId);
            const reply = if (started.guestBypassSupported)
                try std.fmt.allocPrint(allocator, "Auth started for `{s}`.\nOpen: {s}\n{s}\nThen run `/auth guest {s}` (or `/auth complete {s} guest`).", .{ provider, started.verificationUriComplete, started.guestBypassHint, provider, provider })
            else
                try std.fmt.allocPrint(allocator, "Auth started for `{s}`.\nOpen: {s}\nThen run `/auth complete {s} <code_or_url>`", .{ provider, started.verificationUriComplete, provider });
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
            const provider = if (rest.len > 0 and isKnownProvider(rest[0])) normalizeProvider(rest[0]) else default_provider;
            const maybe_session = if (rest.len > 1) rest[1] else "";
            const key = try authBindingKey(allocator, target, provider);
            defer allocator.free(key);
            const login_session = if (std.mem.trim(u8, maybe_session, " \t\r\n").len > 0) maybe_session else (self.auth_bindings.get(key) orelse "");
            if (std.mem.trim(u8, login_session, " \t\r\n").len == 0) {
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "No active auth session for `{s}`.", .{provider}),
                    .provider = provider,
                    .model = defaultModelForProvider(provider),
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "pending",
                };
            }

            if (std.ascii.eqlIgnoreCase(action, "wait")) {
                const maybe_timeout = if (rest.len > 2) rest[2] else "";
                const timeout_ms: u32 = blk: {
                    const trimmed = std.mem.trim(u8, maybe_timeout, " \t\r\n");
                    if (trimmed.len == 0) break :blk 30_000;
                    const secs = std.fmt.parseInt(u32, trimmed, 10) catch 30;
                    break :blk secs * 1000;
                };
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
            const provider = if (rest.len > 0 and isKnownProvider(rest[0])) normalizeProvider(rest[0]) else default_provider;
            const maybe_session = if (rest.len > 1) rest[1] else "";
            const key = try authBindingKey(allocator, target, provider);
            defer allocator.free(key);
            const login_session = if (std.mem.trim(u8, maybe_session, " \t\r\n").len > 0) maybe_session else (self.auth_bindings.get(key) orelse "");
            if (std.mem.trim(u8, login_session, " \t\r\n").len == 0) {
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "No pending auth session for `{s}`. Start with `/auth start {s}`.", .{ provider, provider }),
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
            try self.setAuthBinding(target, provider, completed.loginSessionId);
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "Guest auth completed for `{s}`. Session `{s}` is `{s}`.", .{ provider, completed.loginSessionId, completed.status }),
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
                    .reply = try allocator.dupe(u8, "Missing code. Usage: /auth complete <provider> <callback_url_or_code> [session_id]"),
                    .provider = default_provider,
                    .model = default_model,
                    .login_session_id = "",
                    .login_code = "",
                    .auth_status = "pending",
                };
            }

            var provider = default_provider;
            var code_token = rest[0];
            var session_token: []const u8 = "";
            if (isKnownProvider(rest[0]) and rest.len >= 2) {
                provider = normalizeProvider(rest[0]);
                code_token = rest[1];
                if (rest.len > 2) session_token = rest[2];
            } else if (rest.len > 1) {
                session_token = rest[1];
            }

            if (!isKnownProvider(rest[0])) {
                if (inferProviderFromAuthInput(code_token)) |inferred| provider = inferred;
            }

            const key = try authBindingKey(allocator, target, provider);
            defer allocator.free(key);
            const login_session = if (std.mem.trim(u8, session_token, " \t\r\n").len > 0) session_token else (self.auth_bindings.get(key) orelse "");
            if (std.mem.trim(u8, login_session, " \t\r\n").len == 0) {
                return .{
                    .is_command = true,
                    .command_name = "auth",
                    .reply = try std.fmt.allocPrint(allocator, "No pending auth session for `{s}`. Start with `/auth start {s}`.", .{ provider, provider }),
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
            try self.setAuthBinding(target, provider, completed.loginSessionId);
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "Auth completed. Session `{s}` is `{s}`.", .{ completed.loginSessionId, completed.status }),
                .provider = provider,
                .model = completed.model,
                .login_session_id = completed.loginSessionId,
                .login_code = completed.code,
                .auth_status = completed.status,
            };
        }
        if (std.ascii.eqlIgnoreCase(action, "cancel") or std.ascii.eqlIgnoreCase(action, "logout")) {
            const provider = if (rest.len > 0 and isKnownProvider(rest[0])) normalizeProvider(rest[0]) else default_provider;
            const key = try authBindingKey(allocator, target, provider);
            defer allocator.free(key);
            try self.setOrClearAuthBinding(key, "");
            return .{
                .is_command = true,
                .command_name = "auth",
                .reply = try std.fmt.allocPrint(allocator, "Auth binding cleared for `{s}`.", .{provider}),
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
    }

    fn setTargetModel(self: *TelegramRuntime, target: []const u8, provider: []const u8, model: []const u8) !void {
        const key = try self.allocator.dupe(u8, std.mem.trim(u8, target, " \t\r\n"));
        errdefer self.allocator.free(key);
        const value = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ normalizeProvider(provider), if (normalizeModel(model).len > 0) normalizeModel(model) else defaultModelForProvider(provider) });
        errdefer self.allocator.free(value);
        try self.setOrReplaceMapEntry(&self.target_models, key, value);
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

    fn setAuthBinding(self: *TelegramRuntime, target: []const u8, provider: []const u8, login_session_id: []const u8) !void {
        const key = try authBindingKey(self.allocator, target, provider);
        errdefer self.allocator.free(key);
        if (std.mem.trim(u8, login_session_id, " \t\r\n").len == 0) {
            try self.setOrClearAuthBinding(key, "");
            return;
        }
        const value = try self.allocator.dupe(u8, login_session_id);
        errdefer self.allocator.free(value);
        try self.setOrReplaceMapEntry(&self.auth_bindings, key, value);
    }

    fn setOrClearAuthBinding(self: *TelegramRuntime, key: []const u8, value: []const u8) !void {
        if (value.len == 0) {
            if (self.auth_bindings.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value);
            }
            return;
        }
        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);
        try self.setOrReplaceMapEntry(&self.auth_bindings, key_copy, value_copy);
    }

    fn setOrReplaceMapEntry(self: *TelegramRuntime, map: *std.StringHashMap([]u8), key: []u8, value: []u8) !void {
        if (map.fetchRemove(key)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value);
        }
        try map.put(key, value);
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

fn authBindingKey(allocator: std.mem.Allocator, target: []const u8, provider: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}::{s}", .{ std.mem.trim(u8, target, " \t\r\n"), normalizeProvider(provider) });
}

fn normalizeProvider(provider_raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, provider_raw, " \t\r\n");
    if (trimmed.len == 0) return "chatgpt";
    if (std.ascii.eqlIgnoreCase(trimmed, "openai") or std.ascii.eqlIgnoreCase(trimmed, "openai-chatgpt") or std.ascii.eqlIgnoreCase(trimmed, "chatgpt.com") or std.ascii.eqlIgnoreCase(trimmed, "chatgpt-web")) return "chatgpt";
    if (std.ascii.eqlIgnoreCase(trimmed, "openai-codex") or std.ascii.eqlIgnoreCase(trimmed, "codex-cli") or std.ascii.eqlIgnoreCase(trimmed, "openai-codex-cli")) return "codex";
    if (std.ascii.eqlIgnoreCase(trimmed, "anthropic") or std.ascii.eqlIgnoreCase(trimmed, "claude-cli") or std.ascii.eqlIgnoreCase(trimmed, "claude-code") or std.ascii.eqlIgnoreCase(trimmed, "claude-desktop")) return "claude";
    if (std.ascii.eqlIgnoreCase(trimmed, "google") or std.ascii.eqlIgnoreCase(trimmed, "google-gemini") or std.ascii.eqlIgnoreCase(trimmed, "google-gemini-cli") or std.ascii.eqlIgnoreCase(trimmed, "gemini-cli")) return "gemini";
    if (std.ascii.eqlIgnoreCase(trimmed, "qwen-portal") or std.ascii.eqlIgnoreCase(trimmed, "qwen-chat") or std.ascii.eqlIgnoreCase(trimmed, "qwen-cli") or std.ascii.eqlIgnoreCase(trimmed, "qwen35") or std.ascii.eqlIgnoreCase(trimmed, "qwen3.5") or std.ascii.eqlIgnoreCase(trimmed, "qwen-3.5") or std.ascii.eqlIgnoreCase(trimmed, "copaw") or std.ascii.eqlIgnoreCase(trimmed, "qwen-copaw") or std.ascii.eqlIgnoreCase(trimmed, "qwen-agent")) return "qwen";
    if (std.ascii.eqlIgnoreCase(trimmed, "minimax-portal") or std.ascii.eqlIgnoreCase(trimmed, "minimax-cli")) return "minimax";
    if (std.ascii.eqlIgnoreCase(trimmed, "kimi-code") or std.ascii.eqlIgnoreCase(trimmed, "kimi-coding") or std.ascii.eqlIgnoreCase(trimmed, "kimi-for-coding")) return "kimi";
    if (std.ascii.eqlIgnoreCase(trimmed, "zhipu") or std.ascii.eqlIgnoreCase(trimmed, "zhipu-ai") or std.ascii.eqlIgnoreCase(trimmed, "bigmodel") or std.ascii.eqlIgnoreCase(trimmed, "bigmodel-cn") or std.ascii.eqlIgnoreCase(trimmed, "zhipuai-coding") or std.ascii.eqlIgnoreCase(trimmed, "zhipu-coding")) return "zhipuai";
    if (std.ascii.eqlIgnoreCase(trimmed, "z.ai") or std.ascii.eqlIgnoreCase(trimmed, "z-ai") or std.ascii.eqlIgnoreCase(trimmed, "zaiweb") or std.ascii.eqlIgnoreCase(trimmed, "zai-web") or std.ascii.eqlIgnoreCase(trimmed, "glm") or std.ascii.eqlIgnoreCase(trimmed, "glm-5") or std.ascii.eqlIgnoreCase(trimmed, "glm5")) return "zai";
    if (std.ascii.eqlIgnoreCase(trimmed, "inception-labs") or std.ascii.eqlIgnoreCase(trimmed, "inceptionlabs") or std.ascii.eqlIgnoreCase(trimmed, "mercury") or std.ascii.eqlIgnoreCase(trimmed, "mercury2") or std.ascii.eqlIgnoreCase(trimmed, "mercury-2")) return "inception";
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
    try std.testing.expect(std.mem.eql(u8, set_result.provider, "qwen"));
    try std.testing.expect(std.mem.eql(u8, set_result.model, "qwen3-coder"));
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
    try std.testing.expect(std.mem.indexOf(u8, chat_result.reply, "OpenClaw Zig") != null);

    const poll_frame =
        \\{"id":"tg-poll","method":"poll","params":{"channel":"telegram","limit":10}}
    ;
    var poll_result = try runtime.pollFromFrame(allocator, poll_frame);
    defer poll_result.deinit(allocator);
    try std.testing.expect(poll_result.count >= 1);
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
    try std.testing.expect(std.mem.indexOf(u8, chat_result.reply, "OpenClaw Zig (qwen/") != null);
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
    try std.testing.expect(std.mem.eql(u8, defaultModelForProvider("zhipu-ai"), "glm-4.6"));
    try std.testing.expect(isKnownProvider("zhipuai-coding"));
}
