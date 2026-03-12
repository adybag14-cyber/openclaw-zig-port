# Security and Diagnostics

## Security Pipeline

- prompt-risk scoring
- blocked pattern checks
- loop-guard detection for repetitive flows
- policy bundle probing and validation

## Diagnostics Surfaces

- `security.audit`
  - summary and findings
  - optional deep probes
  - optional remediation actions (`fix`)
- `doctor`
  - operational checks
  - embeds audit-derived status
  - includes docker availability check
- `doctor.memory.status`
- `secrets.store.status`
  - explicit secret-backend support classification
  - requested backend vs active backend
  - fallback reason when Zig is not using the requested native provider directly

## Secret Store Backend Matrix

The secret-store contract is explicit about backend support. Zig does not silently pretend native secret providers are complete when they are not.

| Requested backend | Active backend | Support level | Notes |
| --- | --- | --- | --- |
| `env` | `env` | `implemented` | in-memory only, non-persistent |
| `file` / `encrypted-file` | `encrypted-file` | `implemented` | XChaCha20-Poly1305 persisted store |
| `dpapi` | `encrypted-file` | `fallback-only` | native backend not implemented; encrypted-file fallback is used |
| `keychain` | `encrypted-file` | `fallback-only` | native backend not implemented; encrypted-file fallback is used |
| `keystore` | `encrypted-file` | `fallback-only` | native backend not implemented; encrypted-file fallback is used |
| `auto` | `encrypted-file` | `fallback-only` | resolves to encrypted-file while no native backend is implemented |
| unknown backend | `env` | `unsupported` | request is unrecognized; Zig falls back to `env` and reports the reason |

The `secrets.store.status` receipt now makes these states machine-readable through:

- `requestedRecognized`
- `requestedSupport`
- `fallbackApplied`
- `fallbackReason`

## CLI Entry Points

```powershell
zig build run -- --doctor
zig build run -- --security-audit --deep
zig build run -- --security-audit --deep --fix
```

## Remediation Behavior

The fix path can:

- create required security directories/files
- write default policy bundle where missing
- return structured action results and failures

## Performance Notes

- Docker binary availability probe is cached process-locally in doctor/audit paths to avoid repeated process spawn overhead.
