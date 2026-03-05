# Full-Stack Zig Replacement Matrix

Purpose: lock exact replacement scope and acceptance gates before stable full-stack Zig cutover.

Master tracking:
- Issue: `#1` (master)
- FS0 execution issue: `#2`

## Baseline References (FS0)

| Baseline | Ref Type | Value | Status |
|---|---|---|---|
| OpenClaw Zig Port | Commit | `caaedd9` | Locked |
| OpenClaw Zig Port | Release | `v0.2.0-zig-edge.25` | Locked |
| OpenClaw Go Port | Release/Commit | `TBD` | Pending |
| OpenClaw Rust Port | Release/Commit | `TBD` | Pending |
| Original OpenClaw Stable | Release | `TBD` | Pending |
| Original OpenClaw Beta | Pre-release | `TBD` | Pending |

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
| Appliance/Bare-metal | boot/runtime progression/control-plane | additive | In progress | bare-metal smoke + qemu smoke + runtime probe | qemu scripts outputs |
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

- [ ] Fill all `TBD` baseline references with exact tags/SHAs.
- [ ] Finalize parity policy for each domain row.
- [ ] Map each domain row to exact tests/workflows and evidence links.
- [ ] Attach matrix evidence to issue `#2` and roll up to issue `#1`.
