# Feature Coverage

This page summarizes functional coverage across all major OpenClaw Zig runtime domains.

## Protocol and Gateway

- `connect`, `health`, `status`, `shutdown`
- HTTP route surface:
  - `GET /health`
  - `POST /rpc`
- dispatcher coverage test ensures every registered method is dispatchable

## Runtime and Tooling

- tool runtime:
  - `exec.run`
  - `file.read`
  - `file.write`
- session and history lifecycle:
  - list/preview/status
  - patch/resolve/reset/delete/compact
  - usage, timeseries, logs
  - `sessions.history`, `chat.history`

## Security and Diagnostics

- guard and loop-guard pipelines
- audit and doctor surfaces:
  - `security.audit`
  - `doctor`
  - `doctor.memory.status`
- remediation:
  - audit `--fix` path

## Browser and Auth

- web login lifecycle:
  - `web.login.start`
  - `web.login.wait`
  - `web.login.complete`
  - `web.login.status`
- OAuth compatibility aliases:
  - `auth.oauth.providers|start|wait|complete|logout|import`
- browser request/open:
  - `browser.request`
  - `browser.open`
- provider breadth includes chatgpt/codex/claude/gemini/openrouter/opencode and guest-capable qwen/zai/inception flows

## Channels and Telegram

- channel methods:
  - `channels.status`
  - `channels.logout`
  - `send`, `chat.send`, `sessions.send`
  - `poll`
- telegram command surface:
  - `/auth` family
  - `/model` family
- queue behavior:
  - bounded retention
  - FIFO-preserving single-pass compaction

## Memory

- persistent store with append/history/stats
- memory-backed doctor status and session/chat history retrieval
- efficient trim and session removal with linear compaction

## Edge and Advanced Surfaces

- wasm lifecycle:
  - marketplace list/install/execute/remove
- planning and acceleration:
  - router, acceleration, swarm, collaboration
- multimodal and voice:
  - multimodal inspect, voice transcribe
- enclave/mesh/homomorphic:
  - enclave status/prove, mesh status, homomorphic compute
- finetune:
  - run/status/job get/cancel/cluster plan
- additional edge contracts:
  - identity trust, personality, handoff, revenue preview, alignment, quantum

## Operations and Compat Coverage

- agents/skills
- cron
- device pairing and token rotation/revoke
- node flows and execution approval workflows
- tts/voicewake/talk and heartbeat/presence control surfaces
- update lifecycle:
  - `update.plan`
  - `update.status`
  - `update.run`
- npm ecosystem surface:
  - publishable JS client package `@adybag14-cyber/openclaw-zig-rpc-client`
  - npm release pipeline via GitHub Actions

For the complete method set, see [`src/gateway/registry.zig`](https://github.com/adybag14-cyber/openclaw-zig-port/blob/main/src/gateway/registry.zig).
