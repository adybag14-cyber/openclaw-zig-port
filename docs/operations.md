# Operations

## Current Snapshot

- Latest published edge release: `v0.2.0-zig-edge.26`
- Latest local test gate: `zig build test --summary all` -> main `203/203` + bare-metal host `47/47` passing
- Latest parity gate: `scripts/check-go-method-parity.ps1` -> `GO_MISSING_IN_ZIG=0`, `ORIGINAL_MISSING_IN_ZIG=0`, `ORIGINAL_BETA_MISSING_IN_ZIG=0`, `UNION_MISSING_IN_ZIG=0`, `UNION_EVENTS_MISSING_IN_ZIG=0`, `ZIG_COUNT=169`, `ZIG_EVENTS_COUNT=19`
- Current head: `f707532`
- Latest CI:
  - `zig-ci` `22790152153` -> success
  - `docs-pages` `22790152152` -> success

## Local Validation Matrix

Recommended sequence:

```powershell
./scripts/zig-syntax-check.ps1
./scripts/check-go-method-parity.ps1
./scripts/docs-status-check.ps1 -RefreshParity
./scripts/docker-smoke-check.ps1
./scripts/runtime-smoke-check.ps1
./scripts/baremetal-smoke-check.ps1
./scripts/baremetal-qemu-smoke-check.ps1
./scripts/baremetal-qemu-runtime-oc-tick-check.ps1
./scripts/baremetal-qemu-command-loop-check.ps1
./scripts/baremetal-qemu-descriptor-bootdiag-probe-check.ps1
./scripts/baremetal-qemu-descriptor-table-content-probe-check.ps1
./scripts/baremetal-qemu-descriptor-dispatch-probe-check.ps1
./scripts/baremetal-qemu-vector-history-overflow-probe-check.ps1
./scripts/baremetal-qemu-scheduler-probe-check.ps1
./scripts/baremetal-qemu-scheduler-priority-budget-probe-check.ps1
./scripts/baremetal-qemu-timer-wake-probe-check.ps1
./scripts/baremetal-qemu-periodic-timer-probe-check.ps1
./scripts/baremetal-qemu-interrupt-timeout-probe-check.ps1
./scripts/baremetal-qemu-wake-queue-selective-probe-check.ps1
./scripts/baremetal-qemu-allocator-syscall-probe-check.ps1
./scripts/baremetal-qemu-allocator-syscall-failure-probe-check.ps1
./scripts/baremetal-qemu-reset-counters-probe-check.ps1
./scripts/appliance-control-plane-smoke-check.ps1
./scripts/appliance-restart-recovery-smoke-check.ps1
./scripts/appliance-rollout-boundary-smoke-check.ps1
./scripts/appliance-minimal-profile-smoke-check.ps1
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
- Zig master freshness snapshot (`scripts/zig-codeberg-master-check.ps1`, Codeberg primary + GitHub mirror fallback)
- parity gate enforcement (Go latest + original stable latest + original beta latest, including gateway event parity)
- docs status drift gate (`scripts/docs-status-check.ps1`)
- runtime + gateway-auth + websocket smoke checks
- appliance control-plane smoke check (`system.boot.*`, `system.rollback.*`, secure-boot update gate)
- appliance restart recovery smoke check (persisted control-plane replay + recovery actionability)
- appliance rollout boundary smoke check (real `canary` lane selection + canary-to-stable promotion)
- appliance minimal profile smoke check (persisted state + auth + secure-boot/readiness contract)
- optional bare-metal QEMU scheduler probe (scheduler reset/timeslice/task-create/policy-enable against the freestanding PVH artifact)
- optional bare-metal QEMU descriptor bootdiag probe (boot-diagnostics reset/stack capture/boot-phase transition and descriptor reinit/load telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU bootdiag/history-clear probe (boot-diagnostics reset plus live `command_clear_command_history` and `command_clear_health_history` control semantics against the freestanding PVH artifact)
- optional bare-metal QEMU descriptor table content probe (live `gdtr/idtr` limits+bases, code/data `gdt` entry fields, and `idt[0]/idt[255]` selector/type/stub wiring against the freestanding PVH artifact)
- optional bare-metal QEMU descriptor dispatch probe (descriptor reinit/load plus post-load interrupt and exception dispatch coherence, including interrupt/exception history rings, against the freestanding PVH artifact)
- optional bare-metal QEMU vector history overflow probe (interrupt/exception counter resets plus repeated dispatch saturation, proving history-ring overflow and per-vector telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU command-health history probe (repeated `command_set_health_code` mailbox execution, proving command-history overflow, health-history overflow, and retained oldest/newest payload ordering against the freestanding PVH artifact)
- optional bare-metal QEMU mode/boot-phase history probe (command/runtime/panic reason ordering plus post-clear saturation of the 64-entry mode-history and boot-phase-history rings against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler priority budget probe (live `command_scheduler_set_default_budget` plus `command_task_set_priority` proof, including zero-budget task inheritance and dispatch-order flip under the priority scheduler against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler round-robin probe (default scheduler policy remains round-robin under live QEMU execution, rotating dispatch `1/0 -> 1/1 -> 2/1` across a lower-priority first task and higher-priority second task while budgets decrement deterministically)
- optional bare-metal QEMU timer wake probe (timer reset/quantum/task-wait to fired timer entry + wake queue telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU periodic timer probe (periodic schedule + timer disable/enable pause-resume, capturing the first resumed periodic fire and queued wake telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU periodic interrupt probe (mixed periodic timer + interrupt wake ordering, proving the interrupt arrives before deadline while the periodic source keeps cadence and timer cancellation prevents a later timeout leak against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout probe (`task_wait_interrupt_for` wakes on interrupt before deadline, clears the timeout arm, and does not later leak a second timer wake against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout timer probe (`task_wait_interrupt_for` remains blocked with no wake queue entry at the deadline-preceding boundary, then wakes on the timer path with `reason=timer`, `vector=0`, and zero interrupt telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout clamp probe (near-`u64::max` `task_wait_interrupt_for` deadline saturates to `18446744073709551615`, the queued wake records that saturated tick, and the live wake boundary wraps cleanly to `0` under the freestanding PVH artifact)
- optional bare-metal QEMU interrupt filter probe (`task_wait_interrupt(any)` wakes on vector `200`, vector-scoped `task_wait_interrupt(13)` ignores non-matching `200`, then wakes on matching `13`, and invalid vector `65536` is rejected with `-22` against the freestanding PVH artifact)
- optional bare-metal QEMU manual-wait interrupt probe (`task_wait` remains blocked with `wake_queue_len=0` and manual wait-kind intact after interrupt `44`, then recovers via explicit `scheduler_wake_task` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue selective probe (timer, interrupt, and manual wake generation plus `pop_reason`, `pop_vector`, `pop_reason_vector`, and `pop_before_tick` queue drains against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue summary/age probe (exported `oc_wake_queue_summary_ptr` and `oc_wake_queue_age_buckets_ptr_quantum_2` snapshots before and after selective queue drains against the freestanding PVH artifact)
- optional bare-metal QEMU allocator syscall probe (alloc/free plus syscall register/invoke/block/disable/unregister against the freestanding PVH artifact)
- optional bare-metal QEMU allocator syscall failure probe (invalid-alignment, no-space, blocked-syscall, and disabled-syscall result semantics plus command-result counters against the freestanding PVH artifact)
- optional bare-metal QEMU command-result counters probe (live mailbox result-category accounting plus `command_reset_command_result_counters` reset semantics against the freestanding PVH artifact)
- optional bare-metal QEMU reset counters probe (live `command_reset_counters` proof after dirtying interrupt, exception, scheduler, allocator, syscall, timer, wake-queue, mode, boot-phase, command-history, and health-history state against the freestanding PVH artifact)
- optional bare-metal QEMU task lifecycle probe (live `task_wait -> scheduler_wake_task -> task_resume -> task_terminate` control path plus post-terminate rejected wake semantics against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt mask exception probe (masked external vector remains blocked while an exception vector still wakes the waiting task and records history telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt mask profile probe (external-all, custom unmask/remask, ignored-count reset, external-high, invalid profile rejection, and clear-all recovery against the freestanding PVH artifact)
- parity evidence artifacts
  - websocket smoke validates `/ws` and root compatibility route `/`, including binary-frame RPC dispatch
  - gateway-auth and websocket smokes use bounded receive timeouts to prevent hanging CI jobs
  - dispatcher coverage test now fails on both missing methods (`-32601`) and registered-method dispatcher gaps (`-32603` fallback guard)

### `release-preview.yml`

- validate stage before artifact matrix
- duplicate release-tag protection
- preview artifact publishing with parity evidence
- docs status drift gate (`scripts/docs-status-check.ps1`) in validate stage
- zig master freshness snapshot capture + publish (`zig-master-freshness.json`)
- release trust evidence generation and publishing (`release-manifest.json`, `sbom.spdx.json`, `provenance.intoto.json`)
- gateway-auth + websocket smoke checks in validate stage
- appliance control-plane smoke check in validate stage
- appliance restart recovery smoke check in validate stage
- appliance rollout boundary smoke check in validate stage
- appliance minimal profile smoke check in validate stage
- bare-metal optional QEMU scheduler probe in validate stage
- bare-metal optional QEMU timer wake probe in validate stage
- bare-metal optional QEMU periodic timer probe in validate stage
- bare-metal optional QEMU periodic interrupt probe in validate stage
- bare-metal optional QEMU interrupt timeout probe in validate stage
- bare-metal optional QEMU interrupt timeout timer probe in validate stage
- bare-metal optional QEMU interrupt timeout clamp probe in validate stage
- bare-metal optional QEMU interrupt filter probe in validate stage
- bare-metal optional QEMU manual-wait interrupt probe in validate stage
- bare-metal optional QEMU descriptor bootdiag probe in validate stage
- bare-metal optional QEMU bootdiag/history-clear probe in validate stage
- bare-metal optional QEMU descriptor table content probe in validate stage
- bare-metal optional QEMU descriptor dispatch probe in validate stage
- bare-metal optional QEMU vector history overflow probe in validate stage
- bare-metal optional QEMU command-health history probe in validate stage
- bare-metal optional QEMU mode/boot-phase history probe in validate stage
- bare-metal optional QEMU scheduler priority budget probe in validate stage
- bare-metal optional QEMU scheduler round-robin probe in validate stage
- bare-metal optional QEMU wake-queue selective probe in validate stage
- bare-metal optional QEMU wake-queue summary/age probe in validate stage
- bare-metal optional QEMU allocator syscall probe in validate stage
- bare-metal optional QEMU allocator syscall failure probe in validate stage
- bare-metal optional QEMU command-result counters probe in validate stage
- bare-metal optional QEMU reset counters probe in validate stage
- bare-metal optional QEMU task lifecycle probe in validate stage
- bare-metal optional QEMU interrupt mask exception probe in validate stage
- bare-metal optional QEMU interrupt mask profile probe in validate stage
- npm package dry-run validation in release validate stage
- python package validation (unit tests + build + twine check) in release validate stage
- local `scripts/release-preview.ps1` mirrors parity/docs/freshness gates before artifact packaging

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
