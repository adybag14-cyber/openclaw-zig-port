# Local Zig Toolchain Setup

This workspace is configured to use a local Zig master toolchain.

## Installed toolchain

- Toolchain root: `C:\users\ady\documents\toolchains\zig-master`
- Active junction: `C:\users\ady\documents\toolchains\zig-master\current`
- Zig binary: `C:\users\ady\documents\toolchains\zig-master\current\zig.exe`
- Zig version: `0.16.0-dev.2682+02142a54d`

## Zig source (latest master commit from Codeberg)

- Source checkout: `C:\users\ady\documents\zig-master-src`
- Remote: `https://codeberg.org/ziglang/zig.git`
- Local checkout commit: `74f361a5ce5212ce321fd0ebfa4c158468a161bb`
- Local commit subject: `std.math.big.int: address log2/log10 reviews`
- Latest remote `master` (Codeberg): `ac24e6caf5a79573f16d2ccc273d907ad2199032`
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
