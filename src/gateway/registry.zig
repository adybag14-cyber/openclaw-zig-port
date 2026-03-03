const std = @import("std");

pub const supported_methods = [_][]const u8{
    "connect",
    "health",
    "status",
    "shutdown",
    "usage.status",
    "usage.cost",
    "last-heartbeat",
    "set-heartbeats",
    "system-presence",
    "system-event",
    "wake",
    "talk.config",
    "talk.mode",
    "tts.status",
    "tts.enable",
    "tts.disable",
    "tts.convert",
    "tts.setProvider",
    "tts.providers",
    "voicewake.get",
    "voicewake.set",
    "models.list",
    "config.get",
    "tools.catalog",
    "exec.run",
    "file.read",
    "file.write",
    "web.login.start",
    "web.login.wait",
    "web.login.complete",
    "web.login.status",
    "auth.oauth.providers",
    "auth.oauth.start",
    "auth.oauth.wait",
    "auth.oauth.complete",
    "auth.oauth.logout",
    "auth.oauth.import",
    "browser.request",
    "browser.open",
    "security.audit",
    "doctor",
    "doctor.memory.status",
    "edge.wasm.marketplace.list",
    "edge.wasm.execute",
    "edge.wasm.install",
    "edge.wasm.remove",
    "edge.router.plan",
    "edge.acceleration.status",
    "edge.swarm.plan",
    "edge.multimodal.inspect",
    "edge.voice.transcribe",
    "edge.enclave.status",
    "edge.enclave.prove",
    "edge.mesh.status",
    "edge.homomorphic.compute",
    "edge.finetune.status",
    "edge.finetune.run",
    "edge.identity.trust.status",
    "edge.personality.profile",
    "edge.handoff.plan",
    "edge.marketplace.revenue.preview",
    "edge.finetune.cluster.plan",
    "edge.alignment.evaluate",
    "edge.quantum.status",
    "edge.collaboration.plan",
    "channels.status",
    "channels.logout",
    "update.run",
    "push.test",
    "logs.tail",
    "canvas.present",
    "sessions.list",
    "sessions.preview",
    "session.status",
    "sessions.reset",
    "sessions.delete",
    "sessions.compact",
    "sessions.usage",
    "sessions.usage.timeseries",
    "sessions.usage.logs",
    "send",
    "chat.send",
    "chat.abort",
    "chat.inject",
    "sessions.send",
    "poll",
    "sessions.history",
    "chat.history",
};

pub fn supports(method: []const u8) bool {
    for (supported_methods) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, method)) return true;
    }
    return false;
}

pub fn count() usize {
    return supported_methods.len;
}

test "registry includes browser.request and health" {
    try std.testing.expect(supports("browser.request"));
    try std.testing.expect(supports("health"));
    try std.testing.expect(!supports("unknown.method"));
}
