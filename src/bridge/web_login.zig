const std = @import("std");

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

const Session = struct {
    id: []u8,
    status: LoginStatus,
    provider: []u8,
    model: []u8,
    code: []u8,
    verification_uri: []u8,
    verification_uri_complete: []u8,
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
            .createdAtMs = self.created_at_ms,
            .expiresAtMs = self.expires_at_ms,
            .authorizedAtMs = self.authorized_at_ms,
        };
    }
};

pub const LoginManager = struct {
    allocator: std.mem.Allocator,
    ttl_ms: i64,
    next_sequence: u64,
    sessions: std.ArrayList(Session),

    pub fn init(allocator: std.mem.Allocator, ttl_ms: i64) LoginManager {
        return .{
            .allocator = allocator,
            .ttl_ms = if (ttl_ms <= 0) 10 * 60 * 1000 else ttl_ms,
            .next_sequence = 0,
            .sessions = .empty,
        };
    }

    pub fn deinit(self: *LoginManager) void {
        for (self.sessions.items) |*session| session.deinit(self.allocator);
        self.sessions.deinit(self.allocator);
    }

    pub fn start(self: *LoginManager, provider_raw: []const u8, model_raw: []const u8) !SessionView {
        self.next_sequence += 1;
        const now = nowMs();
        const provider_norm = normalizeProviderAlias(provider_raw);
        const provider = if (provider_norm.len == 0) "chatgpt" else provider_norm;
        const model = if (std.mem.trim(u8, model_raw, " \t\r\n").len == 0) "gpt-5.2" else std.mem.trim(u8, model_raw, " \t\r\n");
        const code_value: u64 = 100_000 + (self.next_sequence % 900_000);

        const id = try std.fmt.allocPrint(self.allocator, "web-login-{d}", .{self.next_sequence});
        errdefer self.allocator.free(id);
        const code = try std.fmt.allocPrint(self.allocator, "OC-{d}", .{code_value});
        errdefer self.allocator.free(code);
        const verification_uri = try self.allocator.dupe(u8, providerVerificationURI(provider));
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
            .created_at_ms = now,
            .expires_at_ms = now + self.ttl_ms,
            .authorized_at_ms = null,
        });

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

        const provided = std.mem.trim(u8, code_raw, " \t\r\n");
        if (provided.len > 0 and !std.ascii.eqlIgnoreCase(provided, session.code)) {
            return error.InvalidCode;
        }

        session.status = .authorized;
        session.authorized_at_ms = nowMs();
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
};

fn statusText(status: LoginStatus) []const u8 {
    return switch (status) {
        .pending => "pending",
        .authorized => "authorized",
        .expired => "expired",
        .rejected => "rejected",
    };
}

fn providerVerificationURI(provider: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(provider, "claude")) return "https://claude.ai/";
    if (std.ascii.eqlIgnoreCase(provider, "gemini")) return "https://aistudio.google.com/";
    if (std.ascii.eqlIgnoreCase(provider, "openrouter")) return "https://openrouter.ai/";
    if (std.ascii.eqlIgnoreCase(provider, "opencode")) return "https://opencode.ai/";
    if (std.ascii.eqlIgnoreCase(provider, "qwen")) return "https://chat.qwen.ai/";
    if (std.ascii.eqlIgnoreCase(provider, "zai")) return "https://chat.z.ai/";
    if (std.ascii.eqlIgnoreCase(provider, "inception")) return "https://chat.inceptionlabs.ai/";
    return "https://chatgpt.com/";
}

fn normalizeProviderAlias(provider: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, provider, " \t\r\n");
    if (trimmed.len == 0) return "";
    if (std.ascii.eqlIgnoreCase(trimmed, "openai") or std.ascii.eqlIgnoreCase(trimmed, "chatgpt.com") or std.ascii.eqlIgnoreCase(trimmed, "chatgpt-web")) return "chatgpt";
    if (std.ascii.eqlIgnoreCase(trimmed, "codex") or std.ascii.eqlIgnoreCase(trimmed, "openai-codex") or std.ascii.eqlIgnoreCase(trimmed, "codex-cli")) return "codex";
    if (std.ascii.eqlIgnoreCase(trimmed, "anthropic")) return "claude";
    if (std.ascii.eqlIgnoreCase(trimmed, "google")) return "gemini";
    if (std.ascii.eqlIgnoreCase(trimmed, "qwen-cli") or std.ascii.eqlIgnoreCase(trimmed, "copaw") or std.ascii.eqlIgnoreCase(trimmed, "qwen-chat")) return "qwen";
    if (std.ascii.eqlIgnoreCase(trimmed, "glm-5") or std.ascii.eqlIgnoreCase(trimmed, "glm5") or std.ascii.eqlIgnoreCase(trimmed, "z-ai") or std.ascii.eqlIgnoreCase(trimmed, "z.ai")) return "zai";
    if (std.ascii.eqlIgnoreCase(trimmed, "mercury2") or std.ascii.eqlIgnoreCase(trimmed, "mercury-2")) return "inception";
    return trimmed;
}

fn nowMs() i64 {
    return std.Io.Clock.real.now(std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

test "web login start wait complete lifecycle" {
    var manager = LoginManager.init(std.testing.allocator, 5 * 60 * 1000);
    defer manager.deinit();

    const start_session = try manager.start("chatgpt", "gpt-5.2");
    try std.testing.expect(std.mem.eql(u8, start_session.status, "pending"));

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
