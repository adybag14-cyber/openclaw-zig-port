const std = @import("std");
const time_util = @import("../util/time.zig");

pub const LoginStatus = enum {
    pending,
    authorized,
    expired,
    rejected,
};

pub const SessionView = struct {
    loginSessionId: []const u8,
    status: []const u8,
    provider: []const u8,
    model: []const u8,
    code: []const u8,
    verificationUri: []const u8,
    verificationUriComplete: []const u8,
    authMode: []const u8,
    guestBypassSupported: bool,
    popupBypassAction: []const u8,
    guestBypassHint: []const u8,
    createdAtMs: i64,
    expiresAtMs: i64,
    authorizedAtMs: ?i64 = null,
};

pub const SummaryView = struct {
    total: usize,
    pending: usize,
    authorized: usize,
    expired: usize,
    rejected: usize,
};

pub const ManagerError = error{
    SessionNotFound,
    SessionExpired,
    InvalidCode,
};

pub const ProviderProfile = struct {
    id: []const u8,
    verification_uri: []const u8,
    default_model: []const u8,
    auth_mode: []const u8,
    guest_bypass_supported: bool,
    popup_bypass_action: []const u8,
    guest_bypass_hint: []const u8,
};

const Session = struct {
    id: []u8,
    status: LoginStatus,
    provider: []u8,
    model: []u8,
    code: []u8,
    verification_uri: []u8,
    verification_uri_complete: []u8,
    auth_mode: []u8,
    guest_bypass_supported: bool,
    popup_bypass_action: []u8,
    guest_bypass_hint: []u8,
    created_at_ms: i64,
    expires_at_ms: i64,
    authorized_at_ms: ?i64,

    fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.provider);
        allocator.free(self.model);
        allocator.free(self.code);
        allocator.free(self.verification_uri);
        allocator.free(self.verification_uri_complete);
        allocator.free(self.auth_mode);
        allocator.free(self.popup_bypass_action);
        allocator.free(self.guest_bypass_hint);
    }

    fn view(self: *const Session) SessionView {
        return .{
            .loginSessionId = self.id,
            .status = statusText(self.status),
            .provider = self.provider,
            .model = self.model,
            .code = self.code,
            .verificationUri = self.verification_uri,
            .verificationUriComplete = self.verification_uri_complete,
            .authMode = self.auth_mode,
            .guestBypassSupported = self.guest_bypass_supported,
            .popupBypassAction = self.popup_bypass_action,
            .guestBypassHint = self.guest_bypass_hint,
            .createdAtMs = self.created_at_ms,
            .expiresAtMs = self.expires_at_ms,
            .authorizedAtMs = self.authorized_at_ms,
        };
    }
};

const PersistedSession = struct {
    id: []const u8,
    status: []const u8,
    provider: []const u8,
    model: []const u8,
    code: []const u8,
    verificationUri: []const u8,
    verificationUriComplete: []const u8,
    authMode: []const u8,
    guestBypassSupported: bool,
    popupBypassAction: []const u8,
    guestBypassHint: []const u8,
    createdAtMs: i64,
    expiresAtMs: i64,
    authorizedAtMs: ?i64 = null,
};

const PersistedState = struct {
    nextSequence: u64 = 0,
    ttlMs: i64 = 10 * 60 * 1000,
    sessions: []PersistedSession = &.{},
};

pub const LoginManager = struct {
    allocator: std.mem.Allocator,
    ttl_ms: i64,
    next_sequence: u64,
    sessions: std.ArrayList(Session),
    state_path: ?[]u8,
    persistent: bool,

    pub fn init(allocator: std.mem.Allocator, ttl_ms: i64) LoginManager {
        return .{
            .allocator = allocator,
            .ttl_ms = if (ttl_ms <= 0) 10 * 60 * 1000 else ttl_ms,
            .next_sequence = 0,
            .sessions = .empty,
            .state_path = null,
            .persistent = false,
        };
    }

    pub fn deinit(self: *LoginManager) void {
        self.clearSessions();
        self.sessions.deinit(self.allocator);
        if (self.state_path) |path| self.allocator.free(path);
        self.state_path = null;
        self.persistent = false;
    }

    pub fn configurePersistence(self: *LoginManager, state_root: []const u8) !void {
        const resolved = try resolveStatePath(self.allocator, state_root);
        if (self.state_path) |path| self.allocator.free(path);
        self.state_path = resolved;
        self.persistent = shouldPersist(resolved);
        if (!self.persistent) return;

        // configurePersistence is expected during bootstrap before active sessions.
        if (self.sessions.items.len == 0 and self.next_sequence == 0) {
            try self.load();
        }
    }

    pub fn start(self: *LoginManager, provider_raw: []const u8, model_raw: []const u8) !SessionView {
        self.next_sequence += 1;
        const now = nowMs();
        const profile = providerProfile(provider_raw);
        const provider = profile.id;
        const model_trimmed = std.mem.trim(u8, model_raw, " \t\r\n");
        const model = if (model_trimmed.len == 0) profile.default_model else model_trimmed;
        const code_value: u64 = 100_000 + (self.next_sequence % 900_000);

        const id = try std.fmt.allocPrint(self.allocator, "web-login-{d}", .{self.next_sequence});
        errdefer self.allocator.free(id);
        const code = try std.fmt.allocPrint(self.allocator, "OC-{d}", .{code_value});
        errdefer self.allocator.free(code);
        const verification_uri = try self.allocator.dupe(u8, profile.verification_uri);
        errdefer self.allocator.free(verification_uri);
        const verification_complete = try std.fmt.allocPrint(self.allocator, "{s}?openclaw_code={s}", .{
            verification_uri,
            code,
        });
        errdefer self.allocator.free(verification_complete);

        try self.sessions.append(self.allocator, .{
            .id = id,
            .status = .pending,
            .provider = try self.allocator.dupe(u8, provider),
            .model = try self.allocator.dupe(u8, model),
            .code = code,
            .verification_uri = verification_uri,
            .verification_uri_complete = verification_complete,
            .auth_mode = try self.allocator.dupe(u8, profile.auth_mode),
            .guest_bypass_supported = profile.guest_bypass_supported,
            .popup_bypass_action = try self.allocator.dupe(u8, profile.popup_bypass_action),
            .guest_bypass_hint = try self.allocator.dupe(u8, profile.guest_bypass_hint),
            .created_at_ms = now,
            .expires_at_ms = now + self.ttl_ms,
            .authorized_at_ms = null,
        });
        if (self.persistent) try self.persist();

        return self.sessions.items[self.sessions.items.len - 1].view();
    }

    pub fn get(self: *LoginManager, session_id: []const u8) ?SessionView {
        const index = self.findIndex(session_id) orelse return null;
        self.applyExpiry(&self.sessions.items[index]);
        return self.sessions.items[index].view();
    }

    pub fn wait(self: *LoginManager, session_id: []const u8, timeout_ms: u32) ManagerError!SessionView {
        const index = self.findIndex(session_id) orelse return error.SessionNotFound;
        _ = timeout_ms;
        self.applyExpiry(&self.sessions.items[index]);
        return self.sessions.items[index].view();
    }

    pub fn complete(self: *LoginManager, session_id: []const u8, code_raw: []const u8) ManagerError!SessionView {
        const index = self.findIndex(session_id) orelse return error.SessionNotFound;
        var session = &self.sessions.items[index];
        self.applyExpiry(session);
        if (session.status == .expired) return error.SessionExpired;

        const provided = extractAuthCode(code_raw);
        if (provided.len == 0 and !session.guest_bypass_supported) return error.InvalidCode;
        if (provided.len > 0 and !std.ascii.eqlIgnoreCase(provided, session.code)) return error.InvalidCode;

        session.status = .authorized;
        session.authorized_at_ms = nowMs();
        if (self.persistent) self.persist() catch {};
        return session.view();
    }

    pub fn status(self: *LoginManager) SummaryView {
        var summary: SummaryView = .{
            .total = self.sessions.items.len,
            .pending = 0,
            .authorized = 0,
            .expired = 0,
            .rejected = 0,
        };
        for (self.sessions.items) |*session| {
            self.applyExpiry(session);
            switch (session.status) {
                .pending => summary.pending += 1,
                .authorized => summary.authorized += 1,
                .expired => summary.expired += 1,
                .rejected => summary.rejected += 1,
            }
        }
        return summary;
    }

    fn applyExpiry(self: *LoginManager, session: *Session) void {
        _ = self;
        if (session.status != .pending) return;
        if (nowMs() > session.expires_at_ms) session.status = .expired;
    }

    fn findIndex(self: *const LoginManager, session_id: []const u8) ?usize {
        const trimmed = std.mem.trim(u8, session_id, " \t\r\n");
        if (trimmed.len == 0) return null;
        for (self.sessions.items, 0..) |session, idx| {
            if (std.mem.eql(u8, session.id, trimmed)) return idx;
        }
        return null;
    }

    fn clearSessions(self: *LoginManager) void {
        for (self.sessions.items) |*session| session.deinit(self.allocator);
        self.sessions.clearRetainingCapacity();
    }

    fn load(self: *LoginManager) !void {
        const path = self.state_path orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();
        const raw = std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(2 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer self.allocator.free(raw);

        var parsed = try std.json.parseFromSlice(PersistedState, self.allocator, raw, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        self.clearSessions();
        self.ttl_ms = if (parsed.value.ttlMs <= 0) self.ttl_ms else parsed.value.ttlMs;
        self.next_sequence = parsed.value.nextSequence;

        var max_seq: u64 = 0;
        for (parsed.value.sessions) |entry| {
            const restored_status = parseStatus(entry.status);
            try self.sessions.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, entry.id),
                .status = restored_status,
                .provider = try self.allocator.dupe(u8, entry.provider),
                .model = try self.allocator.dupe(u8, entry.model),
                .code = try self.allocator.dupe(u8, entry.code),
                .verification_uri = try self.allocator.dupe(u8, entry.verificationUri),
                .verification_uri_complete = try self.allocator.dupe(u8, entry.verificationUriComplete),
                .auth_mode = try self.allocator.dupe(u8, entry.authMode),
                .guest_bypass_supported = entry.guestBypassSupported,
                .popup_bypass_action = try self.allocator.dupe(u8, entry.popupBypassAction),
                .guest_bypass_hint = try self.allocator.dupe(u8, entry.guestBypassHint),
                .created_at_ms = entry.createdAtMs,
                .expires_at_ms = entry.expiresAtMs,
                .authorized_at_ms = entry.authorizedAtMs,
            });
            if (sequenceFromSessionId(entry.id)) |seq| {
                if (seq > max_seq) max_seq = seq;
            }
        }
        if (self.next_sequence < max_seq) self.next_sequence = max_seq;
    }

    fn persist(self: *LoginManager) !void {
        if (!self.persistent) return;
        const path = self.state_path orelse return;
        const io = std.Io.Threaded.global_single_threaded.io();

        if (std.fs.path.dirname(path)) |parent| {
            if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        var out_sessions = try self.allocator.alloc(PersistedSession, self.sessions.items.len);
        defer self.allocator.free(out_sessions);
        for (self.sessions.items, 0..) |entry, idx| {
            out_sessions[idx] = .{
                .id = entry.id,
                .status = statusText(entry.status),
                .provider = entry.provider,
                .model = entry.model,
                .code = entry.code,
                .verificationUri = entry.verification_uri,
                .verificationUriComplete = entry.verification_uri_complete,
                .authMode = entry.auth_mode,
                .guestBypassSupported = entry.guest_bypass_supported,
                .popupBypassAction = entry.popup_bypass_action,
                .guestBypassHint = entry.guest_bypass_hint,
                .createdAtMs = entry.created_at_ms,
                .expiresAtMs = entry.expires_at_ms,
                .authorizedAtMs = entry.authorized_at_ms,
            };
        }

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(.{
            .nextSequence = self.next_sequence,
            .ttlMs = self.ttl_ms,
            .sessions = out_sessions,
        }, .{}, &out.writer);
        const payload = try out.toOwnedSlice();
        defer self.allocator.free(payload);

        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = path,
            .data = payload,
        });
    }
};

fn statusText(status: LoginStatus) []const u8 {
    return switch (status) {
        .pending => "pending",
        .authorized => "authorized",
        .expired => "expired",
        .rejected => "rejected",
    };
}

fn parseStatus(raw: []const u8) LoginStatus {
    if (std.ascii.eqlIgnoreCase(raw, "authorized")) return .authorized;
    if (std.ascii.eqlIgnoreCase(raw, "expired")) return .expired;
    if (std.ascii.eqlIgnoreCase(raw, "rejected")) return .rejected;
    return .pending;
}

fn resolveStatePath(allocator: std.mem.Allocator, state_root: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, state_root, " \t\r\n");
    if (trimmed.len == 0) return allocator.dupe(u8, "memory://web-login-state");
    if (isMemoryScheme(trimmed)) return allocator.dupe(u8, trimmed);
    if (std.mem.endsWith(u8, trimmed, ".json")) return allocator.dupe(u8, trimmed);
    return std.fs.path.join(allocator, &.{ trimmed, "web-login-state.json" });
}

fn shouldPersist(path: []const u8) bool {
    return !isMemoryScheme(path);
}

fn isMemoryScheme(path: []const u8) bool {
    const prefix = "memory://";
    if (path.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix);
}

fn sequenceFromSessionId(session_id: []const u8) ?u64 {
    const prefix = "web-login-";
    if (!std.ascii.startsWithIgnoreCase(session_id, prefix)) return null;
    const suffix = std.mem.trim(u8, session_id[prefix.len..], " \t\r\n");
    if (suffix.len == 0) return null;
    return std.fmt.parseInt(u64, suffix, 10) catch null;
}

pub fn providerProfile(provider_raw: []const u8) ProviderProfile {
    const provider = normalizeProviderAlias(provider_raw);
    if (std.ascii.eqlIgnoreCase(provider, "claude")) {
        return .{
            .id = "claude",
            .verification_uri = "https://claude.ai/",
            .default_model = "claude-opus-4",
            .auth_mode = "device_code",
            .guest_bypass_supported = false,
            .popup_bypass_action = "not_applicable",
            .guest_bypass_hint = "",
        };
    }
    if (std.ascii.eqlIgnoreCase(provider, "gemini")) {
        return .{
            .id = "gemini",
            .verification_uri = "https://aistudio.google.com/",
            .default_model = "gemini-2.5-pro",
            .auth_mode = "device_code",
            .guest_bypass_supported = false,
            .popup_bypass_action = "not_applicable",
            .guest_bypass_hint = "",
        };
    }
    if (std.ascii.eqlIgnoreCase(provider, "openrouter")) {
        return .{
            .id = "openrouter",
            .verification_uri = "https://openrouter.ai/",
            .default_model = "openrouter/auto",
            .auth_mode = "api_key_or_oauth",
            .guest_bypass_supported = false,
            .popup_bypass_action = "not_applicable",
            .guest_bypass_hint = "",
        };
    }
    if (std.ascii.eqlIgnoreCase(provider, "opencode")) {
        return .{
            .id = "opencode",
            .verification_uri = "https://opencode.ai/",
            .default_model = "opencode/default",
            .auth_mode = "api_key_or_oauth",
            .guest_bypass_supported = false,
            .popup_bypass_action = "not_applicable",
            .guest_bypass_hint = "",
        };
    }
    if (std.ascii.eqlIgnoreCase(provider, "qwen")) {
        return .{
            .id = "qwen",
            .verification_uri = "https://chat.qwen.ai/",
            .default_model = "qwen-max",
            .auth_mode = "guest_or_code",
            .guest_bypass_supported = true,
            .popup_bypass_action = "stay_logged_out",
            .guest_bypass_hint = "If Qwen shows a sign-in popup, choose 'Stay logged out' and continue as guest.",
        };
    }
    if (std.ascii.eqlIgnoreCase(provider, "zai")) {
        return .{
            .id = "zai",
            .verification_uri = "https://chat.z.ai/",
            .default_model = "glm-5",
            .auth_mode = "guest_or_code",
            .guest_bypass_supported = true,
            .popup_bypass_action = "stay_logged_out",
            .guest_bypass_hint = "On chat.z.ai choose 'Stay logged out' to continue with guest GLM access.",
        };
    }
    if (std.ascii.eqlIgnoreCase(provider, "inception")) {
        return .{
            .id = "inception",
            .verification_uri = "https://chat.inceptionlabs.ai/",
            .default_model = "mercury-2",
            .auth_mode = "guest_or_code",
            .guest_bypass_supported = true,
            .popup_bypass_action = "stay_logged_out",
            .guest_bypass_hint = "For Mercury 2, keep guest mode by pressing 'Stay logged out' on popup prompts.",
        };
    }
    if (std.ascii.eqlIgnoreCase(provider, "minimax")) {
        return .{
            .id = "minimax",
            .verification_uri = "https://chat.minimax.io/",
            .default_model = "minimax-m2.5",
            .auth_mode = "device_code",
            .guest_bypass_supported = false,
            .popup_bypass_action = "not_applicable",
            .guest_bypass_hint = "",
        };
    }
    if (std.ascii.eqlIgnoreCase(provider, "kimi")) {
        return .{
            .id = "kimi",
            .verification_uri = "https://kimi.com/",
            .default_model = "kimi-k2.5",
            .auth_mode = "device_code",
            .guest_bypass_supported = false,
            .popup_bypass_action = "not_applicable",
            .guest_bypass_hint = "",
        };
    }
    if (std.ascii.eqlIgnoreCase(provider, "zhipuai")) {
        return .{
            .id = "zhipuai",
            .verification_uri = "https://open.bigmodel.cn/",
            .default_model = "glm-4.6",
            .auth_mode = "device_code",
            .guest_bypass_supported = false,
            .popup_bypass_action = "not_applicable",
            .guest_bypass_hint = "",
        };
    }
    if (std.ascii.eqlIgnoreCase(provider, "codex")) {
        return .{
            .id = "codex",
            .verification_uri = "https://chatgpt.com/",
            .default_model = "gpt-5.2",
            .auth_mode = "device_code",
            .guest_bypass_supported = false,
            .popup_bypass_action = "not_applicable",
            .guest_bypass_hint = "",
        };
    }
    return .{
        .id = "chatgpt",
        .verification_uri = "https://chatgpt.com/",
        .default_model = "gpt-5.2",
        .auth_mode = "device_code",
        .guest_bypass_supported = false,
        .popup_bypass_action = "not_applicable",
        .guest_bypass_hint = "",
    };
}

pub fn providerVerificationURI(provider: []const u8) []const u8 {
    return providerProfile(provider).verification_uri;
}

pub fn defaultModelForProvider(provider: []const u8) []const u8 {
    return providerProfile(provider).default_model;
}

pub fn supportsGuestBypass(provider: []const u8) bool {
    return providerProfile(provider).guest_bypass_supported;
}

pub fn guestBypassAction(provider: []const u8) []const u8 {
    return providerProfile(provider).popup_bypass_action;
}

pub fn guestBypassHint(provider: []const u8) []const u8 {
    return providerProfile(provider).guest_bypass_hint;
}

pub fn normalizeProviderAlias(provider: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, provider, " \t\r\n");
    if (trimmed.len == 0) return "chatgpt";
    if (std.ascii.eqlIgnoreCase(trimmed, "openai") or std.ascii.eqlIgnoreCase(trimmed, "openai-chatgpt") or std.ascii.eqlIgnoreCase(trimmed, "chatgpt.com") or std.ascii.eqlIgnoreCase(trimmed, "chatgpt-web")) return "chatgpt";
    if (std.ascii.eqlIgnoreCase(trimmed, "codex") or std.ascii.eqlIgnoreCase(trimmed, "openai-codex") or std.ascii.eqlIgnoreCase(trimmed, "codex-cli")) return "codex";
    if (std.ascii.eqlIgnoreCase(trimmed, "anthropic") or std.ascii.eqlIgnoreCase(trimmed, "claude-cli") or std.ascii.eqlIgnoreCase(trimmed, "claude-code") or std.ascii.eqlIgnoreCase(trimmed, "claude-desktop")) return "claude";
    if (std.ascii.eqlIgnoreCase(trimmed, "google") or std.ascii.eqlIgnoreCase(trimmed, "google-gemini") or std.ascii.eqlIgnoreCase(trimmed, "google-gemini-cli") or std.ascii.eqlIgnoreCase(trimmed, "gemini-cli")) return "gemini";
    if (std.ascii.eqlIgnoreCase(trimmed, "qwen-portal") or std.ascii.eqlIgnoreCase(trimmed, "qwen-cli") or std.ascii.eqlIgnoreCase(trimmed, "qwen-chat") or std.ascii.eqlIgnoreCase(trimmed, "qwen35") or std.ascii.eqlIgnoreCase(trimmed, "qwen3.5") or std.ascii.eqlIgnoreCase(trimmed, "qwen-3.5") or std.ascii.eqlIgnoreCase(trimmed, "copaw") or std.ascii.eqlIgnoreCase(trimmed, "qwen-copaw") or std.ascii.eqlIgnoreCase(trimmed, "qwen-agent") or std.ascii.eqlIgnoreCase(trimmed, "qwen-free") or std.ascii.eqlIgnoreCase(trimmed, "qwen-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "qwen-free-chat")) return "qwen";
    if (std.ascii.eqlIgnoreCase(trimmed, "minimax-portal") or std.ascii.eqlIgnoreCase(trimmed, "minimax-cli")) return "minimax";
    if (std.ascii.eqlIgnoreCase(trimmed, "kimi-code") or std.ascii.eqlIgnoreCase(trimmed, "kimi-coding") or std.ascii.eqlIgnoreCase(trimmed, "kimi-for-coding")) return "kimi";
    if (std.ascii.eqlIgnoreCase(trimmed, "opencode-zen") or std.ascii.eqlIgnoreCase(trimmed, "opencode-ai") or std.ascii.eqlIgnoreCase(trimmed, "opencode-go") or std.ascii.eqlIgnoreCase(trimmed, "opencode_free") or std.ascii.eqlIgnoreCase(trimmed, "opencodefree")) return "opencode";
    if (std.ascii.eqlIgnoreCase(trimmed, "zhipu") or std.ascii.eqlIgnoreCase(trimmed, "zhipu-ai") or std.ascii.eqlIgnoreCase(trimmed, "bigmodel") or std.ascii.eqlIgnoreCase(trimmed, "bigmodel-cn") or std.ascii.eqlIgnoreCase(trimmed, "zhipuai-coding") or std.ascii.eqlIgnoreCase(trimmed, "zhipu-coding")) return "zhipuai";
    if (std.ascii.eqlIgnoreCase(trimmed, "z.ai") or std.ascii.eqlIgnoreCase(trimmed, "z-ai") or std.ascii.eqlIgnoreCase(trimmed, "zaiweb") or std.ascii.eqlIgnoreCase(trimmed, "zai-web") or std.ascii.eqlIgnoreCase(trimmed, "glm") or std.ascii.eqlIgnoreCase(trimmed, "glm5") or std.ascii.eqlIgnoreCase(trimmed, "glm-5") or std.ascii.eqlIgnoreCase(trimmed, "zai-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "glm-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "glm5-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "glm-5-chat-free")) return "zai";
    if (std.ascii.eqlIgnoreCase(trimmed, "inception-labs") or std.ascii.eqlIgnoreCase(trimmed, "inceptionlabs") or std.ascii.eqlIgnoreCase(trimmed, "mercury") or std.ascii.eqlIgnoreCase(trimmed, "mercury2") or std.ascii.eqlIgnoreCase(trimmed, "mercury-2") or std.ascii.eqlIgnoreCase(trimmed, "inception-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "mercury-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "mercury2-chat-free") or std.ascii.eqlIgnoreCase(trimmed, "mercury-2-chat-free")) return "inception";
    return trimmed;
}

pub fn extractAuthCode(input_raw: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input_raw, " \t\r\n");
    if (trimmed.len == 0) return "";
    if (isGuestBypassToken(trimmed)) return "";

    for ([_][]const u8{ "openclaw_code=", "code=", "device_code=", "auth_code=", "token=", "oauth_token=" }) |needle| {
        if (extractTaggedCode(trimmed, needle)) |value| return value;
    }

    if (std.mem.indexOfScalar(u8, trimmed, '#')) |hash_idx| {
        const fragment = std.mem.trim(u8, trimmed[hash_idx + 1 ..], " \t\r\n");
        if (fragment.len > 0) {
            for ([_][]const u8{ "openclaw_code=", "code=", "device_code=", "auth_code=", "token=", "oauth_token=" }) |needle| {
                if (extractTaggedCode(fragment, needle)) |value| return value;
            }
            const fragment_candidate = std.mem.trim(u8, fragment, "/");
            if (looksLikeAuthCode(fragment_candidate)) return fragment_candidate;
            if (std.mem.lastIndexOfScalar(u8, fragment_candidate, '/')) |last| {
                const tail = std.mem.trim(u8, fragment_candidate[last + 1 ..], " \t\r\n");
                if (looksLikeAuthCode(tail)) return tail;
            }
        }
    }

    if (std.mem.indexOf(u8, trimmed, "://")) |scheme_idx| {
        const after_scheme = trimmed[scheme_idx + 3 ..];
        if (std.mem.indexOfScalar(u8, after_scheme, '/')) |path_idx| {
            const path_and_more = after_scheme[path_idx + 1 ..];
            var path_end = path_and_more.len;
            if (std.mem.indexOfAny(u8, path_and_more, "?#")) |idx| path_end = idx;
            const path = std.mem.trim(u8, path_and_more[0..path_end], "/");
            if (path.len > 0) {
                if (std.mem.lastIndexOfScalar(u8, path, '/')) |last| {
                    const candidate = std.mem.trim(u8, path[last + 1 ..], " \t\r\n");
                    if (looksLikeAuthCode(candidate)) return candidate;
                } else if (looksLikeAuthCode(path)) {
                    return path;
                }
            }
        }
    }

    return trimmed;
}

fn extractTaggedCode(haystack: []const u8, needle: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, haystack, needle)) |idx| {
        const start = idx + needle.len;
        var end = start;
        while (end < haystack.len and haystack[end] != '&' and haystack[end] != '#' and haystack[end] != '/' and haystack[end] != '?' and haystack[end] != '"' and haystack[end] != '\'') : (end += 1) {}
        if (end > start) return haystack[start..end];
    }
    return null;
}

fn looksLikeAuthCode(candidate_raw: []const u8) bool {
    const candidate = std.mem.trim(u8, candidate_raw, " \t\r\n");
    if (candidate.len < 4 or candidate.len > 256) return false;
    if (std.ascii.eqlIgnoreCase(candidate, "callback") or
        std.ascii.eqlIgnoreCase(candidate, "oauth") or
        std.ascii.eqlIgnoreCase(candidate, "auth") or
        std.ascii.eqlIgnoreCase(candidate, "complete"))
    {
        return false;
    }
    if (std.mem.indexOfAny(u8, candidate, " \t\r\n") != null) return false;
    return true;
}

fn isGuestBypassToken(token_raw: []const u8) bool {
    const token = std.mem.trim(u8, token_raw, " \t\r\n");
    if (token.len == 0) return false;
    return std.ascii.eqlIgnoreCase(token, "guest") or
        std.ascii.eqlIgnoreCase(token, "guest_mode") or
        std.ascii.eqlIgnoreCase(token, "guest-bypass") or
        std.ascii.eqlIgnoreCase(token, "stay_logged_out") or
        std.ascii.eqlIgnoreCase(token, "stay-logged-out") or
        std.ascii.eqlIgnoreCase(token, "stayloggedout") or
        std.ascii.eqlIgnoreCase(token, "continue_as_guest") or
        std.ascii.eqlIgnoreCase(token, "continue-as-guest") or
        std.ascii.eqlIgnoreCase(token, "logged_out");
}

fn nowMs() i64 {
    return time_util.nowMs();
}

test "web login start wait complete lifecycle" {
    var manager = LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer manager.deinit();

    const start_session = try manager.start("chatgpt", "gpt-5.2");
    try std.testing.expect(std.mem.eql(u8, start_session.status, "pending"));
    try std.testing.expect(std.mem.eql(u8, start_session.authMode, "device_code"));

    const wait_pending = try manager.wait(start_session.loginSessionId, 10);
    try std.testing.expect(std.mem.eql(u8, wait_pending.status, "pending"));

    const complete = try manager.complete(start_session.loginSessionId, start_session.code);
    try std.testing.expect(std.mem.eql(u8, complete.status, "authorized"));
}

test "web login complete rejects wrong code" {
    var manager = LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer manager.deinit();

    const start_session = try manager.start("chatgpt", "gpt-5.2");
    try std.testing.expectError(error.InvalidCode, manager.complete(start_session.loginSessionId, "WRONG-CODE"));
}

test "guest providers can complete auth with guest token" {
    var manager = LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer manager.deinit();

    const qwen = try manager.start("copaw", "");
    try std.testing.expect(std.mem.eql(u8, qwen.provider, "qwen"));
    try std.testing.expect(qwen.guestBypassSupported);
    try std.testing.expect(std.mem.eql(u8, qwen.popupBypassAction, "stay_logged_out"));
    const completed = try manager.complete(qwen.loginSessionId, "guest");
    try std.testing.expect(std.mem.eql(u8, completed.status, "authorized"));
}

test "normalize provider alias accepts free guest chat variants" {
    try std.testing.expect(std.mem.eql(u8, normalizeProviderAlias("qwen-chat-free"), "qwen"));
    try std.testing.expect(std.mem.eql(u8, normalizeProviderAlias("glm-5-chat-free"), "zai"));
    try std.testing.expect(std.mem.eql(u8, normalizeProviderAlias("mercury-2-chat-free"), "inception"));
}

test "non guest providers reject empty or guest completion token" {
    var manager = LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer manager.deinit();

    const chatgpt = try manager.start("chatgpt", "");
    try std.testing.expectError(error.InvalidCode, manager.complete(chatgpt.loginSessionId, ""));
    try std.testing.expectError(error.InvalidCode, manager.complete(chatgpt.loginSessionId, "guest"));
}

test "extract auth code supports callback urls and fragments" {
    try std.testing.expect(std.mem.eql(u8, extractAuthCode("https://chat.qwen.ai/callback?code=OC-QWEN999"), "OC-QWEN999"));
    try std.testing.expect(std.mem.eql(u8, extractAuthCode("https://chat.z.ai/oauth#auth_code=OC-GLM5"), "OC-GLM5"));
    try std.testing.expect(std.mem.eql(u8, extractAuthCode("https://chat.inceptionlabs.ai/auth/OC-MERCURY2"), "OC-MERCURY2"));
    try std.testing.expect(std.mem.eql(u8, extractAuthCode("guest"), ""));
}

test "web login persistence roundtrip restores authorized session" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var session_id: []u8 = undefined;
    {
        var manager = LoginManager.init(allocator, 5 * 60 * 1000);
        defer manager.deinit();
        try manager.configurePersistence(root);
        const started = try manager.start("qwen", "qwen-max");
        _ = try manager.complete(started.loginSessionId, "guest");
        session_id = try allocator.dupe(u8, started.loginSessionId);
    }
    defer allocator.free(session_id);

    {
        var restored = LoginManager.init(allocator, 5 * 60 * 1000);
        defer restored.deinit();
        try restored.configurePersistence(root);
        const view = restored.get(session_id) orelse return error.SessionNotFound;
        try std.testing.expect(std.ascii.eqlIgnoreCase(view.status, "authorized"));
        try std.testing.expect(std.ascii.eqlIgnoreCase(view.provider, "qwen"));
    }
}
