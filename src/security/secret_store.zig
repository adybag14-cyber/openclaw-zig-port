const std = @import("std");
const pal = @import("../pal/mod.zig");
const time_util = @import("../util/time.zig");

const Cipher = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const aad = "openclaw-zig-secret-store-v1";

pub const SecretKeyRef = struct {
    targetId: []const u8,
};

pub const Status = struct {
    requestedBackend: []const u8,
    activeBackend: []const u8,
    providerImplemented: bool,
    encryptedFallback: bool,
    requestedRecognized: bool,
    requestedSupport: []const u8,
    fallbackApplied: bool,
    fallbackReason: ?[]const u8,
    persistent: bool,
    path: []const u8,
    keySource: []const u8,
    loadedAtMs: i64,
    savedAtMs: i64,
    count: usize,
};

pub const InitOptions = struct {
    requested_backend: ?[]const u8 = null,
    store_path_override: ?[]const u8 = null,
    key_override: ?[]const u8 = null,
};

const PersistedEntry = struct {
    key: []const u8,
    value: []const u8,
};

const PersistedPlain = struct {
    version: u8 = 1,
    entries: []PersistedEntry = &.{},
};

const PersistedEnvelope = struct {
    version: u8 = 1,
    algorithm: []const u8,
    nonceB64: []const u8,
    tagB64: []const u8,
    ciphertextB64: []const u8,
};

pub const SecretStore = struct {
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    requested_backend: []u8,
    active_backend: []u8,
    provider_implemented: bool,
    encrypted_fallback: bool,
    requested_recognized: bool,
    requested_support: []u8,
    fallback_applied: bool,
    fallback_reason: ?[]u8,
    persistent: bool,
    state_path: []u8,
    key_source: []u8,
    key: [Cipher.key_length]u8,
    entries: std.StringHashMap([]u8),
    loaded_at_ms: i64,
    saved_at_ms: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        state_root: []const u8,
        environ: std.process.Environ,
    ) !SecretStore {
        return initWithOptions(allocator, state_root, environ, .{});
    }

    pub fn initWithOptions(
        allocator: std.mem.Allocator,
        state_root: []const u8,
        environ: std.process.Environ,
        options: InitOptions,
    ) !SecretStore {
        var store = SecretStore{
            .allocator = allocator,
            .environ = environ,
            .requested_backend = try allocator.dupe(u8, "env"),
            .active_backend = try allocator.dupe(u8, "env"),
            .provider_implemented = false,
            .encrypted_fallback = false,
            .requested_recognized = true,
            .requested_support = try allocator.dupe(u8, "implemented"),
            .fallback_applied = false,
            .fallback_reason = null,
            .persistent = false,
            .state_path = try allocator.dupe(u8, "memory://secret-store"),
            .key_source = try allocator.dupe(u8, "none"),
            .key = [_]u8{0} ** Cipher.key_length,
            .entries = std.StringHashMap([]u8).init(allocator),
            .loaded_at_ms = 0,
            .saved_at_ms = 0,
        };
        errdefer store.deinit();

        try store.configure(state_root, options);
        if (store.persistent) try store.reload();
        return store;
    }

    pub fn deinit(self: *SecretStore) void {
        self.allocator.free(self.requested_backend);
        self.allocator.free(self.active_backend);
        self.allocator.free(self.requested_support);
        if (self.fallback_reason) |reason| self.allocator.free(reason);
        self.allocator.free(self.state_path);
        self.allocator.free(self.key_source);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.deinit();
    }

    pub fn status(self: *const SecretStore) Status {
        return .{
            .requestedBackend = self.requested_backend,
            .activeBackend = self.active_backend,
            .providerImplemented = self.provider_implemented,
            .encryptedFallback = self.encrypted_fallback,
            .requestedRecognized = self.requested_recognized,
            .requestedSupport = self.requested_support,
            .fallbackApplied = self.fallback_applied,
            .fallbackReason = self.fallback_reason,
            .persistent = self.persistent,
            .path = self.state_path,
            .keySource = self.key_source,
            .loadedAtMs = self.loaded_at_ms,
            .savedAtMs = self.saved_at_ms,
            .count = self.entries.count(),
        };
    }

    pub fn count(self: *const SecretStore) usize {
        return self.entries.count();
    }

    pub fn setSecret(self: *SecretStore, target_id: []const u8, value: []const u8) !void {
        const key = std.mem.trim(u8, target_id, " \t\r\n");
        const secret = std.mem.trim(u8, value, " \t\r\n");
        if (key.len == 0) return error.MissingTargetId;
        if (secret.len == 0) return error.MissingSecretValue;

        if (self.entries.getPtr(key)) |existing| {
            self.allocator.free(existing.*);
            existing.* = try self.allocator.dupe(u8, secret);
        } else {
            const owned_key = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(owned_key);
            const owned_value = try self.allocator.dupe(u8, secret);
            errdefer self.allocator.free(owned_value);
            try self.entries.put(owned_key, owned_value);
        }
        if (self.persistent) try self.persist();
    }

    pub fn deleteSecret(self: *SecretStore, target_id: []const u8) !bool {
        const key = std.mem.trim(u8, target_id, " \t\r\n");
        if (key.len == 0) return false;
        const removed = self.entries.fetchRemove(key);
        if (removed) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            if (self.persistent) try self.persist();
            return true;
        }
        return false;
    }

    pub fn resolveTargetAlloc(self: *const SecretStore, allocator: std.mem.Allocator, target_id: []const u8) !?[]u8 {
        const needle = std.mem.trim(u8, target_id, " \t\r\n");
        if (needle.len == 0) return null;
        if (self.entries.get(needle)) |value| {
            const trimmed = std.mem.trim(u8, value, " \t\r\n");
            if (trimmed.len > 0) return try allocator.dupe(u8, trimmed);
        }

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const key = std.mem.trim(u8, entry.key_ptr.*, " \t\r\n");
            if (key.len == 0) continue;
            if (!wildcardPathMatch(needle, key) and !wildcardPathMatch(key, needle)) continue;
            const value = std.mem.trim(u8, entry.value_ptr.*, " \t\r\n");
            if (value.len == 0) continue;
            return try allocator.dupe(u8, value);
        }
        return null;
    }

    pub fn listKeys(self: *const SecretStore, allocator: std.mem.Allocator) ![]SecretKeyRef {
        var out: std.ArrayList(SecretKeyRef) = .empty;
        defer out.deinit(allocator);

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            try out.append(allocator, .{ .targetId = entry.key_ptr.* });
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn reload(self: *SecretStore) !void {
        self.clearEntries();
        if (!self.persistent) {
            self.loaded_at_ms = time_util.nowMs();
            return;
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        const raw = std.Io.Dir.cwd().readFileAlloc(io, self.state_path, self.allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => {
                self.loaded_at_ms = time_util.nowMs();
                return;
            },
            else => return err,
        };
        defer self.allocator.free(raw);

        var envelope_parsed = try std.json.parseFromSlice(PersistedEnvelope, self.allocator, raw, .{ .ignore_unknown_fields = true });
        defer envelope_parsed.deinit();
        if (!std.ascii.eqlIgnoreCase(envelope_parsed.value.algorithm, "xchacha20poly1305")) {
            return error.UnsupportedSecretStoreAlgorithm;
        }

        var nonce: [Cipher.nonce_length]u8 = undefined;
        try decodeBase64Fixed(Cipher.nonce_length, &nonce, envelope_parsed.value.nonceB64);
        var tag: [Cipher.tag_length]u8 = undefined;
        try decodeBase64Fixed(Cipher.tag_length, &tag, envelope_parsed.value.tagB64);
        const ciphertext = try decodeBase64Alloc(self.allocator, envelope_parsed.value.ciphertextB64);
        defer self.allocator.free(ciphertext);

        const plaintext = try self.allocator.alloc(u8, ciphertext.len);
        defer self.allocator.free(plaintext);
        try Cipher.decrypt(plaintext, ciphertext, tag, aad, nonce, self.key);

        var plain_parsed = try std.json.parseFromSlice(PersistedPlain, self.allocator, plaintext, .{ .ignore_unknown_fields = true });
        defer plain_parsed.deinit();
        for (plain_parsed.value.entries) |entry| {
            const key = std.mem.trim(u8, entry.key, " \t\r\n");
            const value = std.mem.trim(u8, entry.value, " \t\r\n");
            if (key.len == 0 or value.len == 0) continue;
            try self.setSecretNoPersist(key, value);
        }

        self.loaded_at_ms = time_util.nowMs();
    }

    fn persist(self: *SecretStore) !void {
        if (!self.persistent) {
            self.saved_at_ms = time_util.nowMs();
            return;
        }

        const io = std.Io.Threaded.global_single_threaded.io();
        if (std.fs.path.dirname(self.state_path)) |parent| {
            if (parent.len > 0) try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        var out_entries = try self.allocator.alloc(PersistedEntry, self.entries.count());
        defer self.allocator.free(out_entries);

        var idx: usize = 0;
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            out_entries[idx] = .{
                .key = entry.key_ptr.*,
                .value = entry.value_ptr.*,
            };
            idx += 1;
        }

        var plain_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer plain_writer.deinit();
        try std.json.Stringify.value(PersistedPlain{
            .version = 1,
            .entries = out_entries,
        }, .{}, &plain_writer.writer);
        const plain_payload = try plain_writer.toOwnedSlice();
        defer self.allocator.free(plain_payload);

        var nonce: [Cipher.nonce_length]u8 = undefined;
        io.random(nonce[0..]);
        const ciphertext = try self.allocator.alloc(u8, plain_payload.len);
        defer self.allocator.free(ciphertext);
        var tag: [Cipher.tag_length]u8 = undefined;
        Cipher.encrypt(ciphertext, &tag, plain_payload, aad, nonce, self.key);

        const nonce_b64 = try encodeBase64Alloc(self.allocator, nonce[0..]);
        defer self.allocator.free(nonce_b64);
        const tag_b64 = try encodeBase64Alloc(self.allocator, tag[0..]);
        defer self.allocator.free(tag_b64);
        const ciphertext_b64 = try encodeBase64Alloc(self.allocator, ciphertext);
        defer self.allocator.free(ciphertext_b64);

        var env_writer: std.Io.Writer.Allocating = .init(self.allocator);
        defer env_writer.deinit();
        try std.json.Stringify.value(PersistedEnvelope{
            .version = 1,
            .algorithm = "xchacha20poly1305",
            .nonceB64 = nonce_b64,
            .tagB64 = tag_b64,
            .ciphertextB64 = ciphertext_b64,
        }, .{}, &env_writer.writer);
        const payload = try env_writer.toOwnedSlice();
        defer self.allocator.free(payload);

        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = self.state_path,
            .data = payload,
        });
        self.saved_at_ms = time_util.nowMs();
    }

    fn setSecretNoPersist(self: *SecretStore, target_id: []const u8, value: []const u8) !void {
        const key = std.mem.trim(u8, target_id, " \t\r\n");
        const secret = std.mem.trim(u8, value, " \t\r\n");
        if (key.len == 0 or secret.len == 0) return;
        const owned_key = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(owned_key);
        const owned_value = try self.allocator.dupe(u8, secret);
        errdefer self.allocator.free(owned_value);
        const gop = try self.entries.getOrPut(owned_key);
        if (gop.found_existing) {
            self.allocator.free(owned_key);
            self.allocator.free(gop.value_ptr.*);
            gop.value_ptr.* = owned_value;
        } else {
            gop.value_ptr.* = owned_value;
        }
    }

    fn clearEntries(self: *SecretStore) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.entries.clearRetainingCapacity();
    }

    fn configure(self: *SecretStore, state_root: []const u8, options: InitOptions) !void {
        const requested = try resolveRequestedBackendAlloc(self.allocator, self.environ, options.requested_backend);
        defer self.allocator.free(requested);

        self.allocator.free(self.requested_backend);
        self.requested_backend = try self.allocator.dupe(u8, requested);

        const selection = classifyRequestedBackend(requested);

        self.allocator.free(self.active_backend);
        self.active_backend = try self.allocator.dupe(u8, selection.active_backend);
        self.provider_implemented = selection.provider_implemented;
        self.encrypted_fallback = selection.encrypted_fallback;
        self.requested_recognized = selection.requested_recognized;
        self.allocator.free(self.requested_support);
        self.requested_support = try self.allocator.dupe(u8, selection.requested_support);
        self.fallback_applied = selection.fallback_applied;
        if (self.fallback_reason) |reason| self.allocator.free(reason);
        self.fallback_reason = if (selection.fallback_reason) |reason| try self.allocator.dupe(u8, reason) else null;

        if (std.ascii.eqlIgnoreCase(selection.active_backend, "env")) {
            self.persistent = false;
            self.allocator.free(self.state_path);
            self.state_path = try self.allocator.dupe(u8, "memory://secret-store");
            self.allocator.free(self.key_source);
            self.key_source = try self.allocator.dupe(u8, "none");
            self.key = [_]u8{0} ** Cipher.key_length;
            return;
        }

        const resolved_path = try resolveStorePathAlloc(self.allocator, self.environ, state_root, options.store_path_override);
        defer self.allocator.free(resolved_path);
        self.allocator.free(self.state_path);
        self.state_path = try self.allocator.dupe(u8, resolved_path);
        self.persistent = !isMemoryScheme(self.state_path);

        const key_material = try deriveEncryptionKey(self.allocator, self.environ, self.state_path, options.key_override);
        defer self.allocator.free(key_material.source);
        self.allocator.free(self.key_source);
        self.key_source = try self.allocator.dupe(u8, key_material.source);
        self.key = key_material.key;
    }
};

const BackendSelection = struct {
    active_backend: []const u8,
    provider_implemented: bool,
    encrypted_fallback: bool,
    requested_recognized: bool,
    requested_support: []const u8,
    fallback_applied: bool,
    fallback_reason: ?[]const u8,
};

fn classifyRequestedBackend(requested: []const u8) BackendSelection {
    if (std.ascii.eqlIgnoreCase(requested, "env")) {
        return .{
            .active_backend = "env",
            .provider_implemented = true,
            .encrypted_fallback = false,
            .requested_recognized = true,
            .requested_support = "implemented",
            .fallback_applied = false,
            .fallback_reason = null,
        };
    }
    if (std.ascii.eqlIgnoreCase(requested, "file") or std.ascii.eqlIgnoreCase(requested, "encrypted-file")) {
        return .{
            .active_backend = "encrypted-file",
            .provider_implemented = true,
            .encrypted_fallback = false,
            .requested_recognized = true,
            .requested_support = "implemented",
            .fallback_applied = false,
            .fallback_reason = null,
        };
    }
    if (std.ascii.eqlIgnoreCase(requested, "dpapi") or std.ascii.eqlIgnoreCase(requested, "keychain") or std.ascii.eqlIgnoreCase(requested, "keystore")) {
        return .{
            .active_backend = "encrypted-file",
            .provider_implemented = false,
            .encrypted_fallback = true,
            .requested_recognized = true,
            .requested_support = "fallback-only",
            .fallback_applied = true,
            .fallback_reason = "native backend not implemented; using encrypted-file fallback",
        };
    }
    if (std.ascii.eqlIgnoreCase(requested, "auto")) {
        return .{
            .active_backend = "encrypted-file",
            .provider_implemented = false,
            .encrypted_fallback = true,
            .requested_recognized = true,
            .requested_support = "fallback-only",
            .fallback_applied = true,
            .fallback_reason = "auto resolved to encrypted-file fallback because no native backend is implemented",
        };
    }
    return .{
        .active_backend = "env",
        .provider_implemented = false,
        .encrypted_fallback = false,
        .requested_recognized = false,
        .requested_support = "unsupported",
        .fallback_applied = true,
        .fallback_reason = "unsupported requested backend; falling back to env",
    };
}

const KeyMaterial = struct {
    source: []u8,
    key: [Cipher.key_length]u8,
};

fn resolveRequestedBackendAlloc(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    override: ?[]const u8,
) ![]u8 {
    if (override) |explicit| {
        const trimmed = std.mem.trim(u8, explicit, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    if (try pal.secrets.envLookupAlloc(environ, allocator, "OPENCLAW_ZIG_SECRET_BACKEND")) |value| return value;
    if (try pal.secrets.envLookupAlloc(environ, allocator, "OPENCLAW_SECRET_BACKEND")) |value| return value;
    return allocator.dupe(u8, "env");
}

fn resolveStorePathAlloc(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    state_root: []const u8,
    override: ?[]const u8,
) ![]u8 {
    if (override) |explicit| {
        const trimmed = std.mem.trim(u8, explicit, " \t\r\n");
        if (trimmed.len > 0) return allocator.dupe(u8, trimmed);
    }
    if (try pal.secrets.envLookupAlloc(environ, allocator, "OPENCLAW_ZIG_SECRET_STORE_PATH")) |value| return value;

    const trimmed_root = std.mem.trim(u8, state_root, " \t\r\n");
    if (trimmed_root.len == 0 or isMemoryScheme(trimmed_root)) {
        return allocator.dupe(u8, "memory://secret-store");
    }
    if (std.mem.endsWith(u8, trimmed_root, ".json")) {
        if (std.fs.path.dirname(trimmed_root)) |parent| {
            if (parent.len > 0) return std.fs.path.join(allocator, &.{ parent, "secrets.store.enc.json" });
        }
        return allocator.dupe(u8, "secrets.store.enc.json");
    }
    return std.fs.path.join(allocator, &.{ trimmed_root, "secrets.store.enc.json" });
}

fn deriveEncryptionKey(
    allocator: std.mem.Allocator,
    environ: std.process.Environ,
    state_path: []const u8,
    override: ?[]const u8,
) !KeyMaterial {
    if (override) |explicit| {
        const trimmed = std.mem.trim(u8, explicit, " \t\r\n");
        if (trimmed.len > 0) {
            return .{
                .source = try allocator.dupe(u8, "override"),
                .key = sha256ToKey(trimmed),
            };
        }
    }
    if (try pal.secrets.resolveFirstAlloc(environ, allocator, &.{
        "OPENCLAW_ZIG_SECRET_STORE_KEY",
        "OPENCLAW_GO_SECRET_STORE_KEY",
        "OPENCLAW_RS_SECRET_STORE_KEY",
        "OPENCLAW_SECRET_STORE_KEY",
    })) |value| {
        defer allocator.free(value);
        return .{
            .source = try allocator.dupe(u8, "env:OPENCLAW_ZIG_SECRET_STORE_KEY"),
            .key = sha256ToKey(value),
        };
    }
    if (try pal.secrets.resolveFirstAlloc(environ, allocator, &.{
        "OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN",
        "OPENCLAW_GO_GATEWAY_AUTH_TOKEN",
        "OPENCLAW_RS_GATEWAY_AUTH_TOKEN",
    })) |value| {
        defer allocator.free(value);
        return .{
            .source = try allocator.dupe(u8, "env:OPENCLAW_ZIG_GATEWAY_AUTH_TOKEN"),
            .key = sha256ToKey(value),
        };
    }

    var seed: std.ArrayList(u8) = .empty;
    defer seed.deinit(allocator);
    try seed.appendSlice(allocator, "openclaw-zig-secret-store:");
    try seed.appendSlice(allocator, state_path);
    if (try pal.secrets.resolveFirstAlloc(environ, allocator, &.{ "USERNAME", "USER", "LOGNAME" })) |value| {
        defer allocator.free(value);
        try seed.appendSlice(allocator, ":user=");
        try seed.appendSlice(allocator, value);
    }
    if (try pal.secrets.resolveFirstAlloc(environ, allocator, &.{ "COMPUTERNAME", "HOSTNAME" })) |value| {
        defer allocator.free(value);
        try seed.appendSlice(allocator, ":host=");
        try seed.appendSlice(allocator, value);
    }

    return .{
        .source = try allocator.dupe(u8, "derived:machine-state"),
        .key = sha256ToKey(seed.items),
    };
}

fn sha256ToKey(data: []const u8) [Cipher.key_length]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return digest;
}

fn encodeBase64Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

fn decodeBase64Alloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(encoded);
    const out = try allocator.alloc(u8, size);
    errdefer allocator.free(out);
    try decoder.decode(out, encoded);
    return out;
}

fn decodeBase64Fixed(comptime expected_len: usize, out: *[expected_len]u8, encoded: []const u8) !void {
    const decoder = std.base64.standard.Decoder;
    const size = try decoder.calcSizeForSlice(encoded);
    if (size != expected_len) return error.InvalidSecretStoreEnvelope;
    try decoder.decode(out[0..], encoded);
}

fn isMemoryScheme(path: []const u8) bool {
    const prefix = "memory://";
    if (path.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix);
}

fn wildcardPathMatch(pattern: []const u8, value: []const u8) bool {
    const p = std.mem.trim(u8, pattern, " \t\r\n");
    const v = std.mem.trim(u8, value, " \t\r\n");
    if (p.len == 0 or v.len == 0) return false;
    if (std.mem.eql(u8, p, v)) return true;
    if (std.mem.indexOfScalar(u8, p, '*') == null) return false;

    var pat_split = std.mem.splitScalar(u8, p, '*');
    var cursor: usize = 0;
    var first = true;
    while (pat_split.next()) |segment_raw| {
        const segment = std.mem.trim(u8, segment_raw, " \t\r\n");
        if (segment.len == 0) {
            first = false;
            continue;
        }
        if (first and !std.mem.startsWith(u8, v, segment)) return false;
        const found = std.mem.indexOfPos(u8, v, cursor, segment) orelse return false;
        cursor = found + segment.len;
        first = false;
    }
    const suffix = blk: {
        var split = std.mem.splitScalar(u8, p, '*');
        var last: []const u8 = "";
        while (split.next()) |part| last = std.mem.trim(u8, part, " \t\r\n");
        break :blk last;
    };
    if (suffix.len > 0 and !std.mem.endsWith(u8, v, suffix)) return false;
    return true;
}

test "secret store encrypted-file roundtrip persists and reloads" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var store = try SecretStore.initWithOptions(allocator, root, std.process.Environ.empty, .{
        .requested_backend = "file",
        .key_override = "test-secret-key",
    });
    defer store.deinit();

    try store.setSecret("talk.apiKey", "sk-test-1");
    try store.setSecret("channels.telegram.botToken", "tg-test-2");
    try std.testing.expectEqual(@as(usize, 2), store.count());
    try std.testing.expect(store.status().persistent);

    var reloaded = try SecretStore.initWithOptions(allocator, root, std.process.Environ.empty, .{
        .requested_backend = "file",
        .key_override = "test-secret-key",
    });
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), reloaded.count());
    const resolved = try reloaded.resolveTargetAlloc(allocator, "talk.apiKey");
    defer if (resolved) |value| allocator.free(value);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.eql(u8, resolved.?, "sk-test-1"));
}

test "secret store wildcard lookup resolves provider pattern keys" {
    const allocator = std.testing.allocator;
    var store = try SecretStore.initWithOptions(allocator, "memory://secret-test", std.process.Environ.empty, .{
        .requested_backend = "env",
    });
    defer store.deinit();

    try store.setSecret("talk.providers.openrouter.apiKey", "or-secret");
    const resolved = try store.resolveTargetAlloc(allocator, "talk.providers.*.apiKey");
    defer if (resolved) |value| allocator.free(value);
    try std.testing.expect(resolved != null);
    try std.testing.expect(std.mem.eql(u8, resolved.?, "or-secret"));
}

test "secret store status reports implemented env backend" {
    const allocator = std.testing.allocator;
    var store = try SecretStore.initWithOptions(allocator, "memory://secret-test", std.process.Environ.empty, .{
        .requested_backend = "env",
    });
    defer store.deinit();

    const status = store.status();
    try std.testing.expectEqualStrings("env", status.requestedBackend);
    try std.testing.expectEqualStrings("env", status.activeBackend);
    try std.testing.expect(status.requestedRecognized);
    try std.testing.expectEqualStrings("implemented", status.requestedSupport);
    try std.testing.expect(!status.fallbackApplied);
    try std.testing.expect(status.fallbackReason == null);
    try std.testing.expect(status.providerImplemented);
    try std.testing.expect(!status.encryptedFallback);
}

test "secret store status reports encrypted file backend as implemented" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var store = try SecretStore.initWithOptions(allocator, root, std.process.Environ.empty, .{
        .requested_backend = "encrypted-file",
        .key_override = "test-secret-key",
    });
    defer store.deinit();

    const status = store.status();
    try std.testing.expectEqualStrings("encrypted-file", status.requestedBackend);
    try std.testing.expectEqualStrings("encrypted-file", status.activeBackend);
    try std.testing.expect(status.requestedRecognized);
    try std.testing.expectEqualStrings("implemented", status.requestedSupport);
    try std.testing.expect(!status.fallbackApplied);
    try std.testing.expect(status.fallbackReason == null);
    try std.testing.expect(status.providerImplemented);
    try std.testing.expect(!status.encryptedFallback);
    try std.testing.expect(status.persistent);
}

test "secret store status reports native backend requests as fallback only" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.Io.Threaded.global_single_threaded.io();
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    var store = try SecretStore.initWithOptions(allocator, root, std.process.Environ.empty, .{
        .requested_backend = "dpapi",
        .key_override = "test-secret-key",
    });
    defer store.deinit();

    const status = store.status();
    try std.testing.expectEqualStrings("dpapi", status.requestedBackend);
    try std.testing.expectEqualStrings("encrypted-file", status.activeBackend);
    try std.testing.expect(status.requestedRecognized);
    try std.testing.expectEqualStrings("fallback-only", status.requestedSupport);
    try std.testing.expect(status.fallbackApplied);
    try std.testing.expect(status.fallbackReason != null);
    try std.testing.expect(std.mem.indexOf(u8, status.fallbackReason.?, "native backend not implemented") != null);
    try std.testing.expect(!status.providerImplemented);
    try std.testing.expect(status.encryptedFallback);
}

test "secret store status reports unknown backend as unsupported fallback" {
    const allocator = std.testing.allocator;
    var store = try SecretStore.initWithOptions(allocator, "memory://secret-test", std.process.Environ.empty, .{
        .requested_backend = "unknown-backend",
    });
    defer store.deinit();

    const status = store.status();
    try std.testing.expectEqualStrings("unknown-backend", status.requestedBackend);
    try std.testing.expectEqualStrings("env", status.activeBackend);
    try std.testing.expect(!status.requestedRecognized);
    try std.testing.expectEqualStrings("unsupported", status.requestedSupport);
    try std.testing.expect(status.fallbackApplied);
    try std.testing.expect(status.fallbackReason != null);
    try std.testing.expect(std.mem.indexOf(u8, status.fallbackReason.?, "unsupported requested backend") != null);
    try std.testing.expect(!status.providerImplemented);
    try std.testing.expect(!status.encryptedFallback);
}
