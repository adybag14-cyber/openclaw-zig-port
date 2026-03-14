# OpenClaw Zig Port Documentation

Full documentation for the OpenClaw Zig runtime port.

## Status Snapshot

- RPC surface in Zig: `175` methods
- Pinned tri-baseline parity gate:
  - Go baseline (`v2.14.0-go`): `134/134`
  - Original OpenClaw baseline (`v2026.3.11`): `99/99`
  - Original OpenClaw beta baseline (`v2026.3.11-beta.1`): `99/99`
  - Union baseline: `140/140` (`MISSING_IN_ZIG=0`)
  - Gateway events union baseline: `19/19` (`UNION_EVENTS_MISSING_IN_ZIG=0`)
- Latest local validation: `263/263` main tests + `192/192` bare-metal host tests passing
- Latest published edge release tag: `v0.2.0-zig-edge.28`
- Toolchain lane: Codeberg `master` is canonical; `adybag14-cyber/zig` provides rolling `latest-master` and immutable `upstream-<sha>` Windows releases for refresh and reproducibility.
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
- Strict FS2 provider/channel matrix
- Strict FS3 memory/knowledge matrix
- Strict FS4 security/trust matrix
- Strict FS5 edge/wasm/finetune matrix
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
- Strict FS2 matrix: [zig-port/FS2_PROVIDER_CHANNEL_MATRIX.md](zig-port/FS2_PROVIDER_CHANNEL_MATRIX.md)
- Strict FS3 matrix: [zig-port/FS3_MEMORY_KNOWLEDGE_MATRIX.md](zig-port/FS3_MEMORY_KNOWLEDGE_MATRIX.md)
- Strict FS4 matrix: [zig-port/FS4_SECURITY_TRUST_MATRIX.md](zig-port/FS4_SECURITY_TRUST_MATRIX.md)
- Strict FS5 matrix: [zig-port/FS5_EDGE_WASM_FINETUNE_MATRIX.md](zig-port/FS5_EDGE_WASM_FINETUNE_MATRIX.md)
- Method registry source: [`src/gateway/registry.zig`](https://github.com/adybag14-cyber/openclaw-zig-port/blob/main/src/gateway/registry.zig)

