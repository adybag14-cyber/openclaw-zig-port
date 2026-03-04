# Local Zig Toolchain Setup

This workspace is configured to use a local Zig master toolchain.

## Installed toolchain

- Toolchain root: `C:\users\ady\documents\toolchains\zig-master`
- Active junction: `C:\users\ady\documents\toolchains\zig-master\current`
- Zig binary: `C:\users\ady\documents\toolchains\zig-master\current\zig.exe`
- Zig version: `0.16.0-dev.2703+0a412853a`

## Zig source (latest master commit from Codeberg)

- Source checkout: `C:\users\ady\documents\zig-master-src`
- Remote: `https://codeberg.org/ziglang/zig.git`
- Local checkout commit: `2d88a5a10334bddf3bd0b8bc98744ea6f239ce3a`
- Local commit subject: `Merge pull request 'Another dll dependency bites the dust (advapi32.dll)' (#31384) from squeek502/zig:delete-advapi32 into master`
- Latest remote `master` (Codeberg): `ce32003625566dcc3687e9e32be411ccb83a4aaa`
- Current status: local toolchain hash does **not** match latest remote master hash

## Syntax and build check command

From `openclaw-zig-port`:

```powershell
./scripts/zig-syntax-check.ps1
```

This runs:

1. `zig fmt --check`
2. `zig build`
3. `zig build test`
4. `zig build run`

## Master Freshness Check

From `openclaw-zig-port`:

```powershell
./scripts/zig-codeberg-master-check.ps1
```

This reports:
- latest Codeberg `master` commit hash
- local Zig toolchain version/hash
- whether hashes match
