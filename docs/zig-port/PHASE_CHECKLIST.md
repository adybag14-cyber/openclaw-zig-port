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
- [x] Port edge handler contracts
- [x] Port wasm runtime/sandbox lifecycle contracts

Phase 6 progress notes:
- Implemented persistent memory store (`src/memory/store.zig`) with session/channel history handlers: `sessions.history`, `chat.history`, and `doctor.memory.status`.
- Implemented edge contract slice in dispatcher: `edge.wasm.marketplace.list`, `edge.router.plan`, `edge.swarm.plan`, `edge.multimodal.inspect`, and `edge.voice.transcribe`.
- Implemented advanced edge contract slice in dispatcher: `edge.enclave.status`, `edge.enclave.prove`, `edge.mesh.status`, `edge.homomorphic.compute`, `edge.finetune.status`, `edge.finetune.run`, `edge.identity.trust.status`, `edge.personality.profile`, `edge.handoff.plan`, `edge.marketplace.revenue.preview`, `edge.finetune.cluster.plan`, `edge.alignment.evaluate`, `edge.quantum.status`, and `edge.collaboration.plan`.
- Added `edge.acceleration.status` parity handler with contract coverage.
- Added wasm/runtime contract depth slice: `config.get` now exposes wasm module + policy snapshot and `tools.catalog` advertises wasm/runtime tool families; `edge.wasm.marketplace.list` now includes `witPackages` and `builderHints` parity fields.
- Added explicit wasm lifecycle contracts: `edge.wasm.install`, `edge.wasm.execute`, and `edge.wasm.remove` with custom module state tracking and sandbox limit/capability enforcement.
- Added OAuth + runtime aliases needed by Go parity callers: `auth.oauth.providers|start|wait|complete|logout|import`, `browser.open`, `chat.send`, and `sessions.send`.
- Added compat observability/session slice:
  - usage + heartbeat + presence methods: `usage.status`, `usage.cost`, `last-heartbeat`, `set-heartbeats`, `system-presence`, `system-event`, `wake`
  - session/log methods: `sessions.list`, `sessions.preview`, `session.status`, `sessions.reset`, `sessions.delete`, `sessions.compact`, `sessions.usage`, `sessions.usage.timeseries`, `sessions.usage.logs`, `logs.tail`
  - memory store now supports `count`, `removeSession`, and `trim` to back these contracts with real state mutations.
- Added compat conversation/control slice:
  - talk/voice methods: `talk.config`, `talk.mode`, `voicewake.get`, `voicewake.set`
  - TTS methods: `tts.status`, `tts.enable`, `tts.disable`, `tts.providers`, `tts.setProvider`, `tts.convert`
  - model/control methods: `models.list`, `chat.abort`, `chat.inject`, `push.test`, `canvas.present`, `update.run`
  - stateful compat runtime now tracks talk mode/voice, TTS provider/enabled, voicewake phrase, and update jobs.
- Added compat config/wizard/session-mutation slice:
  - config methods: `config.set`, `config.patch`, `config.apply`, `config.schema`
  - wizard methods: `wizard.start`, `wizard.next`, `wizard.cancel`, `wizard.status`
  - session mutation methods: `sessions.patch`, `sessions.resolve`
  - `secrets.reload` contract method added for key reload reporting.
- Added compat agent/skills slice:
  - agent methods: `agent`, `agent.identity.get`, `agent.wait`
  - agents methods: `agents.list`, `agents.create`, `agents.update`, `agents.delete`, `agents.files.list`, `agents.files.get`, `agents.files.set`
  - skills methods: `skills.status`, `skills.bins`, `skills.install`, `skills.update`
  - stateful backing added for agents, agent files, installed skills, and async-compatible agent jobs.
- Added compat cron slice:
  - cron methods: `cron.list`, `cron.status`, `cron.add`, `cron.update`, `cron.remove`, `cron.run`, `cron.runs`
  - stateful backing added for cron jobs and bounded cron run history with update/run lifecycle fields.
- Added compat device slice:
  - device methods: `device.pair.list`, `device.pair.approve`, `device.pair.reject`, `device.pair.remove`, `device.token.rotate`, `device.token.revoke`
  - stateful backing added for device pairs and token rotate/revoke lifecycle.
- Added compat node + exec-approval slice:
  - node methods: `node.pair.request`, `node.pair.list`, `node.pair.approve`, `node.pair.reject`, `node.pair.verify`, `node.rename`, `node.list`, `node.describe`, `node.invoke`, `node.invoke.result`, `node.event`, `node.canvas.capability.refresh`
  - exec approval methods: `exec.approvals.get`, `exec.approvals.set`, `exec.approvals.node.get`, `exec.approvals.node.set`, `exec.approval.request`, `exec.approval.waitdecision`, `exec.approval.resolve`
  - stateful backing added for node pairs/nodes/events and approval policies/pending approval lifecycle.
- Method surface now at `145` Zig methods; Go method-set parity is complete at `134/134` with `11` Zig-only extras retained (`shutdown`, `doctor`, `security.audit`, `exec.run`, `file.read`, `file.write`, `web.login.complete`, `web.login.status`, `edge.wasm.install`, `edge.wasm.execute`, `edge.wasm.remove`).

## Phase 7 - Validation + Release
- [x] Run full parity diff against Go baseline
- [x] Run full test matrix and smoke checks
- [x] Build release binaries + checksums
- [x] Publish first Zig preview release

## Latest Validation Snapshot
- [x] `zig build`
- [x] `zig build test`
- [x] `zig test src/main.zig`
- [x] `scripts/zig-syntax-check.ps1`
- [x] `scripts/zig-codeberg-master-check.ps1` (reports local vs remote master hash)
- [x] Go-vs-Zig method diff check: `Go=134`, `Zig=145`, `missing_in_zig=0`, `zig_extras=11`
- [x] Smoke scripts now run against built binary (`zig-out/bin/openclaw-zig.exe`) with readiness loops + early-exit diagnostics:
  - `scripts/docker-smoke-check.ps1` -> host+docker HTTP 200
  - `scripts/web-login-smoke-check.ps1` -> start/wait/complete/status HTTP 200
  - `scripts/telegram-reply-loop-smoke-check.ps1` -> send/poll/auth lifecycle HTTP 200
- [x] `scripts/docker-smoke-check.ps1` (host + Docker HTTP 200 checks on `/health` and `/rpc`)
- [x] `scripts/web-login-smoke-check.ps1` (`web.login.start -> wait -> complete -> status` all HTTP 200 with authorized completion)
- [x] `scripts/telegram-reply-loop-smoke-check.ps1` (`send /auth start -> send /auth complete -> send chat -> poll` all HTTP 200 with non-empty queued replies)
- [x] Freshness check: Codeberg Zig `master`=`852c5d2824afdf3a0997b20923eac15f7569f56a`; local toolchain=`0.16.0-dev.2703+0a412853a` (hash mismatch acknowledged)
- [x] Serve smoke: `GET /health` and `POST /rpc` (`shutdown`) both returned HTTP 200
- [x] Serve smoke: `POST /rpc` `file.write`, `file.read`, and `exec.run` returned HTTP 200 with real payloads
- [x] Serve smoke: `POST /rpc` `security.audit` and `doctor` return structured diagnostics payloads
- [x] Serve smoke: `POST /rpc` `web.login.start`, `web.login.wait`, `web.login.complete`, `web.login.status` return expected lifecycle statuses
- [x] Serve smoke: `POST /rpc` `send` and `poll` return HTTP 200 and include queued Telegram reply payloads
- [x] Release artifacts built in `ReleaseFast` and checksummed:
  - `openclaw-zig-v0.1.0-zig-preview.1-x86_64-windows.zip`
  - `openclaw-zig-v0.1.0-zig-preview.1-x86_64-linux.zip`
  - `openclaw-zig-v0.1.0-zig-preview.1-x86_64-macos.zip`
  - `SHA256SUMS.txt`
- [x] GitHub release published: `v0.1.0-zig-preview.1`
  - https://github.com/adybag14-cyber/openclaw-zig-port/releases/tag/v0.1.0-zig-preview.1
- [x] Cross-target note: `aarch64-linux` and `aarch64-macos` failed on local Zig `0.16.0-dev.2703+0a412853a` Windows toolchain with compiler exit code `5`; release matrix kept to passing `x86_64` targets.
- [x] Dispatcher coverage guard: registry-wide test asserts every method in `registry.supported_methods` resolves in dispatcher (prevents method-set drift regressions).
- [x] Added CI pipeline (`.github/workflows/zig-ci.yml`) for build/test gates and cross-target release build attempts on Zig master.
- [x] Added arm64 diagnostic runner (`scripts/zig-arm64-diagnose.ps1`) to persist stdout/stderr logs for `aarch64-linux` and `aarch64-macos` failures.
- [x] Arm64 diagnostics confirmed local Windows Zig master failure class is toolchain-level (repro on minimal `build-exe`): `compiler_rt` sub-compilation failure, `memory allocation failure`, and (`aarch64-linux`) `invalid constraint: 'X'`.
- [x] CI confirmation: GitHub Actions run `22645119953` passed all jobs, including `aarch64-linux` and `aarch64-macos` cross-target builds on Ubuntu Zig master.
