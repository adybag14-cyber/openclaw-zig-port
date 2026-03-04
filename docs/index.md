# OpenClaw Zig Port Documentation

Full documentation for the OpenClaw Zig runtime port.

## Status Snapshot

- RPC surface in Zig: `151` methods
- Dual-baseline parity gate:
  - Go baseline (`v2.14.0-go`): `134/134`
  - Original OpenClaw baseline (`v2026.3.2`): `94/94`
  - Union baseline: `135/135` (`MISSING_IN_ZIG=0`)
- Latest local validation: `66/66` tests passing

## Documentation Map

- Getting started and local development workflow
- Architecture and runtime composition
- Full feature coverage by domain
- RPC method family reference
- Security, diagnostics, and remediation model
- Browser/auth integration model (Lightpanda-only)
- Telegram command and polling behavior
- Memory and edge capability surfaces
- CI/release flows and deployment operations
- GitHub Pages publishing workflow

## Project Links

- Repository: <https://github.com/adybag14-cyber/openclaw-zig-port>
- Tracking issue: <https://github.com/adybag14-cyber/openclaw-zig-port/issues/1>
- Method registry source: [`src/gateway/registry.zig`](https://github.com/adybag14-cyber/openclaw-zig-port/blob/main/src/gateway/registry.zig)
