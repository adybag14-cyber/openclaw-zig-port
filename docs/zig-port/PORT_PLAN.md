# Zig Port Plan

## Objective

Port OpenClaw Go runtime behavior from baseline commit `65c974b528e2` into a production Zig runtime with parity-first validation.

## Critical Points

- Preserve wire compatibility for existing RPC envelopes and method names.
- Keep behavior parity before optimization changes.
- Require tests for every vertical slice (`config + handler + integration contract`).
- Block release until parity gates and smoke checks pass.
- Push each completed parity slice to GitHub immediately; release artifacts remain blocked until parity is 100%.
- Keep security, browser bridge, and Telegram flows first-class (no stubs).

## Phases

1. Foundation
- Zig project scaffold, build scripts, lint/test harness, config loader, health endpoint.

2. Protocol + Gateway Core
- RPC envelope codec, registry, dispatcher, HTTP server, graceful shutdown.

3. Runtime + Tooling
- runtime state model, scheduler primitives, tool runtime foundation (`exec`, files, message/session ops).

4. Security + Diagnostics
- guard pipeline, policy checks, doctor/security audit command surface.

5. Browser + Auth + Channels
- browser-bridge contracts (Lightpanda-only runtime; Playwright/Puppeteer explicitly rejected), OAuth/login lifecycle, Telegram channel parity.

6. Memory + Edge
- memory store equivalents, edge method payload handling, wasm/sandbox lifecycle.

7. Validation + Release
- parity diff checks, CP-style gates, cross-platform build matrix, signed artifacts, release cut.

## Done Criteria

- RPC contract parity score: `100%`
- No unimplemented handlers in advertised method set
- Full test suite green
- End-to-end smoke for browser auth and Telegram replies
- Host + Docker smoke/system checks return HTTP 200 for gateway surfaces
- Release artifacts built for target platforms

## Current Progress Snapshot

- Phase 2 complete:
  - JSON-RPC envelope parser/encoder
  - Registry + dispatcher
  - HTTP route implementation (`GET /health`, `POST /rpc`)
  - Graceful shutdown via RPC `shutdown` method
- Phase 3 complete:
  - Runtime session primitives + queue lifecycle
  - Tool runtime actions (`exec.run`, `file.read`, `file.write`)
  - Dispatcher wiring and integration request lifecycle tests
  - Runtime status telemetry (`runtime_queue_depth`, `runtime_sessions`)
- Phase 4 complete:
  - Guard pipeline with prompt-risk scoring + loop-guard enforcement (`src/security/guard.zig`, `src/security/loop_guard.zig`)
  - RPC diagnostics surfaces: `security.audit` and `doctor`
  - CLI diagnostics surfaces: `--doctor`, `--security-audit`, optional `--deep` and `--fix`
  - Security audit deep probe and remediation actions (`src/security/audit.zig`)
- Phase 5 complete:
  - Real web login manager implemented (`src/bridge/web_login.zig`) with `web.login.start|wait|complete|status`
  - Telegram command/reply runtime implemented (`src/channels/telegram_runtime.zig`) with `send` and `poll` RPC wiring
  - Telegram command surface now handles `/auth` and `/model` flows with queued reply polling
  - Dispatcher `channels.status` now includes telegram queue/target/auth telemetry
  - Added auth + reply-loop smokes (`scripts/web-login-smoke-check.ps1`, `scripts/telegram-reply-loop-smoke-check.ps1`)
- Phase 6 in progress:
  - Memory persistence primitives implemented (`src/memory/store.zig`) with append/history/stats and on-disk JSON persistence.
  - Dispatcher memory parity slice shipped: `sessions.history`, `chat.history`, and `doctor.memory.status`.
  - Edge handler parity slice shipped: `edge.wasm.marketplace.list`, `edge.router.plan`, `edge.swarm.plan`, `edge.multimodal.inspect`, and `edge.voice.transcribe`.
  - Advanced edge handler parity slice shipped: `edge.enclave.status`, `edge.enclave.prove`, `edge.mesh.status`, `edge.homomorphic.compute`, `edge.finetune.status`, `edge.finetune.run`, `edge.identity.trust.status`, `edge.personality.profile`, `edge.handoff.plan`, `edge.marketplace.revenue.preview`, `edge.finetune.cluster.plan`, `edge.alignment.evaluate`, `edge.quantum.status`, and `edge.collaboration.plan`.
  - Added `edge.acceleration.status` parity contract and test coverage.
  - Added runtime/wasm contract depth slice:
    - `config.get` now returns gateway/runtime/browser/channel/memory/security/wasm snapshots with sandbox policy.
    - `tools.catalog` now exposes wasm/runtime/browser/message tool families and counts.
    - `edge.wasm.marketplace.list` now includes `witPackages` + `builderHints` parity metadata.
    - explicit wasm lifecycle RPCs implemented: `edge.wasm.install`, `edge.wasm.execute`, and `edge.wasm.remove` (custom module state + sandbox enforcement).
  - Added Go-compat alias surfaces for auth/runtime callers:
    - `auth.oauth.providers|start|wait|complete|logout|import`
    - `browser.open`, `chat.send`, and `sessions.send`
  - Added dispatcher contract tests for new edge methods and memory flows.
- Toolchain/runtime notes (local Windows Zig master):
  - Codeberg `master` is currently `2d88a5a10334bddf3bd0b8bc98744ea6f239ce3a`.
  - Local Zig toolchain remains `0.16.0-dev.2703+0a412853a` (hash `0a412853a`) and is behind current Codeberg `master` (acknowledged).
  - Added Windows build workaround in `build.zig`:
    - use `-fstrip` for executable to avoid missing `.pdb` install failure on this master toolchain.
    - route `zig build test` through `zig test src/main.zig` on Windows to avoid build-runner `--listen` regression.
