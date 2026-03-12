# FS1-FS5 Strict Analysis Report

Date: 2026-03-12

## Baseline

- Local source of truth repo: `C:\Users\Ady\Documents\openclaw-zig-port`
- Local head at initial analysis start: `c50ba7e` `feat(zig-port): add interrupt-timeout clamp wrapper probes`
- Working tree at analysis start: clean
- Latest verified CI baseline at analysis start:
  - `zig-ci` `22996158098` -> success
  - `docs-pages` `22996158073` -> success
- Latest upstream baselines verified from GitHub on 2026-03-12:
  - stable: `v2026.3.11`
  - beta: `v2026.3.11-beta.1`
  - Go baseline: `v2.14.0-go`
- Current parity fact from `scripts/check-go-method-parity.ps1`:
  - missing in Zig vs union baseline: `0`
  - initial hard method gap (`node.pending.drain`, `node.pending.enqueue`) is now closed locally

## Strict Refresh

This report has been refreshed after the first strict FS1 slice landed.

- `node.pending.enqueue` and `node.pending.drain` are now implemented in the local source of truth.
- current local validation is green:
  - `zig build test --summary all` -> hosted `205/205`
  - bare-metal host tests -> `116/116`
- current local parity gate is green:
  - Go baseline `v2.14.0-go`
  - stable baseline `v2026.3.11`
  - beta baseline `v2026.3.11-beta.1`
- the strict execution order now advances from FS1 to FS4.

This report is based on the current local repo and directly inspected upstream contracts. Stale streamed summaries, guessed percentages, and unverified reviewer claims are not accepted as evidence.

## Non-Negotiable Working Rules

1. Local repo state is the primary source of truth for Zig implementation status.
2. Upstream stable and beta contracts are the primary source of truth for parity targets.
3. No phase may be marked complete while:
   - its checklist item is unchecked,
   - a hard method gap still exists,
   - a required smoke or CI gate is missing,
   - or its behavior is only implied rather than directly tested.
4. No new work proceeds on a dependent subsystem when a blocking prerequisite is still undefined.
5. Every claimed completion must be backed by:
   - code,
   - tests,
   - docs/tracking updates,
   - local validation,
   - pushed commit,
   - green `zig-ci` and `docs-pages`.

## Dependency Rules

| Phase | Depends On | Blocks | Strict Rule |
| --- | --- | --- | --- |
| FS1 Runtime/core consolidation | Foundation, protocol, dispatcher | FS2, FS3, FS4, FS5 | If runtime state, queueing, or method registry is incomplete, dependent feature work is not considered reliable. |
| FS2 Provider + channel completion | FS1, FS4 secret/auth posture | FS3 context-injection proofs, FS5 real remote execution proofs | Any provider or channel proof that depends on auth, secrets, filesystem, or network must use the stabilized FS1/FS4 surfaces first. |
| FS3 Memory/knowledge depth | FS1 persistence/runtime surfaces, FS2 injection surfaces | FS5 memory-fed training and browser/channel recall proofs | Memory is not complete until persistence, recall, and consumer injection are all validated end to end. |
| FS4 Security + trust hardening | FS1 runtime/config surfaces | FS2 live auth/provider proofs, FS5 wasm/trust/marketplace proofs | Security gates must be defined before trusting networked providers, secrets, or wasm execution. |
| FS5 Edge/WASM/marketplace depth | FS1 runtime/filesystem/exec, FS4 trust policy, FS2 network/provider proofs where applicable | Full-stack cutover | If a test requires download, install, filesystem persistence, or network fetch, the supporting FS1/FS4/FS2 gates must already pass. |

FS6 bare metal remains active, but FS1-FS5 completion must no longer be deferred behind additional FS6 wrapper work. If a hosted phase needs a bare-metal prerequisite for a specific proof path, that dependency must be stated explicitly before the test is run.

## Current Phase Status

### FS1 - Runtime/core consolidation

#### Already implemented

- runtime state persistence and restart replay in `src/runtime/state.zig`
- tool runtime snapshot surface in `src/runtime/tool_runtime.zig`
- compat runtime/control-plane persistence in `src/gateway/dispatcher.zig`
- runtime persistence posture surfaced in `security.audit` and `doctor`
- partial-remediation reporting in `security.audit --fix` and `system.maintenance.run`
- leased-job replay and runtime recovery visibility
- status and identity diagnostics parity slices

#### Confirmed current status

1. The initial strict FS1 hard gap is closed:
   - `node.pending.enqueue`
   - `node.pending.drain`
2. Current Zig registry now exposes:
   - `node.pending.pull`
   - `node.pending.ack`
   - `node.pending.enqueue`
   - `node.pending.drain`
3. Current Zig compat state now exposes the upstream-style pending-work contract:
   - item `type`
   - item `priority`
   - item `createdAtMs`
   - item `expiresAtMs`
   - `revision`
   - `hasMore`
   - baseline synthetic status item
4. `docs/rpc-reference.md` is updated for this area.
5. The remaining FS1 question is no longer missing runtime behavior; it is whether the latest pushed head carrying the strict slice is green and tracked. Once that is true, FS1 is closed and the active strict phase is FS4.

#### Upstream contract locked for implementation

Verified from upstream `openclaw/openclaw@v2026.3.11`:

- file: `src/gateway/node-pending-work.ts`
- file: `src/gateway/node-pending-work.test.ts`
- file: `src/gateway/server-methods/nodes-pending.ts`
- file: `src/gateway/server-methods/nodes-pending.test.ts`

Observed required semantics:

- supported types:
  - `status.request`
  - `location.request`
- supported priorities:
  - `default`
  - `normal`
  - `high`
- enqueue rules:
  - `nodeId` required
  - dedupe explicit items by `type`
  - return `revision`, `item`, and `deduped`
  - `expiresInMs` is clamped to at least `1000` when provided
- drain rules:
  - default `maxItems = 4`
  - hard max `10`
  - default baseline item:
    - `id = "baseline-status"`
    - `type = "status.request"`
    - `priority = "default"`
    - `expiresAtMs = null`
  - baseline is included when no explicit `status.request` exists and there is room in the window
  - `hasMore` must remain true when the baseline item is deferred by `maxItems`
  - drain-only nodes must not allocate persistent node state
- ack rules:
  - baseline id is ignored
  - only explicit items are removed
  - revision increments only when real items are removed

#### Strict FS1 success gates

FS1 is not complete until all of the following are true:

1. `node.pending.enqueue` and `node.pending.drain` are in `src/gateway/registry.zig`.
2. `docs/rpc-reference.md` includes both methods.
3. Dispatcher implements upstream request/response shapes without stubs.
4. Local tests prove:
   - baseline item on empty drain
   - dedupe by type
   - `hasMore` when baseline is deferred
   - no drain-only state allocation
   - ack interaction with queued items and ignored baseline id
5. `scripts/check-go-method-parity.ps1` reports zero missing methods against:
   - Go baseline
   - stable baseline
   - beta baseline
6. `zig build test --summary all` is green.
7. `zig-ci` and `docs-pages` are green on the pushed head.

### FS2 - Provider + channel completion

#### Already implemented

- web login lifecycle:
  - `web.login.start`
  - `web.login.wait`
  - `web.login.complete`
  - `web.login.status`
- OAuth/browser auth catalog:
  - `auth.oauth.providers`
  - `auth.oauth.start`
  - `auth.oauth.wait`
  - `auth.oauth.complete`
  - `auth.oauth.logout`
  - `auth.oauth.import`
- browser bridge:
  - `browser.request`
  - `browser.open`
  - Lightpanda policy and direct-provider support
- Telegram channel:
  - `channels.telegram.webhook.receive`
  - `channels.telegram.bot.send`
  - rich `/auth`, `/model`, `/tts`, typing, chunking, reply loop logic
- existing smoke references in checklist:
  - `scripts/web-login-smoke-check.ps1`
  - `scripts/telegram-reply-loop-smoke-check.ps1`

#### Confirmed work still needed for strict completion

1. The phase has many shipped slices, but it does not yet have a single strict provider/channel completion matrix recorded as a hard gate.
2. The repo does not yet define a phase-complete evidence set for:
   - browser session auth success
   - browser completion success
   - direct-provider completion success
   - Telegram command loop success
   - Telegram non-command reply success
   - typing/chunking success
   - failure telemetry correctness
3. FS2 depends on FS1 and FS4 for trustworthy auth, secret resolution, and runtime state handling. Without those locked, provider/channel closure is not defensible.

#### Strict FS2 success gates

FS2 is not complete until all of the following are true:

1. The auth/browser/Telegram method set is fully implemented and documented.
2. A strict provider/channel matrix exists in docs and includes pass/fail criteria for:
   - ChatGPT/browser session
   - direct provider OpenAI-compatible path
   - OpenRouter
   - OpenCode
   - Telegram webhook receive
   - Telegram bot send
3. Smoke proofs exist and pass for the selected supported matrix.
4. Secrets/auth dependency rules are satisfied:
   - required credentials resolved through the supported secret/config path
   - unsupported/unauthorized cases produce deterministic telemetry
5. End-to-end proofs are recorded for at least one real completion path and one real Telegram reply path.
6. `zig-ci` and `docs-pages` are green on the pushed head.

### FS3 - Memory/knowledge depth

#### Already implemented

- persistent memory store in `src/memory/store.zig`
- `sessions.history`, `chat.history`, `doctor.memory.status`
- retention-cap enforcement on load/replay
- `next_id` recovery from persisted entries
- semantic recall:
  - `semanticRecall`
- graph recall:
  - `graphNeighbors`
- synthesis:
  - `recallSynthesis`
- runtime retention config:
  - `runtime.memory_max_entries`
- browser and Telegram memory-context injection surfaces already exist

#### Confirmed work still needed for strict completion

1. There is real memory depth, but no strict FS3 closure matrix tying storage, recovery, recall, and consumer injection together as one completion gate.
2. The repo does not yet define phase-complete evidence for:
   - persistence across restart
   - semantic recall ranking
   - graph-neighbor recall
   - synthesis payload quality
   - browser completion memory injection
   - Telegram reply memory injection
3. Memory-fed downstream features in FS5 should not be called complete until the consumer side is proven against the persisted store, not only unit tests.

#### Strict FS3 success gates

FS3 is not complete until all of the following are true:

1. Memory persistence/recovery tests pass.
2. Semantic recall, graph recall, and synthesis tests pass.
3. `doctor.memory.status` exposes consistent stats after restart.
4. At least one browser completion and one Telegram reply path prove memory-context consumption from persisted state.
5. Retention-cap and unlimited-retention modes are both tested and documented.
6. `zig-ci` and `docs-pages` are green on the pushed head.

### FS4 - Security + trust hardening

#### Already implemented

- guard pipeline in `src/security/guard.zig`
- loop guard in `src/security/loop_guard.zig`
- `security.audit`
- `doctor`
- gateway token/rate-limit posture reporting
- config fingerprinting
- non-loopback bind token enforcement
- secure secret storage abstraction in `src/security/secret_store.zig`
- `secrets.store.*` and `secrets.resolve`

#### Latest delivered slice

- `secrets.store.status` now reports backend truth explicitly instead of leaving native-provider posture implicit.
- backend support is now machine-readable:
  - `requestedRecognized`
  - `requestedSupport`
  - `fallbackApplied`
  - `fallbackReason`
- current runtime classification:
  - `env` -> `implemented`
  - `file|encrypted-file` -> `implemented`
  - `dpapi|keychain|keystore` -> `fallback-only`
  - `auto` -> `fallback-only`
  - unknown backend -> `unsupported`
- direct secret-store tests and dispatcher coverage now lock those semantics.

#### Confirmed work still needed for strict completion

1. The local code clearly implements encrypted-file-backed secret storage, but native OS secret backend completion is not established by the current audited evidence.
2. The repo does not currently define a strict backend proof matrix for:
   - env
   - encrypted-file
   - native provider path, if supported
3. Security phase closure also requires explicit proof that its findings/remediation outputs are stable under the active config matrix, not just unit-tested in one posture.
4. FS4 must be explicitly signed off before FS2 live-provider or FS5 WASM trust claims are treated as complete.

#### Strict FS4 success gates

FS4 is not complete until all of the following are true:

1. `security.audit`, `doctor`, and secret-store methods are fully documented.
2. Secret-store backend support is explicitly documented as:
   - implemented,
   - fallback-only,
   - or unsupported
   with no ambiguous claims.
3. Gateway auth and rate-limit posture checks are validated under both safe and unsafe configs.
4. `security.audit --fix` behavior is tested for:
   - auto-remediation
   - partial remediation
   - manual blocker reporting
5. `zig-ci` and `docs-pages` are green on the pushed head.

### FS5 - Edge/WASM/marketplace depth

#### Already implemented

- edge/WASM methods in `src/gateway/dispatcher.zig`:
  - `edge.wasm.marketplace.list`
  - `edge.wasm.install`
  - `edge.wasm.execute`
  - `edge.wasm.remove`
- additional edge surfaces:
  - `edge.enclave.status`
  - `edge.enclave.prove`
  - `edge.mesh.status`
  - `edge.homomorphic.compute`
  - `edge.finetune.status`
  - `edge.finetune.run`
  - `edge.finetune.job.get`
  - `edge.finetune.cancel`
  - `edge.marketplace.revenue.preview`
  - `edge.finetune.cluster.plan`
- trust policy and capability gating already present for wasm install/execute
- non-dry-run finetune path already exists and requires `OPENCLAW_ZIG_LORA_TRAINER_BIN`

#### Confirmed work still needed for strict completion

1. FS5 has large handler coverage, but phase-complete end-to-end gates are not defined.
2. Strict closure still requires explicit proof of:
   - trusted install lifecycle
   - execution denial on disallowed host hooks
   - successful execution on allowed hooks
   - finetune job lifecycle
   - cancel/job-get consistency
   - marketplace/trust metadata invariants
3. Any edge test that requires network download, filesystem persistence, or exec/trainer launch must first satisfy the relevant FS1 and FS4 prerequisites.

#### Strict FS5 success gates

FS5 is not complete until all of the following are true:

1. The advertised edge/WASM/marketplace methods are fully documented.
2. WASM lifecycle is proven end to end:
   - list
   - install
   - execute allow
   - execute deny
   - remove
3. Finetune lifecycle is proven end to end:
   - run
   - status
   - job.get
   - cancel
4. Trust metadata and failure modes are deterministic and tested.
5. Any network/filesystem/exec dependencies used by these proofs are already passing their prerequisite FS gates.
6. `zig-ci` and `docs-pages` are green on the pushed head.

## Execution Order

Strict execution order from the current repo state:

1. FS1
2. FS4
3. FS2
4. FS3
5. FS5

Rationale:

- FS1 is the current hard parity blocker.
- FS4 hardens secrets/trust/auth posture before more live provider and edge proofs.
- FS2 depends on FS1 and FS4 to be trustworthy.
- FS3 depends on stable FS1 persistence and FS2 consumer surfaces.
- FS5 depends on FS1 runtime/filesystem/exec and FS4 trust policy; some FS5 proofs may also depend on FS2 network/provider paths.

## Immediate FS1 Slice

This report originally froze the first implementation target:

- add `node.pending.enqueue`
- add `node.pending.drain`

That slice's acceptance criteria are now satisfied locally:

1. `src/gateway/registry.zig` includes both methods.
2. `src/gateway/dispatcher.zig` implements both methods using the upstream contract locked above.
3. Existing `node.pending.pull` and `node.pending.ack` behavior is not regressed for current Zig/Go compatibility callers.
4. `docs/rpc-reference.md` includes both methods.
5. New tests prove:
   - baseline drain
   - dedupe by type
   - baseline deferral `hasMore`
   - no-state drain-only node
   - ack removes explicit items and ignores baseline id
6. `scripts/check-go-method-parity.ps1` reports zero missing methods against the current stable/beta baselines.

## Required Validation Commands

For every FS1-FS5 slice:

```powershell
zig fmt src\\gateway\\dispatcher.zig src\\gateway\\registry.zig
zig build test --summary all
powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\check-go-method-parity.ps1 -OutputJsonPath .\\release\\parity-go-zig.json
powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\docs-status-check.ps1 -ParityJsonPath .\\release\\parity-go-zig.json
```

Additional FS2/FS5 smoke gates are required when those phases are active:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\web-login-smoke-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\\scripts\\telegram-reply-loop-smoke-check.ps1
```

GitHub verification after push:

```powershell
gh run list -L 6 --json databaseId,headSha,status,conclusion,name,workflowName,displayTitle
```

## Decision

No blind FS6 continuation is justified until the missing FS1 parity slice is implemented and the FS1-FS5 execution order above is reflected in tracking artifacts.
