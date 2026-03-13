# FS4 Security and Trust Matrix

This document is the strict source of truth for FS4 security and trust hardening.

Only directly verified local evidence counts:

- runtime implementation in the local Zig repo
- explicit Zig tests
- explicit smoke scripts
- green `zig-ci` and `docs-pages` on the pushed head

Status legend:

- `PASS`: all listed strict pass criteria are satisfied
- `PARTIAL`: implementation exists, but one or more strict pass criteria are still missing
- `FAIL`: required behavior is currently broken

## Dependency Rules

FS4 depends on already-closed hosted prerequisites:

- FS1 runtime/core consolidation

FS4 hardens the surfaces required before treating FS2 and FS5 as trustworthy:

- gateway auth and transport posture
- secret storage and resolution
- audit/doctor diagnostics
- remediation workflows

## Selected Supported Matrix

| Surface | Methods / path | Strict pass criteria | Current evidence | Status | Remaining gap |
| --- | --- | --- | --- | --- | --- |
| Gateway auth enforcement | `/rpc`, `/ws` | unauthorized requests fail and authorized requests succeed under token gate | `scripts/gateway-auth-smoke-check.ps1` | `PASS` | none |
| Safe security posture + secret lifecycle | `doctor`, `security.audit`, `secrets.store.status`, `secrets.store.set`, `secrets.store.get`, `secrets.store.list`, `secrets.resolve`, `secrets.store.delete` | safe doctor posture passes, safe audit summary is empty, encrypted-file backend is explicit, secret store persists across restart, CRUD + resolve succeed | `scripts/security-secret-store-smoke-check.ps1`; dispatcher tests for `secrets.store.*` and `secrets.resolve` | `PASS` | none |
| Maintenance remediation lifecycle | `system.maintenance.plan`, `system.maintenance.run`, `system.maintenance.status` | plan/run/status all return HTTP `200`, dry-run and apply semantics are explicit, partial manual remediation is surfaced honestly | `scripts/system-maintenance-smoke-check.ps1`; dispatcher tests for partial remediation | `PASS` | none |
| Unsafe/invalid gateway posture telemetry | `doctor`, `security.audit` | missing token, disabled rate limit, and invalid thresholds produce deterministic diagnostics | dispatcher tests in `src/gateway/dispatcher.zig` | `PASS` | none |
| Secret backend support classification | `secrets.store.status` | backend is explicitly classified as `implemented`, `fallback-only`, or `unsupported` with fallback reasoning | `src/security/secret_store.zig` tests; `scripts/security-secret-store-smoke-check.ps1` | `PASS` | none |

## Strict FS4 Closure Status

FS4 is locally closed.

What is now closed:

- gateway auth enforcement is smoke-gated
- safe doctor/audit posture is smoke-gated
- persistent encrypted secret-store lifecycle is smoke-gated
- maintenance remediation lifecycle is smoke-gated
- unsafe/invalid posture remains covered by dispatcher tests

## Enforced Local Smoke Commands

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\gateway-auth-smoke-check.ps1 -SkipBuild
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\security-secret-store-smoke-check.ps1 -SkipBuild
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\system-maintenance-smoke-check.ps1 -SkipBuild
```
