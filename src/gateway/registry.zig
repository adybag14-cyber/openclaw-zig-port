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
    "agent",
    "agent.identity.get",
    "agent.wait",
    "agents.list",
    "agents.create",
    "agents.update",
    "agents.delete",
    "agents.files.list",
    "agents.files.get",
    "agents.files.set",
    "skills.status",
    "skills.bins",
    "skills.install",
    "skills.update",
    "cron.list",
    "cron.status",
    "cron.add",
    "cron.update",
    "cron.remove",
    "cron.run",
    "cron.runs",
    "device.pair.list",
    "device.pair.approve",
    "device.pair.reject",
    "device.pair.remove",
    "device.token.rotate",
    "device.token.revoke",
    "node.pair.request",
    "node.pair.list",
    "node.pair.approve",
    "node.pair.reject",
    "node.pair.verify",
    "node.rename",
    "node.list",
    "node.describe",
    "node.invoke",
    "node.invoke.result",
    "node.event",
    "node.canvas.capability.refresh",
    "exec.approvals.get",
    "exec.approvals.set",
    "exec.approvals.node.get",
    "exec.approvals.node.set",
    "exec.approval.request",
    "exec.approval.waitdecision",
    "exec.approval.resolve",
    "secrets.reload",
    "secrets.resolve",
    "secrets.store.status",
    "secrets.store.set",
    "secrets.store.get",
    "secrets.store.delete",
    "secrets.store.list",
    "config.get",
    "config.set",
    "config.patch",
    "config.apply",
    "config.schema",
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
    "edge.finetune.job.get",
    "edge.finetune.cancel",
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
    "channels.telegram.webhook.receive",
    "channels.telegram.bot.send",
    "system.maintenance.plan",
    "system.maintenance.run",
    "system.maintenance.status",
    "system.boot.status",
    "system.boot.verify",
    "system.boot.attest",
    "system.boot.attest.verify",
    "system.boot.policy.get",
    "system.boot.policy.set",
    "system.rollback.plan",
    "system.rollback.run",
    "system.rollback.cancel",
    "update.plan",
    "update.status",
    "update.run",
    "wizard.start",
    "wizard.next",
    "wizard.cancel",
    "wizard.status",
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
    "sessions.patch",
    "sessions.resolve",
    "send",
    "chat.send",
    "chat.abort",
    "chat.inject",
    "sessions.send",
    "poll",
    "sessions.history",
    "chat.history",
};

pub const supported_events = [_][]const u8{
    "connect.challenge",
    "agent",
    "chat",
    "presence",
    "tick",
    "talk.mode",
    "shutdown",
    "health",
    "heartbeat",
    "cron",
    "node.pair.requested",
    "node.pair.resolved",
    "node.invoke.request",
    "device.pair.requested",
    "device.pair.resolved",
    "voicewake.changed",
    "exec.approval.requested",
    "exec.approval.resolved",
    "update.available",
};

pub fn supports(method: []const u8) bool {
    var has_upper = false;
    for (method) |ch| {
        if (std.ascii.isUpper(ch)) {
            has_upper = true;
            break;
        }
    }

    for (supported_methods) |entry| {
        if (std.mem.eql(u8, entry, method)) return true;
    }
    if (!has_upper) return false;

    for (supported_methods) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, method)) return true;
    }

    return false;
}

pub fn supportsEvent(event: []const u8) bool {
    var has_upper = false;
    for (event) |ch| {
        if (std.ascii.isUpper(ch)) {
            has_upper = true;
            break;
        }
    }

    for (supported_events) |entry| {
        if (std.mem.eql(u8, entry, event)) return true;
    }
    if (!has_upper) return false;

    for (supported_events) |entry| {
        if (std.ascii.eqlIgnoreCase(entry, event)) return true;
    }

    return false;
}

pub fn count() usize {
    return supported_methods.len;
}

test "registry includes browser.request and health" {
    try std.testing.expect(supports("browser.request"));
    try std.testing.expect(supports("health"));
    try std.testing.expect(supports("HeAlTh"));
    try std.testing.expect(!supports("unknown.method"));
}

test "registry includes core gateway events" {
    try std.testing.expect(supportsEvent("connect.challenge"));
    try std.testing.expect(supportsEvent("UPDATE.AVAILABLE"));
    try std.testing.expect(!supportsEvent("unknown.event"));
}
