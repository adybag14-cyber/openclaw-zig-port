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

Phase 5 enhancement notes:
- Added browser request provider split (`engine` vs target `provider`) so `qwen|zai|inception` route through Lightpanda correctly.
- Added guest bypass metadata and action hints (`stay_logged_out`) to browser completion and OAuth provider catalog payloads.
- Added Telegram `/auth guest <provider>` flow plus callback URL provider inference and shared callback code extraction (`query/fragment/path`) via `web_login.extractAuthCode`.
- Expanded auth provider breadth in Telegram + OAuth catalog: `minimax`, `kimi`, and `zhipuai` (with alias normalization + default model coverage).
- Added account-scoped Telegram auth bindings with force replacement semantics:
  - `/auth start <provider> [account] [--force]`
  - `/auth status|wait|guest|complete|cancel <provider> [session_id] [account]`
  - provider-level authorized fallback for chat replies when any account scope is authorized.
- Added auth UX depth for guest and account flows:
  - `/auth providers` now includes auth mode + guest/popup hints.
  - `/auth bridge <provider>` now returns provider-specific lightpanda guidance.
  - `/auth wait` supports backward-compatible positional timeout (`/auth wait <provider> [account] <seconds>`) in addition to `--timeout`.

## Phase 6 - Memory + Edge
- [x] Port memory persistence primitives
- [x] Port edge handler contracts
- [x] Port wasm runtime/sandbox lifecycle contracts

Phase 6 progress notes:
- Implemented persistent memory store (`src/memory/store.zig`) with session/channel history handlers: `sessions.history`, `chat.history`, and `doctor.memory.status`.
- Optimization hardening for Phase 6 shipped:
  - `memory/store.zig`: batched front-removal helper applied to overflow + trim, and `removeSession` rewritten to linear compaction while preserving order.
  - `runtime/state.zig`: pending job queue now dequeues via head offset + amortized compaction (replaces repeated front removal shifts).
  - `channels/telegram_runtime.zig`: `poll` now drains queue prefix then compacts once, preserving FIFO ordering with lower churn.
  - Added regression tests:
    - `memory.store.test.store removeSession and trim keep ordering with linear compaction`
    - `runtime.state.test.runtime state queue depth stays correct across compaction cycles`
    - `channels.telegram_runtime.test.telegram runtime poll compacts queue front in one pass and keeps ordering`
- Diagnostics perf hardening shipped:
  - `security/audit.zig`: `doctor` now uses cached docker binary probe (`dockerAvailableCached`) to reduce repeated process-spawn cost on repeated diagnostics invocations.
  - Added regression test: `security.audit.test.doctor includes docker binary check`.
- Channel retention hardening shipped:
  - `channels/telegram_runtime.zig`: bounded queue retention (`max_queue_entries=4096`) now drops oldest queued messages with single-pass front compaction.
  - Added regression test: `channels.telegram_runtime.test.telegram runtime queue retention keeps newest entries under cap`.
- Registry hot-path optimization shipped:
  - `gateway/registry.zig`: `supports` now checks exact-case method hits first and only performs case-insensitive fallback when request method contains uppercase characters.
  - Added regression check for mixed-case compatibility: `supports(\"HeAlTh\")`.
- Dispatcher bounded-history compaction shipped:
  - `gateway/dispatcher.zig`: introduced shared `trimFrontOwnedList` helper and moved capped retention paths away from repeated single-item `orderedRemove(0)` for compat/edge histories (`events`, `update_jobs`, `agent_jobs`, `cron_runs`, `node_events`, `finetune_jobs`).
  - Added regression tests:
    - `gateway.dispatcher.test.compat state bounded history keeps newest events`
    - `gateway.dispatcher.test.edge state bounded finetune history keeps newest jobs`
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
  - `secrets.reload` and `secrets.resolve` contract methods added for key reload + secret reference resolution parity.
  - `secrets.resolve` now performs active resolution from config overlay values (direct + wildcard key matching) and environment alias fallbacks (`OPENCLAW_ZIG_*`, `OPENCLAW_GO_*`, `OPENCLAW_RS_*`).
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
- Self-evolution depth update:
  - `edge.finetune.run` now supports provider alias/model default normalization, full trainer argv generation, `OPENCLAW_ZIG_LORA_TRAINER_TIMEOUT_MS`, and non-dry-run trainer execution telemetry.
  - `edge.finetune.status` now includes richer job metadata (`statusReason`, `updatedAtMs`) and dataset source surfaces.
  - new methods: `edge.finetune.job.get`, `edge.finetune.cancel`.
- Self-maintenance/update slice:
  - methods: `system.maintenance.plan`, `system.maintenance.run`, `system.maintenance.status`.
  - integrates doctor/security/memory/heartbeat signals into health scoring and actionable remediation workflows.
- Method surface now at `151` Zig methods; dual-baseline method-set parity is complete:
  - Go latest release baseline: `134/134` covered in Zig.
  - Original OpenClaw latest release baseline: `94/94` covered in Zig.
  - Union baseline: `135/135` covered in Zig.
  - Zig-only extras vs union baseline: `16` (`shutdown`, `doctor`, `security.audit`, `exec.run`, `file.read`, `file.write`, `web.login.complete`, `web.login.status`, `edge.wasm.install`, `edge.wasm.execute`, `edge.wasm.remove`, `edge.finetune.job.get`, `edge.finetune.cancel`, `system.maintenance.plan`, `system.maintenance.run`, `system.maintenance.status`).

## Phase 7 - Validation + Release
- [x] Run full parity diff against Go baseline
- [x] Run full test matrix and smoke checks
- [x] Build release binaries + checksums
- [x] Publish first Zig preview release

## Latest Validation Snapshot
- [x] `zig build`
- [x] `zig build test`
- [x] `zig build test --summary all` -> `66/66` passing (latest post-optimization run)
- [x] `zig test src/main.zig`
- [x] Guest/auth parity tests:
  - `channels.telegram_runtime.test.telegram runtime qwen guest auth lifecycle`
  - `channels.telegram_runtime.test.telegram runtime auth complete infers provider from callback URL`
  - `bridge.web_login.test.guest providers can complete auth with guest token`
- [x] Account-scoped auth tests:
  - `channels.telegram_runtime.test.telegram runtime auth supports account scope and force restart`
- [x] Auth UX tests:
  - `channels.telegram_runtime.test.telegram runtime auth bridge and providers help include guest guidance`
  - `channels.telegram_runtime.test.telegram runtime wait supports positional timeout with account`
- [x] `scripts/zig-syntax-check.ps1`
- [x] `scripts/zig-codeberg-master-check.ps1` (reports local vs remote master hash)
- [x] Multi-baseline method diff check: `Go(latest)=134`, `Original(latest)=94`, `Union=135`, `Zig=151`, `missing_in_zig=0`, `union_extras=16`
- [x] Smoke scripts now run against built binary (`zig-out/bin/openclaw-zig.exe`) with readiness loops + early-exit diagnostics:
  - `scripts/docker-smoke-check.ps1` -> host+docker HTTP 200
  - `scripts/web-login-smoke-check.ps1` -> start/wait/complete/status HTTP 200
  - `scripts/telegram-reply-loop-smoke-check.ps1` -> send/poll/auth lifecycle HTTP 200
- [x] `scripts/docker-smoke-check.ps1` (host + Docker HTTP 200 checks on `/health` and `/rpc`)
- [x] `scripts/web-login-smoke-check.ps1` (`web.login.start -> wait -> complete -> status` all HTTP 200 with authorized completion)
- [x] `scripts/telegram-reply-loop-smoke-check.ps1` (`send /auth start -> send /auth complete -> send chat -> poll` all HTTP 200 with non-empty queued replies)
- [x] Cross-target diagnostics matrix (`scripts/zig-cross-target-matrix.ps1`) now covers desktop + Android with per-target logs and JSON summary:
  - Local Windows Zig master result: `4/8` pass (`x86_64-windows`, `x86_64-linux`, `x86_64-macos`, `x86_64-linux-android`)
  - Local failures: `aarch64-linux`, `aarch64-macos`, `aarch64-linux-android`, `arm-linux-androideabi`
  - Failure class reproduces in minimal targets and remains toolchain-level on this host (`compiler_rt` + `memory allocation failure`; `aarch64-linux*` additionally show `invalid constraint: 'X'`; `arm-linux-androideabi` minimal repro exits with access-violation code `-1073741819`)
  - Evidence: `release/cross-target-diagnostics/summary.json` and per-target `stdout/stderr` logs in `release/cross-target-diagnostics/`
- [x] Android ARMv7 link failure (`__tls_get_addr`) was resolved for CI/release builds by forcing single-threaded mode for `arm-linux-androideabi` in `build.zig`.
- [x] Freshness check: Codeberg Zig `master`=`ce32003625566dcc3687e9e32be411ccb83a4aaa`; local toolchain=`0.16.0-dev.2703+0a412853a` (hash mismatch acknowledged)
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
- [x] Expanded CI cross-target matrix with Android builds:
  - `x86_64-linux-android` (required)
  - `aarch64-linux-android` and `arm-linux-androideabi` (required)
- [x] Added arm64 diagnostic runner (`scripts/zig-arm64-diagnose.ps1`) to persist stdout/stderr logs for `aarch64-linux` and `aarch64-macos` failures.
- [x] Arm64 diagnostics confirmed local Windows Zig master failure class is toolchain-level (repro on minimal `build-exe`): `compiler_rt` sub-compilation failure, `memory allocation failure`, and (`aarch64-linux`) `invalid constraint: 'X'`.
- [x] CI confirmation: GitHub Actions run `22645119953` passed all jobs, including `aarch64-linux` and `aarch64-macos` cross-target builds on Ubuntu Zig master.
- [x] Added CI release workflow (`.github/workflows/release-preview.yml`) to publish full preview artifact matrix from Linux runners, including arm64 targets.
- [x] Expanded release preview build matrix with Android artifact targets:
  - `x86_64-android` (required)
  - `aarch64-android` and `armv7-android` (required)
- [x] CI confirmation after ARMv7 fix: GitHub Actions run `22651999994` succeeded with Android cross-target jobs all green (`x86_64-android`, `aarch64-android`, `armv7-android`).
- [x] Release workflow smoke validated: Actions run `22645353103` published `v0.1.0-zig-preview.ci-smoke` with full 5-target artifact set + `SHA256SUMS.txt`.
- [x] Added cross-repo method parity gate script (`scripts/check-go-method-parity.ps1`) and wired it into CI + release workflows as a blocking check.
- [x] Parity gate now resolves and checks both latest release baselines on each run:
  - `adybag14-cyber/openclaw-go-port` latest release tag
  - `openclaw/openclaw` latest release tag
- [x] Release workflow hardened with upfront validate job (`build` + `test` + parity gate) and duplicate-tag guard before publish.
- [x] Parity gate now emits machine-readable report (`parity-go-zig.json`) and CI/release workflows publish it as audit evidence.
- [x] Release workflow evidence update: run `22646343174` published `v0.1.0-zig-preview.ci-parityjson` including `parity-go-zig.json` alongside all target zips + `SHA256SUMS.txt`.
- [x] Parity reporting now includes reviewer-friendly markdown (`parity-go-zig.md`) in CI artifacts and release assets.
- [x] Release workflow evidence update: run `22646648616` published `v0.1.0-zig-preview.ci-paritymd` including both `parity-go-zig.json` and `parity-go-zig.md`.
- [x] Added cross-platform runtime smoke gate (`scripts/runtime-smoke-check.ps1`) and wired it into `zig-ci` validate job.
- [x] Tracking/docs refresh:
  - README updated with current parity + validation + workflow status.
  - `docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md` updated to current local/remote Zig hash state.
  - GitHub tracking comments updated with recent optimization evidence.
