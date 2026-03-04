# RPC Reference

This page provides a grouped reference for RPC families.  
Source of truth: [`src/gateway/registry.zig`](https://github.com/adybag14-cyber/openclaw-zig-port/blob/main/src/gateway/registry.zig)

## Common Envelope

```json
{
  "id": "req-1",
  "method": "health",
  "params": {}
}
```

## Core

- `connect`
- `health`
- `status`
- `shutdown`

## Runtime/Session

- `sessions.list`, `sessions.preview`, `session.status`
- `sessions.patch`, `sessions.resolve`, `sessions.reset`, `sessions.delete`, `sessions.compact`
- `sessions.usage`, `sessions.usage.timeseries`, `sessions.usage.logs`
- `sessions.history`, `chat.history`

## Tools

- `exec.run`
- `file.read`
- `file.write`
- `tools.catalog`

## Security/Diagnostics

- `security.audit`
- `doctor`
- `doctor.memory.status`
- `secrets.reload`
- `secrets.resolve`

## Browser/Auth

- `browser.request`
- `browser.open`
- `web.login.start`
- `web.login.wait`
- `web.login.complete`
- `web.login.status`
- `auth.oauth.providers`
- `auth.oauth.start`
- `auth.oauth.wait`
- `auth.oauth.complete`
- `auth.oauth.logout`
- `auth.oauth.import`

## Channels

- `channels.status`
- `channels.logout`
- `send`
- `chat.send`
- `sessions.send`
- `poll`

## Edge

- wasm: `edge.wasm.marketplace.list`, `edge.wasm.install`, `edge.wasm.execute`, `edge.wasm.remove`
- planning: `edge.router.plan`, `edge.acceleration.status`, `edge.swarm.plan`, `edge.collaboration.plan`
- multimodal: `edge.multimodal.inspect`, `edge.voice.transcribe`
- trust/mesh/enclave: `edge.identity.trust.status`, `edge.mesh.status`, `edge.enclave.status`, `edge.enclave.prove`
- finetune: `edge.finetune.run`, `edge.finetune.status`, `edge.finetune.job.get`, `edge.finetune.cancel`, `edge.finetune.cluster.plan`
- advanced: `edge.homomorphic.compute`, `edge.personality.profile`, `edge.handoff.plan`, `edge.marketplace.revenue.preview`, `edge.alignment.evaluate`, `edge.quantum.status`

## Compat/Operations

- agent surfaces (`agent*`, `agents*`)
- skills surfaces (`skills*`)
- cron surfaces (`cron*`)
- device surfaces (`device.*`)
- node surfaces (`node.*`)
- execution approvals (`exec.approvals.*`, `exec.approval.*`)
- tts/talk/voicewake/system (`tts.*`, `talk.*`, `voicewake.*`, `usage.*`, heartbeat/presence)

## Minimal Call Example

```bash
curl -s http://127.0.0.1:8080/rpc \
  -H "content-type: application/json" \
  -d '{"id":"doctor-1","method":"doctor","params":{"deep":true}}'
```
