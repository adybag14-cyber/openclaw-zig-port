# OpenClaw Zig Port Documentation

Full documentation for the OpenClaw Zig runtime port.

## Status Snapshot

- RPC surface in Zig: `153` methods
- Tri-baseline parity gate:
  - Go baseline (`v2.14.0-go`): `134/134`
  - Original OpenClaw baseline (`v2026.3.2`): `94/94`
  - Original OpenClaw beta baseline (`v2026.3.2-beta.1`): `94/94`
  - Union baseline: `135/135` (`MISSING_IN_ZIG=0`)
  - Gateway events union baseline: `19/19` (`UNION_EVENTS_MISSING_IN_ZIG=0`)
- Latest local validation: `87/87` tests passing
- Latest edge release tag: `v0.2.0-zig-edge.14`

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
