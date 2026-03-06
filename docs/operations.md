# Operations

## Current Snapshot

- Latest published edge release: `v0.2.0-zig-edge.26`
- Latest local test gate: `zig build test --summary all` -> `202/202` passing
- Latest parity gate: `scripts/check-go-method-parity.ps1` -> `GO_MISSING_IN_ZIG=0`, `ORIGINAL_MISSING_IN_ZIG=0`, `ORIGINAL_BETA_MISSING_IN_ZIG=0`, `UNION_MISSING_IN_ZIG=0`, `UNION_EVENTS_MISSING_IN_ZIG=0`, `ZIG_COUNT=169`, `ZIG_EVENTS_COUNT=19`
- Current head: `ccf905b`
- Latest CI:
  - `zig-ci` `22752747937` -> success
  - `docs-pages` `22752747922` -> success

## Local Validation Matrix

Recommended sequence:

```powershell
./scripts/zig-syntax-check.ps1
./scripts/check-go-method-parity.ps1
./scripts/docs-status-check.ps1 -RefreshParity
./scripts/docker-smoke-check.ps1
./scripts/runtime-smoke-check.ps1
./scripts/baremetal-smoke-check.ps1
./scripts/baremetal-qemu-smoke-check.ps1
./scripts/baremetal-qemu-runtime-oc-tick-check.ps1
./scripts/baremetal-qemu-command-loop-check.ps1
./scripts/appliance-control-plane-smoke-check.ps1
./scripts/appliance-restart-recovery-smoke-check.ps1
./scripts/gateway-auth-smoke-check.ps1
./scripts/websocket-smoke-check.ps1
./scripts/web-login-smoke-check.ps1
./scripts/telegram-reply-loop-smoke-check.ps1
./scripts/npm-pack-check.ps1
./scripts/python-pack-check.ps1
```

## CI Workflows

### `zig-ci.yml`

- Zig master build/test gates
- Zig master freshness snapshot (`scripts/zig-codeberg-master-check.ps1`, Codeberg primary + GitHub mirror fallback)
- parity gate enforcement (Go latest + original stable latest + original beta latest, including gateway event parity)
- docs status drift gate (`scripts/docs-status-check.ps1`)
- runtime + gateway-auth + websocket smoke checks
- appliance control-plane smoke check (`system.boot.*`, `system.rollback.*`, secure-boot update gate)
- appliance restart recovery smoke check (persisted control-plane replay + recovery actionability)
- parity evidence artifacts
  - websocket smoke validates `/ws` and root compatibility route `/`, including binary-frame RPC dispatch
  - gateway-auth and websocket smokes use bounded receive timeouts to prevent hanging CI jobs
  - dispatcher coverage test now fails on both missing methods (`-32601`) and registered-method dispatcher gaps (`-32603` fallback guard)

### `release-preview.yml`

- validate stage before artifact matrix
- duplicate release-tag protection
- preview artifact publishing with parity evidence
- docs status drift gate (`scripts/docs-status-check.ps1`) in validate stage
- zig master freshness snapshot capture + publish (`zig-master-freshness.json`)
- release trust evidence generation and publishing (`release-manifest.json`, `sbom.spdx.json`, `provenance.intoto.json`)
- gateway-auth + websocket smoke checks in validate stage
- appliance control-plane smoke check in validate stage
- appliance restart recovery smoke check in validate stage
- npm package dry-run validation in release validate stage
- python package validation (unit tests + build + twine check) in release validate stage
- local `scripts/release-preview.ps1` mirrors parity/docs/freshness gates before artifact packaging

### `npm-release.yml`

- publishes `@adybag14-cyber/openclaw-zig-rpc-client` to npm
- supports manual version/dist-tag dispatch and release-triggered publish
- uses `NPM_TOKEN` when present for npmjs publish
- falls back to GitHub Packages publish when `NPM_TOKEN` is not configured
- attaches built npm tarball to the matching GitHub release tag when available

### `python-release.yml`

- builds and validates `python/openclaw-zig-rpc-client`
- supports manual dispatch with explicit PEP 440 version
- maps release tags to Python versions for `release.published` trigger
- publishes to PyPI when `PYPI_API_TOKEN` is configured
- uploads and optionally attaches wheel/sdist assets to matching GitHub release tags

## Release Notes

- do not cut release until parity gate is green and validation matrix passes
- include parity artifacts in release output
- keep tracking docs and issue comments updated with validation evidence

## Toolchain Freshness

Run:

```powershell
./scripts/zig-codeberg-master-check.ps1
```

Track local/remote mismatch in:

- `docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md`
