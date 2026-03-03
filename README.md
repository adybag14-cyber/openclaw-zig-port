# OpenClaw Zig Port

Bootstrap repository for the next OpenClaw runtime port in Zig.

## Baseline

- Source baseline repo: `adybag14-cyber/openclaw-go-port`
- Baseline branch: `main`
- Baseline commit: `65c974b528e2` (`v2.10.2-go` line)

## Scope

- Rebuild OpenClaw runtime surfaces in Zig with end-to-end parity against the Go runtime baseline.
- Keep RPC contract compatibility, channel behavior, auth/browser bridge semantics, and release packaging parity.
- Treat this repo as the Zig-only source of truth for the new runtime.
- Browser bridge policy for Zig is Lightpanda-only; Playwright and Puppeteer are intentionally rejected in dispatcher contracts.
- Release policy: push each completed parity slice, but do not cut a release tag until parity is explicitly 100% and Phase 7 gates are green.

## Tracking

- Plan: [`docs/zig-port/PORT_PLAN.md`](docs/zig-port/PORT_PLAN.md)
- Checklist: [`docs/zig-port/PHASE_CHECKLIST.md`](docs/zig-port/PHASE_CHECKLIST.md)
- Local Zig setup: [`docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md`](docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md)

## Initial Milestone

1. Establish build/test scaffolding and protocol contracts in Zig.
2. Land gateway + RPC dispatcher parity core.
3. Port security/runtime/tooling surfaces in vertical slices with tests.
4. Reach release gate and ship `v0.1.0-zig` preview when parity gates pass.

## Zig Bootstrap Commands

```bash
zig build
zig build run
zig build test
```

Run HTTP serve mode:

```bash
zig build run -- --serve
```

Current route surface:
- `GET /health` -> JSON-RPC health payload
- `POST /rpc` -> JSON-RPC dispatcher route
- graceful shutdown via RPC method `shutdown`
- runtime tool actions via RPC:
  - `exec.run`
  - `file.read`
  - `file.write`
  - `web.login.start`
  - `web.login.wait`
  - `web.login.complete`
  - `web.login.status`
  - `channels.status`
  - `send`
  - `poll`
  - `security.audit`
  - `doctor`

Run diagnostics directly from CLI:

```powershell
zig build run -- --doctor
zig build run -- --security-audit --deep
zig build run -- --security-audit --deep --fix
```

Or run the workspace checker with local Zig master:

```powershell
./scripts/zig-syntax-check.ps1
```

Check Codeberg `master` freshness against local toolchain:

```powershell
./scripts/zig-codeberg-master-check.ps1
```

Diagnose arm64 cross-build failures (logs written under `release/arm64-diagnostics`):

```powershell
./scripts/zig-arm64-diagnose.ps1
```

Run Go-to-Zig method parity gate locally:

```powershell
./scripts/check-go-method-parity.ps1
```

Run host + Docker smoke/system checks:

```powershell
./scripts/docker-smoke-check.ps1
```

Run web login lifecycle smoke check:

```powershell
./scripts/web-login-smoke-check.ps1
```

Run Telegram command/reply loop smoke check:

```powershell
./scripts/telegram-reply-loop-smoke-check.ps1
```

Build preview release bundles (and optionally publish to GitHub Releases):

```powershell
./scripts/release-preview.ps1 -Version v0.1.1-zig-preview.2
./scripts/release-preview.ps1 -Version v0.1.1-zig-preview.2 -IncludeArm64
./scripts/release-preview.ps1 -Version v0.1.1-zig-preview.2 -Publish
```

CI workflow:
- `.github/workflows/zig-ci.yml` runs on push/PR with Zig `master`
- validates build/test gates
- enforces Go->Zig method-set parity (`scripts/check-go-method-parity.ps1`)
- attempts cross-target release builds (x86_64-macos required, aarch64-linux/aarch64-macos optional)
- supports manual dispatch (`workflow_dispatch`) for on-demand verification

Automated preview release workflow:
- `.github/workflows/release-preview.yml` builds and publishes full preview artifacts on Linux runners for:
  - `x86_64-windows`
  - `x86_64-linux`
  - `x86_64-macos`
  - `aarch64-linux`
  - `aarch64-macos`
- Trigger with GitHub CLI:

```powershell
gh workflow run release-preview.yml -R adybag14-cyber/openclaw-zig-port -f version=v0.1.1-zig-preview.2
```
