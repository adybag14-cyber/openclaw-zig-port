# Operations

## Current Snapshot

- Latest published edge release: `v0.2.0-zig-edge.26`
- Latest local test gate: `zig build test --summary all` -> main `203/203` + bare-metal host `64/64` passing
- Latest parity gate: `scripts/check-go-method-parity.ps1` -> `GO_MISSING_IN_ZIG=0`, `ORIGINAL_MISSING_IN_ZIG=0`, `ORIGINAL_BETA_MISSING_IN_ZIG=0`, `UNION_MISSING_IN_ZIG=0`, `UNION_EVENTS_MISSING_IN_ZIG=0`, `ZIG_COUNT=169`, `ZIG_EVENTS_COUNT=19`
- Current head: `main + panic-recovery slice`
- Latest CI:
  - `zig-ci` `22804683149` -> success
  - `docs-pages` `22804683158` -> success

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
./scripts/baremetal-qemu-feature-flags-tick-batch-probe-check.ps1
./scripts/baremetal-qemu-descriptor-bootdiag-probe-check.ps1
./scripts/baremetal-qemu-descriptor-table-content-probe-check.ps1
./scripts/baremetal-qemu-descriptor-dispatch-probe-check.ps1
./scripts/baremetal-qemu-vector-counter-reset-probe-check.ps1
./scripts/baremetal-qemu-vector-history-overflow-probe-check.ps1
./scripts/baremetal-qemu-scheduler-probe-check.ps1
./scripts/baremetal-qemu-scheduler-priority-budget-probe-check.ps1
./scripts/baremetal-qemu-timer-wake-probe-check.ps1
./scripts/baremetal-qemu-timer-cancel-probe-check.ps1
./scripts/baremetal-qemu-periodic-timer-probe-check.ps1
./scripts/baremetal-qemu-interrupt-timeout-probe-check.ps1
./scripts/baremetal-qemu-wake-queue-selective-probe-check.ps1
./scripts/baremetal-qemu-wake-queue-reason-overflow-probe-check.ps1
./scripts/baremetal-qemu-wake-queue-fifo-probe-check.ps1
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
- optional bare-metal QEMU feature-flags/tick-batch probe (`command_set_feature_flags` updates the live flag mask, `command_set_tick_batch_hint` raises runtime tick progression from `1` to `4`, and an invalid zero hint is rejected without changing the active batch size against the freestanding PVH artifact)
- optional bare-metal QEMU vector counter reset probe (`command_reset_vector_counters` after live interrupt+exception dispatch, proving vectors `10/200/14` and exception vectors `10/14` zero while aggregate counts stay at `4/3` against the freestanding PVH artifact)
- optional bare-metal QEMU vector history overflow probe (interrupt/exception counter resets plus repeated dispatch saturation, proving history-ring overflow and per-vector telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU vector history clear probe (dedicated mailbox clear-path proof for `command_clear_interrupt_history` and `command_clear_exception_history`, validating that history rings/overflow reset without disturbing aggregate interrupt/exception counters against the freestanding PVH artifact)
- optional bare-metal QEMU command-health history probe (repeated `command_set_health_code` mailbox execution, proving command-history overflow, health-history overflow, and retained oldest/newest payload ordering against the freestanding PVH artifact)
- optional bare-metal QEMU mode/boot-phase history probe (command/runtime/panic reason ordering plus post-clear saturation of the 64-entry mode-history and boot-phase-history rings against the freestanding PVH artifact)
- optional bare-metal QEMU mode/boot-phase history clear probe (dedicated mailbox clear-path proof for `command_clear_mode_history` and `command_clear_boot_phase_history`, validating clear-state reset of len/head/overflow/seq and `seq=1` restart semantics against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler priority budget probe (live `command_scheduler_set_default_budget` plus `command_task_set_priority` proof, including zero-budget task inheritance and dispatch-order flip under the priority scheduler against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler round-robin probe (default scheduler policy remains round-robin under live QEMU execution, rotating dispatch `1/0 -> 1/1 -> 2/1` across a lower-priority first task and higher-priority second task while budgets decrement deterministically)
- optional bare-metal QEMU scheduler timeslice-update probe (live `command_scheduler_set_timeslice` updates under active load, proving budget consumption immediately follows `timeslice 1 -> 4 -> 2` and invalid zero is rejected without changing the active timeslice against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler disable-enable probe (live `command_scheduler_disable` and `command_scheduler_enable` under active load, proving dispatch count and task budget stay frozen across idle disabled ticks and resume immediately after re-enable against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler reset probe (live `command_scheduler_reset` under active load, proving scheduler state returns to defaults, active task state is cleared, task IDs restart at `1`, and a fresh task dispatches cleanly after re-enable against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler policy-switch probe (live round-robin to priority to round-robin transitions under active load, proving dispatch order flips immediately, low-task reprioritization takes effect on the next priority tick, and invalid policy `9` is rejected without changing the active round-robin policy against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler saturation probe (fills the 16-slot scheduler task table, proves the 17th `command_task_create` returns `result_no_space`, then terminates one slot and reuses it with a fresh task ID plus replacement priority/budget against the freestanding PVH artifact)
- optional bare-metal QEMU timer wake probe (timer reset/quantum/task-wait to fired timer entry + wake queue telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU timer quantum probe (one-shot `command_timer_schedule` respects `command_timer_set_quantum`, keeps the task waiting with `wake_queue_len=0` at the pre-boundary tick, and only wakes on the next quantum boundary against the freestanding PVH artifact)
- optional bare-metal QEMU timer cancel probe (capture the live timer ID from the armed entry, cancel that exact timer via `command_timer_cancel`, preserve the canceled slot state, and get `result_not_found` on a second cancel against the freestanding PVH artifact)
- optional bare-metal QEMU timer cancel task probe (one-shot + periodic task timer arming followed by `command_timer_cancel_task`, proving the first cancel collapses `timer_entry_count` to `0`, preserves the canceled timer slot state, and the second cancel returns `result_not_found` against the freestanding PVH artifact)
- optional bare-metal QEMU timer pressure probe (fills the 16 runnable task slots with live one-shot timers, proves timer IDs `1 -> 16`, cancels one task timer, then reuses that exact slot with fresh timer ID `17` and no stray wake/dispatch activity against the freestanding PVH artifact)
- optional bare-metal QEMU periodic timer probe (periodic schedule + timer disable/enable pause-resume, capturing the first resumed periodic fire and queued wake telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU periodic timer clamp probe (periodic timer armed at `u64::max-1`, proving the first fire lands at `18446744073709551615`, the periodic deadline re-arms to the same saturated tick instead of wrapping, and the runtime holds stable after the tick counter wraps to `0`)
- optional bare-metal QEMU periodic interrupt probe (mixed periodic timer + interrupt wake ordering, proving the interrupt arrives before deadline while the periodic source keeps cadence and timer cancellation prevents a later timeout leak against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout probe (`task_wait_interrupt_for` wakes on interrupt before deadline, clears the timeout arm, and does not later leak a second timer wake against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout timer probe (`task_wait_interrupt_for` remains blocked with no wake queue entry at the deadline-preceding boundary, then wakes on the timer path with `reason=timer`, `vector=0`, and zero interrupt telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout clamp probe (near-`u64::max` `task_wait_interrupt_for` deadline saturates to `18446744073709551615`, the queued wake records that saturated tick, and the live wake boundary wraps cleanly to `0` under the freestanding PVH artifact)
- optional bare-metal QEMU interrupt filter probe (`task_wait_interrupt(any)` wakes on vector `200`, vector-scoped `task_wait_interrupt(13)` ignores non-matching `200`, then wakes on matching `13`, and invalid vector `65536` is rejected with `-22` against the freestanding PVH artifact)
- optional bare-metal QEMU timer-disable interrupt probe (`command_timer_disable` suppresses timer dispatch while `command_trigger_interrupt` still wakes an interrupt waiter immediately, and the deferred one-shot timer wake is only delivered after `command_timer_enable` against the freestanding PVH artifact)
- optional bare-metal QEMU panic-recovery probe (`command_trigger_panic_flag` freezes dispatch and budget burn under active load, `command_set_mode(mode_running)` resumes the same task immediately, and `command_set_boot_phase(runtime)` restores boot diagnostics against the freestanding PVH artifact)
- optional bare-metal QEMU manual-wait interrupt probe (`task_wait` remains blocked with `wake_queue_len=0` and manual wait-kind intact after interrupt `44`, then recovers via explicit `scheduler_wake_task` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue selective probe (timer, interrupt, and manual wake generation plus `pop_reason`, `pop_vector`, `pop_reason_vector`, and `pop_before_tick` queue drains against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue selective-overflow probe (wrapped 64-entry interrupt wake ring selective drain proof, preserving FIFO survivor ordering after `pop_vector(13,31)` and final `pop_reason_vector(interrupt@13)` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue before-tick-overflow probe (wrapped 64-entry interrupt wake ring deadline-drain proof, preserving FIFO survivor ordering through two `pop_before_tick` threshold drains and a final empty-queue `result_not_found` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue reason-overflow probe (wrapped 64-entry mixed `manual`/`interrupt` wake ring drain proof, preserving FIFO survivor ordering through `pop_reason(manual,31)` and final `pop_reason(manual,99)` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue FIFO probe (`command_wake_queue_pop` removes the logical oldest wake first, preserves the second queued manual wake as the new head, and returns `result_not_found` once the queue is empty)
- optional bare-metal QEMU wake-queue summary/age probe (exported `oc_wake_queue_summary_ptr` and `oc_wake_queue_age_buckets_ptr_quantum_2` snapshots before and after selective queue drains against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue overflow probe (sustained manual wake pressure over one waiting task, proving the 64-entry ring retains the newest window with `overflow=2` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue batch-pop probe (post-overflow batch-drain and refill proof over one waiting task, proving survivor ordering `65/66`, empty recovery, and reuse at `seq=67` against the freestanding PVH artifact)
- optional bare-metal QEMU allocator syscall probe (alloc/free plus syscall register/invoke/block/disable/unregister against the freestanding PVH artifact)
- optional bare-metal QEMU allocator syscall failure probe (invalid-alignment, no-space, blocked-syscall, and disabled-syscall result semantics plus command-result counters against the freestanding PVH artifact)
- optional bare-metal QEMU command-result counters probe (live mailbox result-category accounting plus `command_reset_command_result_counters` reset semantics against the freestanding PVH artifact)
- optional bare-metal QEMU reset counters probe (live `command_reset_counters` proof after dirtying interrupt, exception, scheduler, allocator, syscall, timer, wake-queue, mode, boot-phase, command-history, and health-history state against the freestanding PVH artifact)
- optional bare-metal QEMU task lifecycle probe (live `task_wait -> scheduler_wake_task -> task_resume -> task_terminate` control path plus post-terminate rejected wake semantics against the freestanding PVH artifact)
- optional bare-metal QEMU active-task terminate probe (live `command_task_terminate` against the currently running high-priority task, proving immediate failover to the remaining ready task, idempotent repeat terminate semantics, and final empty-run collapse against the freestanding PVH artifact)
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
- bare-metal optional QEMU feature-flags/tick-batch probe in validate stage
- bare-metal optional QEMU scheduler probe in validate stage
- bare-metal optional QEMU scheduler timeslice-update probe in validate stage
- bare-metal optional QEMU scheduler disable-enable probe in validate stage
- bare-metal optional QEMU scheduler reset probe in validate stage
- bare-metal optional QEMU scheduler policy-switch probe in validate stage
- bare-metal optional QEMU scheduler saturation probe in validate stage
- bare-metal optional QEMU timer wake probe in validate stage
- bare-metal optional QEMU timer quantum probe in validate stage
- bare-metal optional QEMU timer cancel probe in validate stage
- bare-metal optional QEMU timer cancel task probe in validate stage
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
- bare-metal optional QEMU vector counter reset probe in validate stage
- bare-metal optional QEMU vector history overflow probe in validate stage
- bare-metal optional QEMU vector history clear probe in validate stage
- bare-metal optional QEMU command-health history probe in validate stage
- bare-metal optional QEMU mode/boot-phase history probe in validate stage
- bare-metal optional QEMU mode/boot-phase history clear probe in validate stage
- bare-metal optional QEMU scheduler priority budget probe in validate stage
- bare-metal optional QEMU scheduler round-robin probe in validate stage
- bare-metal optional QEMU wake-queue selective probe in validate stage
- bare-metal optional QEMU wake-queue selective-overflow probe in validate stage
- bare-metal optional QEMU wake-queue before-tick-overflow probe in validate stage
- bare-metal optional QEMU wake-queue reason-overflow probe in validate stage
- bare-metal optional QEMU wake-queue FIFO probe in validate stage
- bare-metal optional QEMU wake-queue summary/age probe in validate stage
- bare-metal optional QEMU wake-queue overflow probe in validate stage
- bare-metal optional QEMU wake-queue clear probe in validate stage
- bare-metal optional QEMU wake-queue batch-pop probe in validate stage
- bare-metal optional QEMU allocator syscall probe in validate stage
- bare-metal optional QEMU allocator syscall failure probe in validate stage
- bare-metal optional QEMU command-result counters probe in validate stage
- bare-metal optional QEMU reset counters probe in validate stage
- bare-metal optional QEMU task lifecycle probe in validate stage
- bare-metal optional QEMU active-task terminate probe in validate stage
- bare-metal optional QEMU panic-recovery probe in validate stage
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
