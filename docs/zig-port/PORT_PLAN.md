# Zig Port Plan

## Objective

Track and achieve OpenClaw Zig parity against both upstream baselines:
- latest `adybag14-cyber/openclaw-go-port` release tag
- latest `openclaw/openclaw` release tag

while maintaining parity-first validation and release gating.

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

- Tracking and documentation refresh (2026-03-04):
  - README refreshed with current parity/validation state and workflow guidance.
  - Local Zig toolchain reference doc refreshed to current local/remote hashes.
  - MkDocs documentation site scaffolded with full feature/domain documentation and GitHub Pages deployment workflow.
  - GitHub Pages enabled and verified with workflow deployment:
    - site: https://adybag14-cyber.github.io/openclaw-zig-port/
    - workflow run: https://github.com/adybag14-cyber/openclaw-zig-port/actions/runs/22653680203
  - RPC reference automation and drift guard added:
    - `scripts/generate-rpc-reference.ps1` generates `docs/rpc-reference.md` from `src/gateway/registry.zig`.
    - `zig-ci`, `release-preview`, and `docs-pages` now regenerate and enforce `git diff --exit-code` on `docs/rpc-reference.md`.
  - Next-generation update/release expansion added:
    - new channel-aware update methods: `update.plan` and `update.status` (alongside enriched `update.run`).
    - npm client package scaffolded at `npm/openclaw-zig-rpc-client` with publish workflow `.github/workflows/npm-release.yml`.
    - npm package dry-run checks now enforced in `zig-ci`, `release-preview` validate stage, and local `scripts/npm-pack-check.ps1`.
  - GitHub tracking issue updated with optimization-slice evidence:
    - https://github.com/adybag14-cyber/openclaw-zig-port/issues/1#issuecomment-3994942224
    - https://github.com/adybag14-cyber/openclaw-zig-port/issues/1#issuecomment-3994964162
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
  - Added provider-aware guest/auth parity for browser-session providers:
    - Qwen/GLM-5/Mercury-2 now expose explicit guest bypass metadata (`stay_logged_out`) through `browser.request` and OAuth provider catalog responses.
    - `/auth guest <provider>` command path added for Telegram, plus callback-URL provider inference and robust callback code extraction (`query/fragment/path`) shared with web login.
    - Browser request parsing now separates `engine` (`lightpanda`) from target `provider` so `qwen|zai|inception` no longer fail as unsupported engine values.
  - Expanded auth provider breadth:
    - Added `minimax`, `kimi`, and `zhipuai` entries to OAuth provider catalog contracts.
    - Extended Telegram provider alias + default-model normalization to cover those providers end-to-end.
  - Added account-scoped auth lifecycle parity in Telegram runtime:
    - provider+account binding keys with backward-compatible legacy lookup.
    - `--force` session replacement for `/auth start`.
    - account-aware `status/wait/guest/complete/cancel` parsing and messaging.
  - Added auth UX parity improvements in Telegram runtime:
    - `/auth providers` output now exposes mode/guest/popup metadata.
    - `/auth bridge <provider>` returns provider-specific lightpanda guest/auth guidance.
    - `/auth wait` now accepts positional timeout syntax in addition to `--timeout`.
    - `/auth link|open` now re-surfaces pending auth URL/code/session details with provider/account aware completion commands.
  - Added live Lightpanda bridge probe telemetry in dispatcher:
    - `browser.request` and `browser.open` now run a real endpoint probe against `<endpoint>/json/version`.
    - Probe telemetry is returned in the RPC payload (`probe.ok/url/statusCode/latencyMs/error`) alongside completion metadata.
    - Request params now accept bridge overrides (`endpoint|bridgeEndpoint|lightpandaEndpoint`, `requestTimeoutMs|timeoutMs`) for parity-safe smoke and deployment checks.
  - Added real browser completion execution path in dispatcher:
    - `browser.request` now executes live Lightpanda completion calls when prompt/messages payloads are present (`POST <endpoint>/v1/chat/completions`).
    - Responses now include `bridgeCompletion` telemetry with request URL, status code, assistant text extraction, latency, and failure reason surfaces.
    - Completion parser now normalizes aliases and payload keys (`prompt|message|text`, `messages`, `max_tokens|maxTokens`, `loginSessionId|login_session_id`, `apiKey|api_key`) for parity with Go runtime behavior.
  - Added completion semantics hardening:
    - Top-level `ok/status/message` now reflect bridge execution success/failure for completion requests (failure surfaces as `status=failed` with bridge error context).
    - Assistant text extraction expanded to additional response shapes (`output_text`, `output[].content[]`, and array-form message content) to reduce empty-response false negatives.
  - Dispatcher `channels.status` now includes telegram queue/target/auth telemetry
  - Added auth + reply-loop smokes (`scripts/web-login-smoke-check.ps1`, `scripts/telegram-reply-loop-smoke-check.ps1`)
  - Telegram reply-loop smoke now asserts `/auth link` parity guidance includes active code/session identifiers and completion command hints.
- Phase 6 in progress:
  - Memory persistence primitives implemented (`src/memory/store.zig`) with append/history/stats and on-disk JSON persistence.
  - Memory/runtime/channel optimization slice shipped:
    - `Store.removeSession` and `Store.trim` now use linear compaction (no repeated front `orderedRemove`) and append overflow uses batched front removal (`src/memory/store.zig`).
    - Runtime job queue now uses head-offset dequeue with amortized compaction to avoid repeated `orderedRemove(0)` shifting (`src/runtime/state.zig`).
    - Telegram `poll` now drains queue prefixes in one compaction pass while preserving ordering (`src/channels/telegram_runtime.zig`).
    - Added regression tests for memory ordering/trim, runtime compaction depth/order invariants, and telegram poll compaction ordering.
  - Diagnostics optimization slice shipped:
    - `doctor` now uses a process-local cached docker binary probe to avoid repeated `docker --version` process spawns during repeated diagnostics calls (`src/security/audit.zig`).
    - Added doctor check-presence regression coverage for `docker.binary`.
  - Channel retention hardening shipped:
    - Telegram runtime now enforces bounded queue retention (`max_queue_entries`, default `4096`) and drops oldest entries via single-pass compaction to prevent unbounded memory growth under delayed polling (`src/channels/telegram_runtime.zig`).
    - Added regression coverage to verify newest-entry retention ordering under queue cap.
  - Gateway registry lookup optimization shipped:
    - `registry.supports` now fast-paths exact lowercase method matches using `std.mem.eql` and only runs case-insensitive fallback scans when uppercase input is present (`src/gateway/registry.zig`).
    - Added mixed-case compatibility regression check (`supports(\"HeAlTh\")`).
  - Dispatcher bounded-history compaction shipped:
    - Added shared front-compaction helper for owned bounded lists in dispatcher state and replaced repeated front `orderedRemove(0)` retention paths for events/update jobs/agent jobs/cron runs/node events/finetune jobs (`src/gateway/dispatcher.zig`).
    - Added retention regression tests for compat event history and edge finetune history caps.
  - Dispatcher memory parity slice shipped: `sessions.history`, `chat.history`, and `doctor.memory.status`.
  - Edge handler parity slice shipped: `edge.wasm.marketplace.list`, `edge.router.plan`, `edge.swarm.plan`, `edge.multimodal.inspect`, and `edge.voice.transcribe`.
  - Advanced edge handler parity slice shipped: `edge.enclave.status`, `edge.enclave.prove`, `edge.mesh.status`, `edge.homomorphic.compute`, `edge.finetune.status`, `edge.finetune.run`, `edge.identity.trust.status`, `edge.personality.profile`, `edge.handoff.plan`, `edge.marketplace.revenue.preview`, `edge.finetune.cluster.plan`, `edge.alignment.evaluate`, `edge.quantum.status`, and `edge.collaboration.plan`.
  - Self-evolution depth expansion shipped for Zig finetune runtime:
    - `edge.finetune.run` now normalizes provider aliases/model defaults, emits full trainer argv (`rank/epochs/lr/max-samples/output[/dataset]`), honors `OPENCLAW_ZIG_LORA_TRAINER_TIMEOUT_MS`, and executes real trainer command in non-dry-run mode with execution telemetry.
    - `edge.finetune.status` now exposes richer job metadata (`statusReason`, `updatedAtMs`) and dataset source surfaces (`zvec` + `graphlite`).
    - Added evolution job-control methods: `edge.finetune.job.get` and `edge.finetune.cancel`.
  - Self-maintenance/update system slice shipped:
    - Added `system.maintenance.plan` to synthesize doctor/security/memory liveness into actionable maintenance plans with health scoring.
    - Added `system.maintenance.run` to execute auto-remediation actions (`security.audit` fix path, memory compaction, heartbeat restoration) and persist run status through update-job tracking.
    - Added `system.maintenance.status` to expose latest maintenance run status plus current health and pending action counts.
  - Added `edge.acceleration.status` parity contract and test coverage.
  - Added runtime/wasm contract depth slice:
    - `config.get` now returns gateway/runtime/browser/channel/memory/security/wasm snapshots with sandbox policy.
    - `tools.catalog` now exposes wasm/runtime/browser/message tool families and counts.
    - `edge.wasm.marketplace.list` now includes `witPackages` + `builderHints` parity metadata.
    - explicit wasm lifecycle RPCs implemented: `edge.wasm.install`, `edge.wasm.execute`, and `edge.wasm.remove` (custom module state + sandbox enforcement).
  - Added Go-compat alias surfaces for auth/runtime callers:
    - `auth.oauth.providers|start|wait|complete|logout|import`
    - `browser.open`, `chat.send`, and `sessions.send`
  - Added compat observability/session surfaces with stateful behavior:
    - usage/heartbeat/presence: `usage.status`, `usage.cost`, `last-heartbeat`, `set-heartbeats`, `system-presence`, `system-event`, `wake`
    - session/log lifecycle: `sessions.list`, `sessions.preview`, `session.status`, `sessions.reset`, `sessions.delete`, `sessions.compact`, `sessions.usage`, `sessions.usage.timeseries`, `sessions.usage.logs`, `logs.tail`
    - memory primitives expanded (`count`, `removeSession`, `trim`) to support real reset/delete/compact semantics.
  - Added compat conversation/control surfaces with stateful behavior:
    - `talk.config`, `talk.mode`, `voicewake.get`, `voicewake.set`
    - `tts.status`, `tts.enable`, `tts.disable`, `tts.providers`, `tts.setProvider`, `tts.convert`
    - `models.list`, `chat.abort`, `chat.inject`, `push.test`, `canvas.present`, `update.run`
  - Added config/wizard/session-mutation compat surfaces:
    - `config.set`, `config.patch`, `config.apply`, `config.schema`
    - `wizard.start`, `wizard.next`, `wizard.cancel`, `wizard.status`
    - `sessions.patch`, `sessions.resolve`, `secrets.reload`, `secrets.resolve`
    - `secrets.resolve` now performs active secret resolution from config overlay keys (including wildcard matching) and environment aliases (`OPENCLAW_ZIG_*` with `OPENCLAW_GO_*` / `OPENCLAW_RS_*` fallbacks), instead of returning inactive placeholders only.
  - Added compat agent/skills surfaces with stateful behavior:
    - `agent`, `agent.identity.get`, `agent.wait`
    - `agents.list`, `agents.create`, `agents.update`, `agents.delete`, `agents.files.list`, `agents.files.get`, `agents.files.set`
    - `skills.status`, `skills.bins`, `skills.install`, `skills.update`
  - Added compat cron surfaces with stateful behavior:
    - `cron.list`, `cron.status`, `cron.add`, `cron.update`, `cron.remove`, `cron.run`, `cron.runs`
    - stateful cron job/run lifecycle with run-history retention and status snapshots.
  - Added compat device surfaces with stateful behavior:
    - `device.pair.list`, `device.pair.approve`, `device.pair.reject`, `device.pair.remove`, `device.token.rotate`, `device.token.revoke`
    - stateful pair/token lifecycle with update and revoke flows.
  - Added compat node + exec-approval surfaces with stateful behavior:
    - node: `node.pair.request|list|approve|reject|verify`, `node.rename`, `node.list`, `node.describe`, `node.invoke`, `node.invoke.result`, `node.event`, `node.canvas.capability.refresh`
    - approvals: `exec.approvals.get|set|node.get|node.set`, `exec.approval.request|waitdecision|resolve`
  - Method surface moved to `153` Zig methods (from `126`) while preserving Lightpanda-only browser policy and green validation gates.
  - Added dispatcher contract tests for new edge methods and memory flows.
  - Method-set parity is now tracked and enforced against both latest upstream release baselines:
    - Go release baseline (`adybag14-cyber/openclaw-go-port`): `134/134` covered in Zig.
    - Original OpenClaw release baseline (`openclaw/openclaw`): `94/94` covered in Zig.
    - Union baseline coverage: `135/135` covered in Zig.
    - Intentional Zig-only extras retained for edge/runtime depth: `18`.
  - Hardened smoke scripts to avoid flaky `zig build run` startup timing by prebuilding and launching the binary directly (`zig-out/bin/openclaw-zig.exe`) with explicit readiness and exit diagnostics.
- Toolchain/runtime notes (local Windows Zig master):
  - Codeberg `master` is currently `ce32003625566dcc3687e9e32be411ccb83a4aaa`.
  - Local Zig toolchain remains `0.16.0-dev.2703+0a412853a` (hash `0a412853a`) and is behind current Codeberg `master` (acknowledged).
  - Added Windows build workaround in `build.zig`:
    - use `-fstrip` for executable to avoid missing `.pdb` install failure on this master toolchain.
    - route `zig build test` through `zig test src/main.zig` on Windows to avoid build-runner `--listen` regression.
  - Extended local cross-target diagnostics to include Android targets:
    - Script: `scripts/zig-cross-target-matrix.ps1`
    - Current local result: pass on `x86_64-windows`, `x86_64-linux`, `x86_64-macos`, `x86_64-linux-android`; fail on `aarch64-linux`, `aarch64-macos`, `aarch64-linux-android`, `arm-linux-androideabi`.
    - Failing targets reproduce in minimal `build-exe` runs and point to local Zig Windows toolchain issues (`compiler_rt` / memory-allocation failure class), not project code regressions.
  - Android ARMv7 CI linker fix:
    - root cause in CI was `ld.lld: undefined symbol: __tls_get_addr` on `arm-linux-androideabi`.
    - mitigation shipped in `build.zig`: force `single_threaded` for Android arm target to avoid TLS runtime linkage path.
- Phase 7 complete:
  - built `ReleaseFast` artifacts for `x86_64-windows`, `x86_64-linux`, and `x86_64-macos`
  - generated `SHA256SUMS.txt` for release zips
  - published GitHub preview release `v0.1.0-zig-preview.1`:
    - https://github.com/adybag14-cyber/openclaw-zig-port/releases/tag/v0.1.0-zig-preview.1
  - target note: `aarch64-linux` and `aarch64-macos` failed on the local Windows Zig master toolchain (`0.16.0-dev.2703+0a412853a`) with compiler exit code `5`, so the preview matrix was constrained to passing x86_64 targets.
- Post-release hardening:
  - added `scripts/release-preview.ps1` to automate deterministic preview artifact creation, checksum generation, and optional `gh release create` publishing.
  - added a registry-wide dispatcher coverage test to assert every method in `registry.supported_methods` is actually dispatchable (no `-32601` method-not-found drift).
  - added GitHub Actions workflow `.github/workflows/zig-ci.yml` to continuously run Zig master build/test and cross-target release build attempts.
  - expanded CI cross-target coverage with Android targets (`x86_64-linux-android`, `aarch64-linux-android`, and `arm-linux-androideabi` required).
  - added `scripts/zig-arm64-diagnose.ps1` to collect reproducible arm64 failure logs (`stdout`/`stderr`) for local Windows toolchain triage.
  - added `scripts/zig-cross-target-matrix.ps1` to capture full desktop + Android compile matrix logs with JSON summary output.
  - arm64 diagnostics now confirm a local toolchain failure class on this Windows Zig build (reproducible on minimal source): `compiler_rt` sub-compilation failure + `memory allocation failure`, with additional `invalid constraint: 'X'` for `aarch64-linux`.
  - CI run `22645119953` validated that `aarch64-linux` and `aarch64-macos` cross-builds succeed on Ubuntu runners with Zig master, isolating the arm64 issue to the local Windows toolchain path.
  - added release automation workflow `.github/workflows/release-preview.yml` so preview tags can be built + published from Linux runners with full `x86_64` + `aarch64` target coverage.
  - expanded release preview matrix with Android artifacts: required `x86_64-android`, `aarch64-android`, and `armv7-android`.
  - CI evidence update: run `22651999994` validated all Android cross-target jobs passed after ARMv7 TLS-link fix.
  - release workflow smoke run `22645353103` succeeded and published `v0.1.0-zig-preview.ci-smoke` with `x86_64-windows`, `x86_64-linux`, `x86_64-macos`, `aarch64-linux`, `aarch64-macos`, and `SHA256SUMS.txt`.
  - upgraded `scripts/check-go-method-parity.ps1` into a dual-baseline parity gate and wired it into both CI workflows, enforcing that every method in:
    - latest Go release baseline, and
    - latest original OpenClaw release baseline
    is present in Zig before merge/release.
  - release workflow now runs an explicit `validate` job (parity + `zig build` + `zig build test`) before matrix artifact builds, and fails early if the requested release tag already exists.
  - parity gate now writes a JSON audit payload (`parity-go-zig.json`) and CI/release flows publish it as traceable parity evidence.
  - release workflow smoke run `22646343174` validated parity evidence publication in release assets (`parity-go-zig.json`) for tag `v0.1.0-zig-preview.ci-parityjson`.
  - parity gate now also writes markdown evidence (`parity-go-zig.md`) for human review, and both CI + release flows publish JSON + markdown together.
  - release workflow smoke run `22646648616` validated dual parity evidence publication (`parity-go-zig.json`, `parity-go-zig.md`) for tag `v0.1.0-zig-preview.ci-paritymd`.
  - added cross-platform runtime smoke script (`scripts/runtime-smoke-check.ps1`) and made it a required gate in `zig-ci` validate job (server boot + health + rpc + auth + telegram reply loop simulation).
  - added update lifecycle smoke script (`scripts/update-lifecycle-smoke-check.ps1`) and made it a required gate in both `zig-ci` and `release-preview` validate jobs (`update.plan`, `update.run`, `update.status` lifecycle checks).
  - added system maintenance smoke script (`scripts/system-maintenance-smoke-check.ps1`) and made it a required gate in both `zig-ci` and `release-preview` validate jobs (`system.maintenance.plan`, `system.maintenance.run`, `system.maintenance.status` lifecycle checks).
  - added bare-metal runtime profile (`src/baremetal_main.zig`) and build target (`zig build baremetal`) plus smoke gate (`scripts/baremetal-smoke-check.ps1`) in both `zig-ci` and `release-preview` validate jobs.
  - release-preview packaging now ships the freestanding image artifact (`openclaw-zig-<version>-x86_64-freestanding-none.elf`) alongside desktop/android zips + checksums.
  - bare-metal runtime now embeds Multiboot2 header and smoke gate checks ELF magic + Multiboot2 magic bytes to reduce boot-regression risk.
  - bare-metal smoke gate now parses ELF section/symbol tables to enforce `.multiboot` section presence and required runtime exports (`_start`, `oc_tick`, `oc_status_ptr`, `multiboot2_header`).
  - bare-metal smoke gate now enforces full Multiboot2 header invariants (field values + checksum + end-tag contract), reducing false-positive magic-only matches.
