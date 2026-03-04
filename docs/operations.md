# Operations

## Local Validation Matrix

Recommended sequence:

```powershell
./scripts/zig-syntax-check.ps1
./scripts/check-go-method-parity.ps1
./scripts/docker-smoke-check.ps1
./scripts/runtime-smoke-check.ps1
./scripts/web-login-smoke-check.ps1
./scripts/telegram-reply-loop-smoke-check.ps1
```

## CI Workflows

### `zig-ci.yml`

- Zig master build/test gates
- parity gate enforcement
- runtime smoke checks
- parity evidence artifacts

### `release-preview.yml`

- validate stage before artifact matrix
- duplicate release-tag protection
- preview artifact publishing with parity evidence

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
