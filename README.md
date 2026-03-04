# OpenClaw Zig Port

Zig runtime port of OpenClaw with parity-first delivery, deterministic validation gates, and Lightpanda-only browser bridge policy.

## Current Status

- RPC method surface in Zig: `151`
- Latest parity gate (dual-baseline):
  - Go baseline (`v2.14.0-go`): `134/134` covered
  - Original OpenClaw baseline (`v2026.3.2`): `94/94` covered
  - Union baseline: `135/135` covered (`MISSING_IN_ZIG=0`)
- Latest local validation: `zig build test --summary all` -> `66/66` passing
- Recent optimization slices (2026-03-04):
  - memory/runtime/channel queue compaction and retention hardening
  - diagnostics docker probe caching
  - registry lookup hot-path optimization
  - dispatcher bounded-history one-pass compaction

## Scope and Policy

- Preserve JSON-RPC contract compatibility while porting runtime behavior to Zig.
- Keep security, browser/auth, Telegram, memory, and edge flows fully stateful (no placeholder stubs for advertised methods).
- Browser bridge policy in Zig is **Lightpanda-only**; Playwright/Puppeteer are rejected in runtime dispatch contracts.
- Push each completed parity slice to `main`; release tags only after parity + validation gates are green for the release cut.

## Baselines

- Historical bootstrap commit: Go baseline `65c974b528e2` (`v2.10.2-go` line)
- Active parity baselines are resolved to latest releases by gate script:
  - `adybag14-cyber/openclaw-go-port`
  - `openclaw/openclaw`

## Tracking

- Plan: [`docs/zig-port/PORT_PLAN.md`](docs/zig-port/PORT_PLAN.md)
- Checklist: [`docs/zig-port/PHASE_CHECKLIST.md`](docs/zig-port/PHASE_CHECKLIST.md)
- Local Zig toolchain notes: [`docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md`](docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md)
- GitHub master tracking issue: <https://github.com/adybag14-cyber/openclaw-zig-port/issues/1>

## Quick Start

```bash
zig build
zig build run
zig build test
```

Run gateway serve mode:

```bash
zig build run -- --serve
```

Core routes:

- `GET /health`
- `POST /rpc`
- graceful shutdown via RPC method `shutdown`

## Validation and Diagnostics

Run full local syntax/build checks:

```powershell
./scripts/zig-syntax-check.ps1
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
./scripts/runtime-smoke-check.ps1
./scripts/web-login-smoke-check.ps1
./scripts/telegram-reply-loop-smoke-check.ps1
```

## CI and Release

`zig-ci` workflow (`.github/workflows/zig-ci.yml`):

- Zig master build/test gates
- dual-baseline parity enforcement
- runtime smoke gate
- parity evidence artifact publication (`parity-go-zig.json`, `parity-go-zig.md`)

`release-preview` workflow (`.github/workflows/release-preview.yml`):

- upfront validate job (build + test + parity)
- full preview artifact matrix build and publish
- duplicate release tag guard
- release asset parity evidence attachment

Manual release-preview trigger:

```powershell
gh workflow run release-preview.yml -R adybag14-cyber/openclaw-zig-port -f version=v0.1.1-zig-preview.2
```
