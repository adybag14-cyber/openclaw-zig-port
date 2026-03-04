# OpenClaw Zig Port

Zig runtime port of OpenClaw with parity-first delivery, deterministic validation gates, and Lightpanda-only browser bridge policy.

## Current Status

- RPC method surface in Zig: `153`
- Latest parity gate (tri-baseline):
  - Go baseline (`v2.14.0-go`): `134/134` covered
  - Original OpenClaw baseline (`v2026.3.2`): `94/94` covered
  - Original OpenClaw beta baseline (`v2026.3.2-beta.1`): `94/94` covered
  - Union baseline: `135/135` covered (`MISSING_IN_ZIG=0`)
  - Gateway events: stable `19/19`, beta `19/19`, union `19/19` (`UNION_EVENTS_MISSING_IN_ZIG=0`)
- Latest local validation: `zig build test --summary all` -> `95/95` passing
- Latest edge release tag: `v0.2.0-zig-edge.18`
- Dual runtime profiles available:
  - OS-hosted profile: `openclaw-zig` (`--serve`, doctor, security audit, full RPC stack)
- Bare-metal profile: `openclaw-zig-baremetal.elf` (`zig build baremetal`, freestanding runtime loop + Multiboot2 header)
  - smoke gate validates ELF class/endianness, Multiboot2 location/alignment, `.multiboot` section, and required exported symbols
  - smoke gate also validates Multiboot2 header field contract and checksum
  - optional QEMU boot smoke path available via `zig build baremetal -Dbaremetal-qemu-smoke=true` and `scripts/baremetal-qemu-smoke-check.ps1` (auto-skips when QEMU is unavailable)
  - bare-metal ABI now includes exported kernel info + command mailbox hooks (`oc_kernel_info_ptr`, `oc_command_ptr`, `oc_submit_command`, `oc_tick_n`)
  - bare-metal boot diagnostics ABI now exported with phase/command/tick telemetry and stack snapshot helpers (`oc_boot_diag_ptr`, `oc_boot_diag_capture_stack`)
  - bare-metal command history ABI now exported for mailbox execution tracing (`oc_command_history_capacity`, `oc_command_history_len`, `oc_command_history_event`, `oc_command_history_clear`)
  - command mailbox interrupt controls are available (`trigger_interrupt`, `trigger_exception`, `reset_interrupt_counters`, `reset_exception_counters`, `reset_vector_counters`, `clear_interrupt_history`, `clear_exception_history`, `reinit_descriptor_tables`)
  - x86 bootstrap exports now include descriptor table pointers, load telemetry, interrupt telemetry, exception/fault counters, vector counters, and bounded interrupt/exception history rings (`oc_gdtr_ptr`, `oc_idtr_ptr`, `oc_gdt_ptr`, `oc_idt_ptr`, `oc_descriptor_tables_loaded`, `oc_descriptor_load_attempt_count`, `oc_descriptor_load_success_count`, `oc_try_load_descriptor_tables`, `oc_interrupt_count`, `oc_last_interrupt_vector`, `oc_interrupt_vector_count`, `oc_exception_vector_count`, `oc_last_exception_vector`, `oc_exception_count`, `oc_last_exception_code`, `oc_interrupt_history_capacity`, `oc_interrupt_history_len`, `oc_interrupt_history_event`, `oc_interrupt_history_clear`, `oc_exception_history_capacity`, `oc_exception_history_len`, `oc_exception_history_event`, `oc_exception_history_clear`, `oc_descriptor_init_count`, `oc_interrupt_state_ptr`)
- Recent optimization slices (2026-03-04):
  - memory/runtime/channel queue compaction and retention hardening
  - diagnostics docker probe caching
  - registry lookup hot-path optimization
  - dispatcher bounded-history one-pass compaction
  - browser completion execution telemetry hardening (`bridgeCompletion` failure/success semantics)
  - runtime policy hardening:
    - configurable filesystem sandbox for `file.read` / `file.write` (`OPENCLAW_ZIG_RUNTIME_FILE_SANDBOX_ENABLED`, `OPENCLAW_ZIG_RUNTIME_FILE_ALLOWED_ROOTS`)
    - configurable `exec.run` gate + allowlist (`OPENCLAW_ZIG_RUNTIME_EXEC_ENABLED`, `OPENCLAW_ZIG_RUNTIME_EXEC_ALLOWLIST`)
- Next-generation update/release slice:
  - channel-aware update lifecycle (`update.plan`, `update.status`, `update.run`)
  - npm client package and release pipeline (`@adybag14-cyber/openclaw-zig-rpc-client`)
  - Python client package + PyPI/uvx release pipeline (`openclaw-zig-rpc-client`)

## Scope and Policy

- Preserve JSON-RPC contract compatibility while porting runtime behavior to Zig.
- Keep security, browser/auth, Telegram, memory, and edge flows fully stateful (no placeholder stubs for advertised methods).
- Browser bridge policy in Zig is **Lightpanda-only**; Playwright/Puppeteer are rejected in runtime dispatch contracts.
- Push each completed parity slice to `main`; release tags only after parity + validation gates are green for the release cut.

## Baselines

- Historical bootstrap commit: Go baseline `65c974b528e2` (`v2.10.2-go` line)
- Active parity baselines are resolved by gate script:
  - `adybag14-cyber/openclaw-go-port`
  - `openclaw/openclaw` latest stable release
  - `openclaw/openclaw` latest prerelease (beta)

## Tracking

- Plan: [`docs/zig-port/PORT_PLAN.md`](docs/zig-port/PORT_PLAN.md)
- Checklist: [`docs/zig-port/PHASE_CHECKLIST.md`](docs/zig-port/PHASE_CHECKLIST.md)
- Local Zig toolchain notes: [`docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md`](docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md)
- GitHub master tracking issue: <https://github.com/adybag14-cyber/openclaw-zig-port/issues/1>
- Full method registry (source of truth): [`src/gateway/registry.zig`](src/gateway/registry.zig)
- GitHub Pages docs site (after first deploy): <https://adybag14-cyber.github.io/openclaw-zig-port/>

## Architecture Overview

- Runtime profiles:
  - OS-hosted runtime: full HTTP/RPC gateway and feature surface.
  - Bare-metal runtime: freestanding image exporting lifecycle hooks (`_start`, `oc_tick`, `oc_tick_n`, `oc_status_ptr`) plus command/mailbox ABI (`oc_command_ptr`, `oc_submit_command`, `oc_kernel_info_ptr`), descriptor table/int-vector bootstrap exports, and a Multiboot2 header for bootloader/hypervisor integration.
- Protocol: JSON-RPC request/response envelopes with deterministic error semantics.
- Gateway: HTTP/WebSocket server with `GET /health`, `POST /rpc`, and websocket RPC routes (`GET /ws` + root compatibility on `GET /`), graceful shutdown via RPC.
- Dispatcher: method routing and contract handling across runtime, security, browser/auth, channels, memory, and edge domains.
- Runtime: session/job state, tool runtime actions, compat state surfaces.
- Security: guard, loop-guard, doctor/security audit, remediation (`--fix`) path.
- Browser/Auth: Lightpanda browser request contract + web login session lifecycle.
- Channels: Telegram command/reply queue with auth/model controls and polling.
- Memory: persistent local store with history/trim/delete/compact primitives.
- Edge: wasm lifecycle, routing/acceleration/swarm/multimodal/voice, enclave/mesh/homomorphic/finetune and related advanced contracts.

## Feature Coverage

All major runtime feature domains are implemented and dispatchable. Representative method groups are listed below; full list is in [`registry.zig`](src/gateway/registry.zig).

### 1) Protocol and Gateway

- Connectivity and health:
  - `connect`, `health`, `status`, `shutdown`
- Gateway routes:
  - `GET /health`
  - `POST /rpc`
  - `GET /ws` websocket upgrade route (JSON-RPC over text and binary websocket frames)
  - `GET /` websocket compatibility route for legacy bridge clients
- Contract coverage guard:
  - test asserts every registered method resolves in dispatcher (no registry/dispatcher drift).

### 2) Runtime and Tool Runtime

- Tool execution and filesystem actions:
  - `exec.run`
  - `file.read`
  - `file.write`
- Runtime and session surfaces:
  - `sessions.list`, `sessions.preview`, `session.status`
  - `sessions.patch`, `sessions.resolve`
  - `sessions.history`, `chat.history`
  - `sessions.reset`, `sessions.delete`, `sessions.compact`
  - `sessions.usage`, `sessions.usage.timeseries`, `sessions.usage.logs`
- Queue/runtime telemetry:
  - exposed through status/doctor and channel status snapshots.

### 3) Security and Diagnostics

- Prompt/tool safety layers:
  - risk scoring + loop guard behavior
  - blocked pattern policy checks
- Diagnostics methods:
  - `security.audit`
  - `doctor`
  - `doctor.memory.status`
- CLI diagnostics:
  - `--doctor`
  - `--security-audit --deep`
  - `--security-audit --deep --fix` (remediation actions)
- Secrets/config resolution:
  - `secrets.reload`
  - `secrets.resolve` with config overlay and env alias fallback resolution.

### 4) Browser Bridge and Auth

- Browser runtime policy:
  - Lightpanda-only runtime in dispatcher contracts.
  - Playwright/Puppeteer requests are intentionally rejected.
- Browser and login lifecycle:
  - `browser.request`
  - `browser.open`
  - `web.login.start`
  - `web.login.wait`
  - `web.login.complete`
  - `web.login.status`
- OAuth alias surfaces for compatibility:
  - `auth.oauth.providers`
  - `auth.oauth.start`
  - `auth.oauth.wait`
  - `auth.oauth.complete`
  - `auth.oauth.logout`
  - `auth.oauth.import`
- Provider/auth breadth:
  - `chatgpt`, `codex`, `claude`, `gemini`, `openrouter`, `opencode`
  - guest-capable browser session providers: `qwen`, `zai/glm-5`, `inception/mercury-2`
  - additional provider aliases: `minimax`, `kimi`, `zhipuai`

### 5) Channels and Telegram

- Channel methods:
  - `channels.status`
  - `channels.logout`
  - `send`, `chat.send`, `sessions.send`
  - `poll`
- Telegram command surface:
  - `/auth` lifecycle (`start`, `status`, `wait`, `link`, `open`, `complete`, `guest`, `cancel`, `providers`, `bridge`)
  - `/model` lifecycle (set/status/reset)
  - account-scoped auth bindings and `--force` session rotation
- Queue behavior:
  - bounded retention (`max_queue_entries`, default `4096`)
  - single-pass FIFO compaction on poll/drain paths.

### 6) Memory System

- Persistent memory store:
  - append/history/stats/persistence roundtrip
  - session delete + trim + compact semantics
- Memory-backed runtime methods:
  - `sessions.history`
  - `chat.history`
  - `doctor.memory.status`
- Safety/perf:
  - linear compaction and batched front-removal for bounded retention.

### 7) Edge and Advanced Features

- Wasm lifecycle and marketplace:
  - `edge.wasm.marketplace.list`
  - `edge.wasm.install`
  - `edge.wasm.execute`
  - `edge.wasm.remove`
- Planning and acceleration:
  - `edge.router.plan`
  - `edge.acceleration.status`
  - `edge.swarm.plan`
  - `edge.collaboration.plan`
- Multimodal and voice:
  - `edge.multimodal.inspect`
  - `edge.voice.transcribe`
- Enclave/mesh/homomorphic:
  - `edge.enclave.status`
  - `edge.enclave.prove`
  - `edge.mesh.status`
  - `edge.homomorphic.compute`
- Finetune/self-evolution:
  - `edge.finetune.run`
  - `edge.finetune.status`
  - `edge.finetune.job.get`
  - `edge.finetune.cancel`
  - `edge.finetune.cluster.plan`
- Additional edge parity contracts:
  - `edge.identity.trust.status`
  - `edge.personality.profile`
  - `edge.handoff.plan`
  - `edge.marketplace.revenue.preview`
  - `edge.alignment.evaluate`
  - `edge.quantum.status`

### 8) Operations, Agents, Device/Node, and Compat Surfaces

- Agent and skill surfaces:
  - `agent`, `agent.identity.get`, `agent.wait`
  - `agents.list/create/update/delete`
  - `agents.files.list/get/set`
  - `skills.status/bins/install/update`
- Cron:
  - `cron.list/status/add/update/remove/run/runs`
- Device:
  - `device.pair.list/approve/reject/remove`
  - `device.token.rotate/revoke`
- Node and approval workflow:
  - `node.pair.request/list/approve/reject/verify`
  - `node.rename/list/describe/invoke/invoke.result/event`
  - `node.canvas.capability.refresh`
  - `exec.approvals.get/set`
  - `exec.approvals.node.get/set`
  - `exec.approval.request/waitdecision/resolve`
- Conversation/voice/TTS/system:
  - `talk.config`, `talk.mode`
  - `voicewake.get`, `voicewake.set`
  - `tts.status`, `tts.enable`, `tts.disable`, `tts.providers`, `tts.setProvider`, `tts.convert`
  - `models.list`, `chat.abort`, `chat.inject`
  - `usage.status`, `usage.cost`, `last-heartbeat`, `set-heartbeats`, `system-presence`, `system-event`, `wake`
  - `push.test`, `logs.tail`, `canvas.present`, `update.plan`, `update.status`, `update.run`, `wizard.start/next/cancel/status`

## Performance and Reliability Improvements

Implemented optimization hardening includes:

- memory store linear compaction and batched front-removal
- runtime queue head-offset dequeue + amortized compaction
- Telegram poll one-pass compaction and bounded queue retention
- doctor docker probe cache (process-local)
- registry supports fast-path exact-match lookup
- dispatcher bounded-history one-pass compaction for capped lists

## Known Constraints (Intentional)

- Browser runtime in Zig remains Lightpanda-only by policy.
- Local Windows zig master toolchain can lag Codeberg `master`; freshness is tracked and reported each session.
- Some cross-target failures can be toolchain-specific on local Windows while CI Linux runners pass full cross-target matrices.

## Quick Start

```bash
zig build
zig build run
zig build test
zig build baremetal
```

Run gateway serve mode:

```bash
zig build run -- --serve
```

Core routes:

- `GET /health`
- `POST /rpc`
- `GET /ws`
- `GET /` (websocket compatibility route)
- graceful shutdown via RPC method `shutdown`

## Validation and Diagnostics

Run full local syntax/build checks:

```powershell
./scripts/zig-syntax-check.ps1
```

Install docs dependencies and build docs locally:

```powershell
python -m pip install -r requirements-docs.txt
./scripts/generate-rpc-reference.ps1
mkdocs build --strict
```

Run doctor/security audit from CLI:

```powershell
zig build run -- --doctor
zig build run -- --security-audit --deep
zig build run -- --security-audit --deep --fix
```

Check Zig Codeberg freshness against local toolchain:

```powershell
./scripts/zig-codeberg-master-check.ps1
```

Run parity gate and emit evidence artifacts:

```powershell
./scripts/check-go-method-parity.ps1
./scripts/check-go-method-parity.ps1 -OutputJsonPath .\release\parity-go-zig.json -OutputMarkdownPath .\release\parity-go-zig.md
```

Run smoke checks:

```powershell
./scripts/docker-smoke-check.ps1
./scripts/baremetal-smoke-check.ps1
./scripts/runtime-smoke-check.ps1
./scripts/gateway-auth-smoke-check.ps1
./scripts/websocket-smoke-check.ps1
./scripts/web-login-smoke-check.ps1
./scripts/telegram-reply-loop-smoke-check.ps1
```

Validate npm package publishability:

```powershell
./scripts/npm-pack-check.ps1
```

Validate python package publishability:

```powershell
./scripts/python-pack-check.ps1
```

## CI and Release

`zig-ci` workflow (`.github/workflows/zig-ci.yml`):

- Zig master build/test gates
- tri-baseline method/event parity enforcement (Go latest + original stable latest + original beta latest)
- freestanding bare-metal artifact smoke gate
- runtime smoke gate
- parity evidence artifact publication (`parity-go-zig.json`, `parity-go-zig.md`)

`docs-pages` workflow (`.github/workflows/docs-pages.yml`):

- regenerates and verifies `docs/rpc-reference.md` from `src/gateway/registry.zig`
- builds MkDocs docs (`mkdocs build --strict`)
- publishes docs to GitHub Pages from `site/`
- triggers on `docs/**`, `mkdocs.yml`, and docs workflow changes

`release-preview` workflow (`.github/workflows/release-preview.yml`):

- upfront validate job (build + test + parity)
- freestanding bare-metal smoke validation
- full preview artifact matrix build and publish
- includes bare-metal release artifact: `openclaw-zig-<version>-x86_64-freestanding-none.elf`
- duplicate release tag guard
- release asset parity evidence attachment
- npm package dry-run validation gate in validate stage

`npm-release` workflow (`.github/workflows/npm-release.yml`):

- publishes `@adybag14-cyber/openclaw-zig-rpc-client` to npm
- supports `workflow_dispatch` (manual version + dist-tag) and `release.published`
- uses `NPM_TOKEN` for npmjs publish with provenance when available
- falls back to GitHub Packages publish (`npm.pkg.github.com`) when `NPM_TOKEN` is missing
- always builds and attaches the npm tarball to the matching GitHub release tag when present

`python-release` workflow (`.github/workflows/python-release.yml`):

- builds and validates `openclaw-zig-rpc-client` (unit tests + wheel/sdist + twine check)
- supports `workflow_dispatch` with explicit Python version and optional release tag
- supports `release.published` trigger with release-tag to PEP 440 version normalization
- publishes to PyPI when `PYPI_API_TOKEN` is configured
- always uploads python build artifacts and attaches them to matching GitHub release when found

Manual release-preview trigger:

```powershell
gh workflow run release-preview.yml -R adybag14-cyber/openclaw-zig-port -f version=v0.1.1-zig-preview.2
```

Manual npm release trigger:

```powershell
gh workflow run npm-release.yml -R adybag14-cyber/openclaw-zig-port -f version=v0.2.0-zig-edge -f dist_tag=edge
```

Manual python release trigger:

```powershell
gh workflow run python-release.yml -R adybag14-cyber/openclaw-zig-port -f version=0.2.0.dev14 -f release_tag=v0.2.0-zig-edge.14
```
