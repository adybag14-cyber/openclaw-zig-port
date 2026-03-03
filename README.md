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

Run host + Docker smoke/system checks:

```powershell
./scripts/docker-smoke-check.ps1
```

Run web login lifecycle smoke check:

```powershell
./scripts/web-login-smoke-check.ps1
```
