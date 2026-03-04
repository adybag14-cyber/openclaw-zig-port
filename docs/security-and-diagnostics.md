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
