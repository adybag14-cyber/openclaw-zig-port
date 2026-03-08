# OpenClaw Zig Port Documentation

Full documentation for the OpenClaw Zig runtime port.

## Status Snapshot

- RPC surface in Zig: `170` methods
- Tri-baseline parity gate:
  - Go baseline (`v2.14.0-go`): `134/134`
  - Original OpenClaw baseline (`v2026.3.2`): `94/94`
  - Original OpenClaw beta baseline (`v2026.3.2-beta.1`): `94/94`
  - Union baseline: `135/135` (`MISSING_IN_ZIG=0`)
  - Gateway events union baseline: `19/19` (`UNION_EVENTS_MISSING_IN_ZIG=0`)
- Latest local validation: `203/203` tests passing
- Latest published edge release tag: `v0.2.0-zig-edge.26`
- Recent FS1 progress (2026-03-06):
  - runtime recovery posture surfaced in `status`, `doctor`, `doctor.memory.status`, `agent.identity.get`, and maintenance RPCs
  - `doctor.memory.status` now exports the Go-visible health envelope
  - `agent.identity.get` now exports stable `startedAt` and gateway `authMode`
  - `status` now exports Go-visible summary keys additively

## Documentation Map

- Getting started and local development workflow
- Architecture and runtime composition
- Package publishing, registry configuration, and install fallbacks
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
- Package publishing guide: [package-publishing.md](package-publishing.md)
- Method registry source: [`src/gateway/registry.zig`](https://github.com/adybag14-cyber/openclaw-zig-port/blob/main/src/gateway/registry.zig)
