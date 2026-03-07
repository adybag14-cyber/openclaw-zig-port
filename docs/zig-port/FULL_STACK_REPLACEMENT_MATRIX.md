# Full-Stack Zig Replacement Matrix

Purpose: lock exact replacement scope and acceptance gates before stable full-stack Zig cutover.

Master tracking:
- Issue: `#1` (master)
- FS0 execution issue: `#2`

## Baseline References (FS0)

| Baseline | Ref Type | Value | Status |
|---|---|---|---|
| OpenClaw Zig Port | Commit | `caaedd9` | Locked |
| OpenClaw Zig Port | Release | `v0.2.0-zig-edge.26` | Locked |
| OpenClaw Go Port | Release/Commit | `v2.14.0-go @ 3614cf457cf26220e486d7f3dc8df09353b38a32` | Locked |
| OpenClaw Rust Port | Release/Commit | `v1.7.15 @ b2abb0d1fa747e371a53ea0890ffd80e4e29ea79` | Locked |
| Original OpenClaw Stable | Release/Commit | `v2026.3.2 @ 85377a28175695c224f6589eb5c1460841ecd65c` | Locked |
| Original OpenClaw Beta | Pre-release/Commit | `v2026.3.2-beta.1 @ eb8a8840d65fd082bdb4712d132fb7d262e24732` | Locked |

## Domain Contract Matrix

Legend:
- Parity policy: `exact`, `compatible`, `additive`
- Gate type: `unit`, `integration`, `smoke`, `ci`, `manual-e2e`

| Domain | Required Surface | Parity Policy | Current Status | Acceptance Gates | Evidence |
|---|---|---|---|---|---|
| Protocol + RPC | Method/event set + envelope semantics | exact | In progress | method parity gate, dispatcher coverage test | `parity-go-zig.json`, CI artifacts |
| Gateway HTTP/WS | `/health`, `/rpc`, `/ws`, stream envelopes | exact | In progress | websocket/gateway smoke, runtime smoke | `scripts/*smoke-check.ps1` |
| Runtime + Tools | sessions/jobs/queue/tool runtime | exact | In progress | runtime tests + integration tests | `zig build test` |
| Security + Diagnostics | guard/loop/policy/doctor/audit/remediation | compatible | In progress | security tests + `security.audit` smoke | CLI + RPC diagnostics outputs |
| Providers + Browser Bridge | Lightpanda auth/completion + provider matrix | compatible | In progress | provider integration tests + manual-e2e | bridge tests + Telegram proofs |
| Telegram + Channels | `/auth` `/model` `/tts` + polling/webhook flow | exact | In progress | telegram reply loop smoke + manual-e2e | smoke output + chat evidence |
| Memory + Recall | persistence/history/vector/graph behaviors | compatible | In progress | memory tests + long-run smoke | memory tests + persistence artifacts |
| Edge + WASM | lifecycle/trust/capabilities/edge contracts | compatible | In progress | wasm/edge tests + parity checks | CI + dispatcher tests |
| Appliance/Bare-metal | boot/runtime progression/control-plane + staged rollout boundary + minimal appliance readiness contract | additive | In progress | bare-metal smoke + qemu smoke + runtime probe + command-loop probe + qemu feature-flags/tick-batch probe + descriptor-bootdiag probe + qemu bootdiag/history-clear probe + descriptor-table-content probe + descriptor-dispatch probe + qemu vector counter reset probe + qemu vector history overflow probe + qemu vector history clear probe + qemu command-health history probe + qemu mode/boot-phase history probe + qemu mode/boot-phase history clear probe + qemu scheduler probe + qemu scheduler priority budget probe + qemu scheduler round robin probe + qemu scheduler timeslice-update probe + qemu scheduler disable-enable probe + qemu scheduler reset probe + qemu scheduler policy-switch probe + qemu scheduler saturation probe + qemu timer wake probe + qemu timer quantum probe + qemu timer cancel probe + qemu timer cancel-task probe + qemu timer pressure probe + qemu periodic timer probe + qemu periodic timer clamp probe + qemu periodic interrupt probe + qemu interrupt timeout probe + qemu interrupt timeout timer probe + qemu interrupt timeout clamp probe + qemu interrupt filter probe + qemu timer-disable interrupt probe + qemu active-task-terminate probe + qemu panic-recovery probe + qemu manual-wait interrupt probe + qemu wake-queue selective probe + qemu wake-queue selective-overflow probe + qemu wake-queue before-tick-overflow probe + qemu wake-queue reason-overflow probe + qemu wake-queue fifo probe + qemu wake-queue summary-age probe + qemu wake-queue overflow probe + qemu wake-queue clear probe + qemu wake-queue batch-pop probe + qemu allocator syscall probe + qemu allocator syscall failure probe + qemu command-result counters probe + qemu reset counters probe + qemu task lifecycle probe + qemu interrupt mask exception probe + qemu interrupt mask profile probe + appliance rollout smoke + appliance readiness smoke | qemu scripts outputs + command-loop output + qemu feature-flags/tick-batch probe output + descriptor-bootdiag probe output + qemu bootdiag/history-clear probe output + descriptor-table-content probe output + descriptor-dispatch probe output + qemu vector counter reset probe output + qemu vector history overflow probe output + qemu vector history clear probe output + qemu command-health history probe output + qemu mode/boot-phase history probe output + qemu mode/boot-phase history clear probe output + qemu scheduler probe output + qemu scheduler priority budget probe output + qemu scheduler round robin probe output + qemu scheduler timeslice-update probe output + qemu scheduler disable-enable probe output + qemu scheduler reset probe output + qemu scheduler policy-switch probe output + qemu scheduler saturation probe output + qemu timer wake probe output + qemu timer quantum probe output + qemu timer cancel probe output + qemu timer cancel-task probe output + qemu timer pressure probe output + qemu periodic timer probe output + qemu periodic timer clamp probe output + qemu periodic interrupt probe output + qemu interrupt timeout probe output + qemu interrupt timeout timer probe output + qemu interrupt timeout clamp probe output + qemu interrupt filter probe output + qemu timer-disable interrupt probe output + qemu active-task-terminate probe output + qemu panic-recovery probe output + qemu manual-wait interrupt probe output + qemu wake-queue selective probe output + qemu wake-queue selective-overflow probe output + qemu wake-queue before-tick-overflow probe output + qemu wake-queue reason-overflow probe output + qemu wake-queue fifo probe output + qemu wake-queue summary-age probe output + qemu wake-queue overflow probe output + qemu wake-queue clear probe output + qemu wake-queue batch-pop probe output + qemu allocator syscall probe output + qemu allocator syscall failure probe output + qemu command-result counters probe output + qemu reset counters probe output + qemu task lifecycle probe output + qemu interrupt mask exception probe output + qemu interrupt mask profile probe output + appliance rollout smoke output + appliance readiness smoke output |
| Ops + Packaging | release matrix, checksums, provenance, docs | exact | In progress | `zig-ci`, `docs-pages`, release-preview dry-run | Actions runs + release assets |

## External Interface Cutover Contract (FS0)

Stable cutover requires no breaking behavior for:
- JSON-RPC methods/events used by existing clients.
- Gateway HTTP and WebSocket transport contracts.
- Telegram command and response behavior.
- CLI diagnostics and security audit surfaces.
- Update lifecycle methods and state transitions.

Any intentional behavior changes must be:
1. documented in migration notes,
2. marked in parity policy (`compatible` or `additive`),
3. backed by explicit tests and rollout rationale.

## Release Gate Mapping

| Gate | Required | Source |
|---|---|---|
| 100% required parity matrix | Yes | parity gate + matrix completion |
| Local validation complete | Yes | `zig build`, `zig build test`, smoke suite |
| CI validation complete | Yes | `zig-ci`, `docs-pages`, release-preview dry run |
| Provider/channel end-to-end proof | Yes | Telegram + provider manual-e2e evidence |
| Migration drill success | Yes | migration playbook dry-run report |
| Stable full-stack tag cut | Blocked until all above are green | release workflow |

## FS0 Checklist

- [x] Fill all `TBD` baseline references with exact tags/SHAs.
- [ ] Finalize parity policy for each domain row.
- [ ] Map each domain row to exact tests/workflows and evidence links.
- [ ] Attach matrix evidence to issue `#2` and roll up to issue `#1`.

