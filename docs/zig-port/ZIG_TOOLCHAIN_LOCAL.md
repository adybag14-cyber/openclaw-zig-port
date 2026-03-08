# Local Zig Toolchain Setup

This workspace uses a local Zig `master` toolchain with an explicit mirror-aware refresh policy.

## Canonical Source vs Distribution Mirror

- Canonical upstream source of truth: `https://codeberg.org/ziglang/zig.git`
- Windows release/distribution mirror: `https://github.com/adybag14-cyber/zig`
- Mirror release modes:
  - `latest-master`: rolling Windows refresh lane
  - `upstream-<sha>`: immutable reproducible lane for CI, bisects, and release recreation

The Zig OpenClaw port uses Codeberg `master` for freshness decisions, but the GitHub mirror helps by publishing a Windows asset URL, SHA256 digest, and target commitish that can be compared directly against the local toolchain.

## Installed Toolchain Layout

- Toolchain root: `C:\users\ady\documents\toolchains\zig-master`
- Active junction: `C:\users\ady\documents\toolchains\zig-master\current`
- Default Zig binary: `C:\users\ady\documents\toolchains\zig-master\current\zig.exe`

## Current Snapshot

- Local Zig version: `0.16.0-dev.2703+0a412853a`
- Current Codeberg `master`: `f16eb18ce8c24ed743aae1faa4980052cb9f4f36`
- Current GitHub mirror `latest-master` target: `f16eb18ce8c24ed743aae1faa4980052cb9f4f36`
- Current GitHub mirror Windows asset digest: `3103b272d64a93a8fdce0ca7f3c8856bf8a33c1d42d745fdbfbec2ca9fb69642`
- Current status: local toolchain hash does **not** match the current Codeberg/mirror target

## Required Checks

From `openclaw-zig-port`:

```powershell
./scripts/zig-codeberg-master-check.ps1
./scripts/zig-github-mirror-release-check.ps1
./scripts/zig-bootstrap-from-github-mirror.ps1 -DryRun
```

`zig-codeberg-master-check.ps1` reports:

- latest Codeberg `master` commit hash
- local Zig toolchain version/hash
- whether the local toolchain matches Codeberg `master`
- GitHub mirror release target commitish
- whether the mirror release matches Codeberg `master`
- Windows asset digest and download URL from the mirror

`zig-github-mirror-release-check.ps1` reports:

- GitHub mirror release tag
- target commitish
- Windows asset name, digest, and URL
- whether the release is rolling or immutable

`zig-bootstrap-from-github-mirror.ps1` supports:

- `-DryRun` to plan a refresh without changing the workstation
- default `latest-master` refresh for fast Windows catch-up
- `-UpstreamSha <sha>` to install from the immutable `upstream-<sha>` release

## Local Validation Command

```powershell
./scripts/zig-syntax-check.ps1
```

This runs:

1. `zig fmt --check`
2. `zig build`
3. `zig build test`
4. `zig build run`
