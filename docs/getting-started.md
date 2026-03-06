# Getting Started

## Prerequisites

- Zig toolchain (master lineage used by this project)
- Git
- PowerShell (for scripts on Windows)
- Docker (recommended for smoke/system checks)

## Bootstrap

```bash
zig build
zig build run
zig build test
zig build baremetal
zig build baremetal -Dbaremetal-qemu-smoke=true
```

Run server mode:

```bash
zig build run -- --serve
```

Core HTTP routes:

- `GET /health`
- `POST /rpc`

## Quick RPC Smoke

```bash
curl -s http://127.0.0.1:8080/rpc \
  -H "content-type: application/json" \
  -d '{"id":"health-1","method":"health","params":{}}'
```

## Validation Scripts

```powershell
./scripts/zig-syntax-check.ps1
./scripts/check-go-method-parity.ps1
./scripts/baremetal-smoke-check.ps1
./scripts/baremetal-qemu-smoke-check.ps1
./scripts/baremetal-qemu-runtime-oc-tick-check.ps1
./scripts/baremetal-qemu-command-loop-check.ps1
./scripts/runtime-smoke-check.ps1
./scripts/appliance-control-plane-smoke-check.ps1
./scripts/appliance-restart-recovery-smoke-check.ps1
./scripts/web-login-smoke-check.ps1
./scripts/telegram-reply-loop-smoke-check.ps1
```

## Local Toolchain Freshness

```powershell
./scripts/zig-codeberg-master-check.ps1
```

Reference: [`docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md`](zig-port/ZIG_TOOLCHAIN_LOCAL.md)
