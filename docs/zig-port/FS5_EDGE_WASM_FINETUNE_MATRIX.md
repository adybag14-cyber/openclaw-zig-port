# FS5 Edge/WASM/Finetune Matrix

Strict FS5 matrix for the Zig port. This file is the no-guesswork source of truth for `FS5`.

## Scope

- WASM / marketplace lifecycle
- finetune lifecycle
- trust metadata and deterministic failure modes

## Dependency posture

- `FS1` is locally strict-closed, so runtime/filesystem/state prerequisites are satisfied.
- `FS4` is locally strict-closed, so trust-policy and secret-resolution prerequisites are satisfied.
- This matrix does not assume external downloads or real trainer binaries unless the proof explicitly requires them.

## Success gates

| Area | Gate | Proof | Current status |
| --- | --- | --- | --- |
| WASM | marketplace list returns built-ins and zero custom modules on clean state | `scripts/edge-wasm-lifecycle-smoke-check.ps1` | pass |
| WASM | trusted install succeeds with exact SHA256 + HMAC verification | `scripts/edge-wasm-lifecycle-smoke-check.ps1` | pass |
| WASM | post-install marketplace metadata exposes digest + verification mode | `scripts/edge-wasm-lifecycle-smoke-check.ps1` | pass |
| WASM | execute allow succeeds only for permitted host hooks | `scripts/edge-wasm-lifecycle-smoke-check.ps1` | pass |
| WASM | execute deny is deterministic on disallowed host hooks | `scripts/edge-wasm-lifecycle-smoke-check.ps1` | pass |
| WASM | bad signature fails deterministically | `scripts/edge-wasm-lifecycle-smoke-check.ps1` | pass |
| WASM | remove succeeds and execute-after-remove fails deterministically | `scripts/edge-wasm-lifecycle-smoke-check.ps1` | pass |
| Finetune | run | `scripts/edge-finetune-lifecycle-smoke-check.ps1` | pass |
| Finetune | status | `scripts/edge-finetune-lifecycle-smoke-check.ps1` | pass |
| Finetune | job.get | `scripts/edge-finetune-lifecycle-smoke-check.ps1` | pass |
| Finetune | cancel | `scripts/edge-finetune-lifecycle-smoke-check.ps1` | pass |
| Finetune | cancel/job-get consistency | `scripts/edge-finetune-lifecycle-smoke-check.ps1` | pass |

## Current strict status

- The WASM lifecycle strict proof is wired into CI/release and validated.
- The finetune lifecycle strict proof is wired into CI/release and validated.
- FS5 strict closure is now reached locally.

## Required validation

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\edge-wasm-lifecycle-smoke-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\edge-finetune-lifecycle-smoke-check.ps1
zig build test --summary all
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\check-go-method-parity.ps1 -OutputJsonPath .\release\parity-go-zig.json
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\docs-status-check.ps1 -ParityJsonPath .\release\parity-go-zig.json
```
