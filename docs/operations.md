# Operations

## Current Snapshot

- Latest edge release: `v0.2.0-zig-edge.14`
- Latest local test gate: `zig build test --summary all` -> `79/79` passing
- Latest parity gate: `scripts/check-go-method-parity.ps1` -> `MISSING_IN_ZIG=0`, `ZIG_COUNT=153`

## Local Validation Matrix

Recommended sequence:

```powershell
./scripts/zig-syntax-check.ps1
./scripts/check-go-method-parity.ps1
./scripts/docker-smoke-check.ps1
./scripts/runtime-smoke-check.ps1
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
- parity gate enforcement
- runtime + gateway-auth + websocket smoke checks
- parity evidence artifacts

### `release-preview.yml`

- validate stage before artifact matrix
- duplicate release-tag protection
- preview artifact publishing with parity evidence
- gateway-auth + websocket smoke checks in validate stage
- npm package dry-run validation in release validate stage
- python package validation (unit tests + build + twine check) in release validate stage

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
