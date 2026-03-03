# Phase Checklist

Release lock: no release tag is allowed until all phases are complete and parity is measured at 100%.

## Phase 1 - Foundation
- [x] Initialize Zig workspace layout (`gateway`, `protocol`, `bridge`, config/runtime slices)
- [x] Add build/test commands (`zig build`, `zig build test`, local syntax-check script)
- [x] Add config parser + env override skeleton
- [x] Add `/health` endpoint contract in dispatcher (`health` RPC route with JSON payload)

## Phase 2 - Protocol + Gateway Core
- [x] Implement JSON-RPC envelope parsing/serialization
- [x] Build method registry and dispatcher
- [x] Implement HTTP RPC route + graceful shutdown
- [x] Add contract tests for error codes and method routing

## Phase 3 - Runtime + Tooling
- [x] Add runtime state/session primitives
- [x] Implement initial tool runtime actions (`exec`, file read/write)
- [x] Add queue/worker scaffolding for async jobs
- [x] Add integration tests for request lifecycle

## Phase 4 - Security + Diagnostics
- [x] Port core guard flow (prompt/tool policy checks)
- [x] Implement `doctor` and `security.audit` base commands
- [x] Add remediation/reporting contract outputs

## Phase 5 - Browser/Auth/Channels
- [x] Implement web login manager (`start/wait/complete/status`)
- [x] Implement browser completion bridge contract (Lightpanda-only provider policy)
- [x] Implement Telegram command/reply surface (`send`/`poll` + `/auth` + `/model` command path)
- [x] Add smoke coverage for auth + reply loops (`scripts/web-login-smoke-check.ps1` + `scripts/telegram-reply-loop-smoke-check.ps1`)

## Phase 6 - Memory + Edge
- [x] Port memory persistence primitives
- [ ] Port edge handler contracts
- [x] Port wasm runtime/sandbox lifecycle contracts

Phase 6 progress notes:
- Implemented persistent memory store (`src/memory/store.zig`) with session/channel history handlers: `sessions.history`, `chat.history`, and `doctor.memory.status`.
- Implemented edge contract slice in dispatcher: `edge.wasm.marketplace.list`, `edge.router.plan`, `edge.swarm.plan`, `edge.multimodal.inspect`, and `edge.voice.transcribe`.
- Implemented advanced edge contract slice in dispatcher: `edge.enclave.status`, `edge.enclave.prove`, `edge.mesh.status`, `edge.homomorphic.compute`, `edge.finetune.status`, `edge.finetune.run`, `edge.identity.trust.status`, `edge.personality.profile`, `edge.handoff.plan`, `edge.marketplace.revenue.preview`, `edge.finetune.cluster.plan`, `edge.alignment.evaluate`, `edge.quantum.status`, and `edge.collaboration.plan`.
- Added `edge.acceleration.status` parity handler with contract coverage.
- Added wasm/runtime contract depth slice: `config.get` now exposes wasm module + policy snapshot and `tools.catalog` advertises wasm/runtime tool families; `edge.wasm.marketplace.list` now includes `witPackages` and `builderHints` parity fields.
- Added explicit wasm lifecycle contracts: `edge.wasm.install`, `edge.wasm.execute`, and `edge.wasm.remove` with custom module state tracking and sandbox limit/capability enforcement.
- Added OAuth + runtime aliases needed by Go parity callers: `auth.oauth.providers|start|wait|complete|logout|import`, `browser.open`, `chat.send`, and `sessions.send`.
- Remaining: expand edge depth to full Go parity set.

## Phase 7 - Validation + Release
- [ ] Run full parity diff against Go baseline
- [ ] Run full test matrix and smoke checks
- [ ] Build release binaries + checksums
- [ ] Publish first Zig preview release

## Latest Validation Snapshot
- [x] `zig build`
- [x] `zig build test`
- [x] `zig test src/main.zig`
- [x] `scripts/zig-syntax-check.ps1`
- [x] `scripts/zig-codeberg-master-check.ps1` (reports local vs remote master hash)
- [x] `scripts/docker-smoke-check.ps1` (host + Docker HTTP 200 checks on `/health` and `/rpc`)
- [x] `scripts/web-login-smoke-check.ps1` (`web.login.start -> wait -> complete -> status` all HTTP 200 with authorized completion)
- [x] `scripts/telegram-reply-loop-smoke-check.ps1` (`send /auth start -> send /auth complete -> send chat -> poll` all HTTP 200 with non-empty queued replies)
- [x] Freshness check: Codeberg Zig `master`=`2d88a5a10334bddf3bd0b8bc98744ea6f239ce3a`; local toolchain=`0.16.0-dev.2703+0a412853a` (hash mismatch acknowledged)
- [x] Serve smoke: `GET /health` and `POST /rpc` (`shutdown`) both returned HTTP 200
- [x] Serve smoke: `POST /rpc` `file.write`, `file.read`, and `exec.run` returned HTTP 200 with real payloads
- [x] Serve smoke: `POST /rpc` `security.audit` and `doctor` return structured diagnostics payloads
- [x] Serve smoke: `POST /rpc` `web.login.start`, `web.login.wait`, `web.login.complete`, `web.login.status` return expected lifecycle statuses
- [x] Serve smoke: `POST /rpc` `send` and `poll` return HTTP 200 and include queued Telegram reply payloads
