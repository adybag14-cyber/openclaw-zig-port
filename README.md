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

## Tracking

- Plan: [`docs/zig-port/PORT_PLAN.md`](docs/zig-port/PORT_PLAN.md)
- Checklist: [`docs/zig-port/PHASE_CHECKLIST.md`](docs/zig-port/PHASE_CHECKLIST.md)

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
