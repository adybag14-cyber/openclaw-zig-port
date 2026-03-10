# Operations

## Current Snapshot

- Latest published edge release: `v0.2.0-zig-edge.28`
- Latest local test gate: `zig build test --summary all` -> main `203/203` + bare-metal host `109/109` passing
- Latest parity gate: `scripts/check-go-method-parity.ps1` -> `GO_MISSING_IN_ZIG=0`, `ORIGINAL_MISSING_IN_ZIG=0`, `ORIGINAL_BETA_MISSING_IN_ZIG=0`, `UNION_MISSING_IN_ZIG=0`, `UNION_EVENTS_MISSING_IN_ZIG=0`, `ZIG_COUNT=172`, `ZIG_EVENTS_COUNT=19`
- Current head: local source-of-truth on `main` (exact pushed head is tracked in issue `#1` and the latest GitHub Actions runs)
- Toolchain lane: Codeberg `master` is canonical; `adybag14-cyber/zig` is the Windows release mirror with rolling `latest-master` plus immutable `upstream-<sha>` releases.
- `scripts/package-registry-status.ps1` now performs default npmjs/PyPI visibility checks even when invoked with only `-ReleaseTag`, so local package diagnostics no longer silently skip unresolved public-registry state.
- Latest CI:
  - latest pushed `main` head is tracked in issue `#1`
  - `zig-ci` + `docs-pages` must both be green before a slice is considered complete

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
./scripts/baremetal-qemu-mailbox-header-validation-probe-check.ps1
./scripts/baremetal-qemu-mailbox-invalid-magic-preserve-state-probe-check.ps1
./scripts/baremetal-qemu-mailbox-invalid-api-version-preserve-state-probe-check.ps1
./scripts/baremetal-qemu-mailbox-valid-recovery-probe-check.ps1
./scripts/baremetal-qemu-mailbox-stale-seq-probe-check.ps1
./scripts/baremetal-qemu-mailbox-stale-seq-preserve-state-probe-check.ps1
./scripts/baremetal-qemu-mailbox-seq-wraparound-probe-check.ps1
./scripts/baremetal-qemu-mailbox-seq-wraparound-recovery-probe-check.ps1
./scripts/baremetal-qemu-feature-flags-tick-batch-probe-check.ps1
./scripts/baremetal-qemu-feature-flags-set-success-probe-check.ps1
./scripts/baremetal-qemu-tick-batch-valid-update-probe-check.ps1
./scripts/baremetal-qemu-tick-batch-invalid-preserve-probe-check.ps1
./scripts/baremetal-qemu-feature-flags-tick-batch-mailbox-state-probe-check.ps1
./scripts/baremetal-qemu-feature-flags-tick-batch-state-preserve-probe-check.ps1
./scripts/baremetal-qemu-descriptor-bootdiag-probe-check.ps1
./scripts/baremetal-qemu-descriptor-table-content-probe-check.ps1
./scripts/baremetal-qemu-descriptor-dispatch-probe-check.ps1
./scripts/baremetal-qemu-vector-counter-reset-probe-check.ps1
./scripts/baremetal-qemu-vector-history-overflow-probe-check.ps1
./scripts/baremetal-qemu-scheduler-probe-check.ps1
./scripts/baremetal-qemu-scheduler-priority-budget-probe-check.ps1
./scripts/baremetal-qemu-timer-wake-probe-check.ps1
./scripts/baremetal-qemu-timer-cancel-probe-check.ps1
./scripts/baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1
./scripts/baremetal-qemu-task-resume-timer-clear-probe-check.ps1
./scripts/baremetal-qemu-task-resume-interrupt-timeout-probe-check.ps1
./scripts/baremetal-qemu-task-resume-interrupt-timeout-wait-clear-probe-check.ps1
./scripts/baremetal-qemu-task-resume-interrupt-timeout-manual-wake-probe-check.ps1
./scripts/baremetal-qemu-scheduler-wake-timer-clear-probe-check.ps1
./scripts/baremetal-qemu-scheduler-wake-timer-clear-manual-wake-probe-check.ps1
./scripts/baremetal-qemu-timer-cancel-task-interrupt-timeout-interrupt-recovery-probe-check.ps1
./scripts/baremetal-qemu-task-terminate-mixed-state-survivor-probe-check.ps1
./scripts/baremetal-qemu-periodic-timer-probe-check.ps1
./scripts/baremetal-qemu-periodic-timer-clamp-probe-check.ps1
./scripts/baremetal-qemu-periodic-timer-clamp-baseline-probe-check.ps1
./scripts/baremetal-qemu-periodic-timer-clamp-first-fire-probe-check.ps1
./scripts/baremetal-qemu-periodic-timer-clamp-saturated-rearm-probe-check.ps1
./scripts/baremetal-qemu-periodic-timer-clamp-post-wrap-hold-probe-check.ps1
./scripts/baremetal-qemu-periodic-timer-clamp-telemetry-preserve-probe-check.ps1
./scripts/baremetal-qemu-interrupt-timeout-probe-check.ps1
./scripts/baremetal-qemu-timer-disable-reenable-probe-check.ps1
./scripts/baremetal-qemu-timer-disable-paused-state-probe-check.ps1
./scripts/baremetal-qemu-timer-disable-reenable-oneshot-recovery-probe-check.ps1
./scripts/baremetal-qemu-interrupt-timeout-disable-enable-probe-check.ps1
./scripts/baremetal-qemu-interrupt-timeout-disable-reenable-timer-probe-check.ps1
./scripts/baremetal-qemu-interrupt-timeout-disable-interrupt-probe-check.ps1
./scripts/baremetal-qemu-interrupt-timeout-disable-interrupt-recovery-probe-check.ps1
./scripts/baremetal-qemu-timer-reset-wait-kind-isolation-probe-check.ps1
./scripts/baremetal-qemu-task-terminate-interrupt-timeout-probe-check.ps1
./scripts/baremetal-qemu-panic-wake-recovery-probe-check.ps1
./scripts/baremetal-qemu-wake-queue-selective-probe-check.ps1
./scripts/baremetal-qemu-wake-queue-reason-overflow-probe-check.ps1
./scripts/baremetal-qemu-wake-queue-fifo-probe-check.ps1
./scripts/baremetal-qemu-allocator-syscall-probe-check.ps1
./scripts/baremetal-qemu-syscall-saturation-probe-check.ps1
./scripts/baremetal-qemu-syscall-control-probe-check.ps1
./scripts/baremetal-qemu-syscall-reregister-preserve-count-probe-check.ps1
./scripts/baremetal-qemu-syscall-blocked-invoke-preserve-state-probe-check.ps1
./scripts/baremetal-qemu-syscall-disabled-invoke-preserve-state-probe-check.ps1
./scripts/baremetal-qemu-syscall-saturation-overflow-preserve-full-probe-check.ps1
./scripts/baremetal-qemu-syscall-saturation-reuse-slot-probe-check.ps1
./scripts/baremetal-qemu-syscall-saturation-reset-restart-probe-check.ps1
./scripts/baremetal-qemu-allocator-syscall-failure-probe-check.ps1
./scripts/baremetal-qemu-reset-counters-probe-check.ps1
./scripts/baremetal-qemu-interrupt-mask-clear-all-recovery-probe-check.ps1
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
- GitHub mirror release snapshot (`scripts/zig-github-mirror-release-check.ps1`) for Windows asset URL/digest/target-commit evidence
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
- optional bare-metal QEMU feature-flags/tick-batch wrapper probes (`baremetal-qemu-feature-flags-set-success-probe-check.ps1`, `baremetal-qemu-tick-batch-valid-update-probe-check.ps1`, `baremetal-qemu-tick-batch-invalid-preserve-probe-check.ps1`, `baremetal-qemu-feature-flags-tick-batch-mailbox-state-probe-check.ps1`, and `baremetal-qemu-feature-flags-tick-batch-state-preserve-probe-check.ps1`) reuse the broad probe and fail directly on the narrow stage-success, valid update, invalid preserve, mailbox-state, and final preserved-state boundaries
- optional bare-metal QEMU vector counter reset probe (`command_reset_vector_counters` after live interrupt+exception dispatch, proving vectors `10/200/14` and exception vectors `10/14` zero while aggregate counts stay at `4/3` against the freestanding PVH artifact)
- optional bare-metal QEMU vector history overflow probe (interrupt/exception counter resets plus repeated dispatch saturation, proving history-ring overflow and per-vector telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU vector history clear probe (dedicated mailbox clear-path proof for `command_reset_interrupt_counters` / `command_reset_exception_counters` plus `command_clear_interrupt_history` / `command_clear_exception_history`, validating that aggregate counters reset first without disturbing retained history/vector tables and that the later clear only zeroes history-ring/overflow state against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt/exception reset-isolation wrappers (`baremetal-qemu-reset-interrupt-counters-preserve-history-probe-check.ps1`, `baremetal-qemu-reset-exception-counters-preserve-history-probe-check.ps1`, `baremetal-qemu-clear-interrupt-history-preserve-exception-probe-check.ps1`, `baremetal-qemu-reset-vector-counters-preserve-aggregate-probe-check.ps1`, and `baremetal-qemu-reset-vector-counters-preserve-last-vector-probe-check.ps1`) reuse the broad vector probes and fail on the narrow preservation boundaries directly
- optional bare-metal QEMU command-health history probe (repeated `command_set_health_code` mailbox execution, proving command-history overflow, health-history overflow, and retained oldest/newest payload ordering against the freestanding PVH artifact)
- optional bare-metal QEMU mailbox header validation probe (invalid `magic` / `api_version` rejection with `ack` advancement but no command execution, followed by clean recovery on the next valid mailbox command against the freestanding PVH artifact)
- optional bare-metal QEMU mailbox stale-seq probe (stale `command_seq` replay stays no-op, preserves prior `ack`/history state, and the next fresh sequence executes exactly once against the freestanding PVH artifact)
- optional bare-metal QEMU mailbox seq-wraparound probe (live mailbox progression across `u64::max` wrap, preserving deterministic `ack` rollover and command-history ordering over the freestanding PVH artifact)
- optional bare-metal QEMU mailbox wrapper probes (`baremetal-qemu-mailbox-invalid-magic-preserve-state-probe-check.ps1`, `baremetal-qemu-mailbox-invalid-api-version-preserve-state-probe-check.ps1`, `baremetal-qemu-mailbox-valid-recovery-probe-check.ps1`, `baremetal-qemu-mailbox-stale-seq-preserve-state-probe-check.ps1`, and `baremetal-qemu-mailbox-seq-wraparound-recovery-probe-check.ps1`) reuse the broad mailbox probes and fail directly on the narrow invalid-header, valid recovery, stale-replay preservation, and wraparound recovery boundaries
- optional bare-metal QEMU command-history overflow clear probe (combined overflow + clear + restart proof for the command-history ring, validating retained `seq 4 -> 35`, single-receipt clear collapse, and clean restart semantics without disturbing health-history overflow state)
- optional bare-metal QEMU health-history overflow clear probe (combined overflow + clear + restart proof for the health-history ring, validating retained `seq 8 -> 71`, single-receipt clear collapse at `seq 1`, and clean restart semantics without disturbing command-history overflow state)
- optional bare-metal QEMU mode/boot-phase history probe (command/runtime/panic reason ordering plus post-clear saturation of the 64-entry mode-history and boot-phase-history rings against the freestanding PVH artifact)
- optional bare-metal QEMU mode/boot-phase setter probe (direct `command_set_boot_phase` / `command_set_mode` proof, validating same-value idempotence, invalid boot-phase `99` and invalid mode `77` rejection without state/history clobbering, and direct `mode_panicked` / `mode_running` transitions without panic-counter or boot-phase side effects against the freestanding PVH artifact)
- optional bare-metal QEMU mode/boot-phase history clear probe (dedicated mailbox clear-path proof for `command_clear_mode_history` and `command_clear_boot_phase_history`, validating clear-state reset of len/head/overflow/seq and `seq=1` restart semantics against the freestanding PVH artifact)
- optional bare-metal QEMU mode-history overflow clear probe (combined overflow + clear + restart proof for the mode-history ring, validating retained `seq 3 -> 66`, dedicated clear collapse, and `seq=1` restart semantics while the boot-phase ring stays intact until its own clear)
- optional bare-metal QEMU boot-phase-history overflow clear probe (combined overflow + clear + restart proof for the boot-phase-history ring, validating retained `seq 3 -> 66`, dedicated clear collapse, and `seq=1` restart semantics while the mode ring stays intact until its own clear)
- optional bare-metal QEMU scheduler priority budget probe (live `command_scheduler_set_default_budget` plus `command_task_set_priority` proof, including zero-budget task inheritance and dispatch-order flip under the priority scheduler against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler priority budget wrapper probes (five isolated checks over the same broad lane: baseline scheduler/task bootstrap, zero-budget default-budget inheritance, initial high-priority dominance, low-task takeover after reprioritize, and invalid-input preservation against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler default-budget invalid probe (live `command_scheduler_set_default_budget(0)` rejection with active default-budget preservation and clean zero-budget task inheritance after the rejected update against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler round-robin probe (default scheduler policy remains round-robin under live QEMU execution, rotating dispatch `1/0 -> 1/1 -> 2/1` across a lower-priority first task and higher-priority second task while budgets decrement deterministically)
- optional bare-metal QEMU scheduler round-robin wrapper probes (five isolated checks over the same broad lane: baseline task/policy bootstrap, first-dispatch first-task-only delivery, second-dispatch rotation, third-dispatch return to the first task, and final scheduler/task-state telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler timeslice-update probe (live `command_scheduler_set_timeslice` updates under active load, proving budget consumption immediately follows `timeslice 1 -> 4 -> 2` and invalid zero is rejected without changing the active timeslice against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler timeslice wrapper probes (five isolated checks over the same broad lane: baseline `timeslice=1`, first update `timeslice=4`, second update `timeslice=2`, invalid-zero preservation, and final dispatch/task-state telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler disable-enable probe (live `command_scheduler_disable` and `command_scheduler_enable` under active load, proving dispatch count and task budget stay frozen across idle disabled ticks and resume immediately after re-enable against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler disable-enable wrapper probes (five isolated checks over the same broad lane: baseline pre-disable state, disabled freeze-state, idle disabled preservation, re-enable resume metadata, and final task-state telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler reset probe (live `command_scheduler_reset` under active load, proving scheduler state returns to defaults, active task state is cleared, task IDs restart at `1`, and a fresh task dispatches cleanly after re-enable against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler reset mixed-state probe (live `command_scheduler_reset` against stale mixed load, proving queued wakes and armed task timers are scrubbed alongside the task table, timeout arms are cleared, timer quantum is preserved, and fresh timer scheduling resumes from the preserved `next_timer_id` against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler policy-switch probe (live round-robin to priority to round-robin transitions under active load, proving dispatch order flips immediately, low-task reprioritization takes effect on the next priority tick, and invalid policy `9` is rejected without changing the active round-robin policy against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler saturation probe (fills the 16-slot scheduler task table, proves the 17th `command_task_create` returns `result_no_space`, then terminates one slot and reuses it with a fresh task ID plus replacement priority/budget against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler saturation wrapper probes (`baremetal-qemu-scheduler-saturation-baseline-probe-check.ps1`, `baremetal-qemu-scheduler-saturation-overflow-preserve-probe-check.ps1`, `baremetal-qemu-scheduler-saturation-terminate-state-probe-check.ps1`, `baremetal-qemu-scheduler-saturation-reuse-state-probe-check.ps1`, and `baremetal-qemu-scheduler-saturation-final-state-probe-check.ps1`) reuse the broad pressure lane and fail directly on the 16-slot baseline fill, overflow rejection without task-count drift, terminated-slot capture, reuse-slot replacement semantics, and final scheduler state
- optional bare-metal QEMU timer wake probe (timer reset/quantum/task-wait to fired timer entry + wake queue telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU timer quantum probe (one-shot `command_timer_schedule` respects `command_timer_set_quantum`, keeps the task waiting with `wake_queue_len=0` at the pre-boundary tick, and only wakes on the next quantum boundary against the freestanding PVH artifact)
- optional bare-metal QEMU timer cancel probe (capture the live timer ID from the armed entry, cancel that exact timer via `command_timer_cancel`, preserve the canceled slot state, and get `result_not_found` on a second cancel against the freestanding PVH artifact)
- optional bare-metal QEMU timer cancel wrapper validation (armed baseline capture, cancel collapse to zero live timer entries, preserved canceled-slot metadata, second-cancel `result_not_found`, and zero wake/dispatch telemetry on the dedicated timer-cancel lane)
- optional bare-metal QEMU timer cancel-task interrupt-timeout probe (`command_timer_cancel_task` on a `task_wait_interrupt_for` waiter clears the timeout arm back to steady state, keeps `wait_timeout=0`, and still allows the later real interrupt wake to land exactly once against the freestanding PVH artifact)
- optional bare-metal QEMU timer cancel task probe (one-shot + periodic task timer arming followed by `command_timer_cancel_task`, proving the first cancel collapses `timer_entry_count` to `0`, preserves the canceled timer slot state, and the second cancel returns `result_not_found` against the freestanding PVH artifact)
- optional bare-metal QEMU timer pressure probe (fills the 16 runnable task slots with live one-shot timers, proves timer IDs `1 -> 16`, cancels one task timer, then reuses that exact slot with fresh timer ID `17` and no stray wake/dispatch activity against the freestanding PVH artifact)
- optional bare-metal QEMU timer pressure wrapper probes (baseline saturation, cancel-collapse, reuse-slot, reuse-next-fire, and quiet-telemetry isolation over the same dedicated PVH artifact)
- optional bare-metal QEMU timer reset recovery probe (dirty live timer entries plus `task_wait_interrupt_for` timeout state, then `command_timer_reset` proving timer state collapses back to baseline, stale timeout wakes do not leak after reset, manual/interrupt wake recovery still works, and the next timer re-arms from `timer_id=1` against the freestanding PVH artifact)
- optional bare-metal QEMU task-resume timer-clear probe (`command_task_resume` on a timer-backed wait cancels the armed timer entry, queues exactly one manual wake, prevents a later ghost timer wake after idle ticks, preserves timer quantum, and restarts fresh timer scheduling from the preserved `next_timer_id` against the freestanding PVH artifact)
- optional bare-metal QEMU task-resume interrupt-timeout probe (`command_task_resume` on a `task_wait_interrupt_for` waiter clears the pending timeout to `none`, queues exactly one manual wake, prevents any delayed timer wake after additional slack ticks, and leaves the timer subsystem at `next_timer_id=1` against the freestanding PVH artifact)
- optional bare-metal QEMU scheduler-wake timer-clear probe (`command_scheduler_wake_task` on a pure timer waiter cancels the armed timer entry, queues exactly one manual wake, prevents a later ghost timer wake after idle ticks, and preserves fresh timer scheduling from the current `next_timer_id` against the freestanding PVH artifact)
- optional bare-metal QEMU task-resume interrupt probe (`command_task_resume` on a pure `task_wait_interrupt` waiter clears the interrupt wait back to `none`, queues exactly one manual wake, prevents a later interrupt from creating a second wake, and leaves the timer subsystem idle at `next_timer_id=1` against the freestanding PVH artifact)
- optional bare-metal QEMU periodic timer probe (periodic schedule + timer disable/enable pause-resume, capturing the first resumed periodic fire and queued wake telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU periodic timer clamp probe (periodic timer armed at `u64::max-1`, proving the first fire lands at `18446744073709551615`, the periodic deadline re-arms to the same saturated tick instead of wrapping, and the runtime holds stable after the tick counter wraps to `0`)
- optional bare-metal QEMU periodic timer clamp wrapper probes (`baremetal-qemu-periodic-timer-clamp-baseline-probe-check.ps1`, `baremetal-qemu-periodic-timer-clamp-first-fire-probe-check.ps1`, `baremetal-qemu-periodic-timer-clamp-saturated-rearm-probe-check.ps1`, `baremetal-qemu-periodic-timer-clamp-post-wrap-hold-probe-check.ps1`, and `baremetal-qemu-periodic-timer-clamp-telemetry-preserve-probe-check.ps1`) reuse the broad clamp lane and fail directly on near-`u64::max` arm state, first-fire wrap semantics, saturated re-arm invariants, post-wrap hold stability, and final wake telemetry
- optional bare-metal QEMU periodic interrupt probe (mixed periodic timer + interrupt wake ordering, proving the interrupt arrives before deadline while the periodic source keeps cadence and timer cancellation prevents a later timeout leak against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout probe (`task_wait_interrupt_for` wakes on interrupt before deadline, clears the timeout arm, and does not later leak a second timer wake against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout manual-wake probe (`command_scheduler_wake_task` clears a pending `task_wait_interrupt_for` timeout, queues exactly one manual wake, and no delayed timer wake appears after additional slack ticks against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout manual-wake wrapper probes (narrow wrappers over the broad manual-wake probe that fail directly on preserved pre-wake interrupt-timeout arm state, single manual wake-queue delivery, cleared wait-kind/vector/timeout state after `command_scheduler_wake_task`, no stale timer wake after additional slack ticks, and preserved zero-interrupt plus last-wake telemetry)
- optional bare-metal QEMU interrupt manual-wake probe (`command_scheduler_wake_task` on a pure `task_wait_interrupt` waiter clears the interrupt wait back to `none`, queues exactly one manual wake, and a later interrupt only advances telemetry without adding a second wake against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout timer probe (`task_wait_interrupt_for` remains blocked with no wake queue entry at the deadline-preceding boundary, then wakes on the timer path with `reason=timer`, `vector=0`, and zero interrupt telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt timeout timer wrapper probes (narrow wrappers over the broad timer-only probe that fail directly on preserved armed timeout identity, deadline-edge blocked state with zero wake queue, timer wake payload semantics, no duplicate timer wake after additional slack ticks, and preserved zero-interrupt telemetry through the full timeout-only recovery path)
- optional bare-metal QEMU masked interrupt timeout probe (`command_interrupt_mask_apply_profile(external_all)` suppresses vector `200`, preserves the waiting task with no wake queue entry and zero interrupt telemetry, and then allows the timeout path to wake with `reason=timer`, `vector=0` against the freestanding PVH artifact)
- optional bare-metal QEMU masked interrupt timeout wrapper probes (narrow wrappers over the broad masked probe that fail directly on preserved `external_all` mask profile, zero-wake masked interrupt behavior, preserved armed wait/deadline, timer-only fallback wake semantics, and preserved zero-interrupt plus masked-vector telemetry)
- optional bare-metal QEMU interrupt timeout clamp probe (near-`u64::max` `task_wait_interrupt_for` deadline saturates to `18446744073709551615`, the queued wake records that saturated tick, and the live wake boundary wraps cleanly to `0` under the freestanding PVH artifact)
- optional bare-metal QEMU timer-disable reenable probe (a pure one-shot timer waiter survives `command_timer_disable`, remains blocked after idling past the original deadline, then wakes exactly once after `command_timer_enable` with a single queued `reason=timer` wake against the freestanding PVH artifact)
- optional bare-metal QEMU timer-disable paused-state probe (wrapper over the broad timer-disable reenable path that fails specifically when the disabled pause window stops preserving the armed entry, waiting task state, or zero wake/dispatch counts)
- optional bare-metal QEMU timer-disable reenable one-shot recovery probe (wrapper over the broad timer-disable reenable path that fails specifically when the pure one-shot wake stops recovering as a single `reason=timer`, `vector=0`, `timer_id=1` wake after `command_timer_enable`)
- optional bare-metal QEMU interrupt-timeout disable-enable probe (`command_task_wait_interrupt_for` survives `command_timer_disable`, remains blocked after idling past the original deadline, then emits exactly one overdue `reason=timer`, `vector=0` wake after `command_timer_enable` against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt-timeout disable-enable arm-preservation probe (wrapper over the broad interrupt-timeout disable-enable path that fails specifically when the timeout arm, interrupt wait-kind, waiting task state, zero wake queue, or zero interrupt telemetry stop being preserved immediately after `command_timer_disable`)
- optional bare-metal QEMU interrupt-timeout disable-enable deadline-hold probe (wrapper over the broad interrupt-timeout disable-enable path that fails specifically when the waiter stops remaining blocked after the original timeout deadline while timers stay disabled)
- optional bare-metal QEMU interrupt-timeout disable-enable paused-window probe (wrapper over the broad interrupt-timeout disable-enable path that fails specifically when the disabled pause window stops preserving zero queued wakes, zero timer-entry usage, zero interrupt telemetry, or zero timer-dispatch drift)
- optional bare-metal QEMU interrupt-timeout disable-enable deferred-timer-wake probe (wrapper over the broad interrupt-timeout disable-enable path that fails specifically when the deferred wake stops targeting the original waiting task, clearing wait state to `none`, and arriving only as a timer wake after `command_timer_enable`)
- optional bare-metal QEMU interrupt-timeout disable-enable telemetry-preserve probe (wrapper over the broad interrupt-timeout disable-enable path that fails specifically when the final timer-only wake stops preserving zero interrupt count, zero timer last-interrupt count, or zero last-interrupt vector)
- optional bare-metal QEMU interrupt-timeout disable-reenable timer probe (wrapper over the broad interrupt-timeout disable-enable path that fails specifically when the overdue wake stops being timer-only with zero interrupt telemetry and no remaining armed entries after `command_timer_enable`)
- optional bare-metal QEMU interrupt-timeout disable-interrupt probe (`command_task_wait_interrupt_for` survives `command_timer_disable`, wakes immediately on a real interrupt while timers stay disabled, clears the timeout arm, and does not leak a stale timer wake after `command_timer_enable` against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt-timeout disable-interrupt immediate-wake probe (wrapper over the broad interrupt-timeout disable-interrupt path that fails specifically when the first queued wake stops being the real interrupt wake, the task stops becoming ready immediately, or interrupt telemetry stops incrementing while timers stay disabled)
- optional bare-metal QEMU interrupt-timeout disable-interrupt timeout-clear probe (wrapper over the broad interrupt-timeout disable-interrupt path that fails specifically when the interrupt wake stops clearing wait kind, wait vector, timeout arm, or timer-entry state immediately)
- optional bare-metal QEMU interrupt-timeout disable-interrupt disabled-state probe (wrapper over the broad interrupt-timeout disable-interrupt path that fails specifically when timers stop remaining disabled, timer dispatch stops staying at `0`, or disabled-window pending-wake state drifts after the interrupt wake)
- optional bare-metal QEMU interrupt-timeout disable-interrupt reenable-no-stale-timer probe (wrapper over the broad interrupt-timeout disable-interrupt path that fails specifically when `command_timer_enable` adds a stale timer wake or changes the retained wake away from the original interrupt event)
- optional bare-metal QEMU interrupt-timeout disable-interrupt telemetry-preserve probe (wrapper over the broad interrupt-timeout disable-interrupt path that fails specifically when interrupt counters, last-interrupt vector, or last-wake telemetry stop staying coherent across re-enable)
- optional bare-metal QEMU interrupt-timeout disable-interrupt recovery probe (wrapper over the broad interrupt-timeout disable-interrupt path that fails specifically when the direct interrupt wake stops winning with `reason=interrupt`, matching vector telemetry, and zero timer dispatch after re-enable)
- optional bare-metal QEMU timer-reset wait-kind isolation probe (wrapper over the broad timer-reset recovery path that fails specifically when `command_timer_reset` stops collapsing pure timer waits to manual while preserving interrupt-wait mode and clearing only the timeout arm)
- optional bare-metal QEMU timer-reset pure-wait recovery probe (wrapper over the broad timer-reset recovery path that fails specifically when the recovered pure timer waiter stops waking via the first manual wake with `reason=manual`, `vector=0`, and `timer_id=0`)
- optional bare-metal QEMU timer-reset timeout-interrupt recovery probe (wrapper over the broad timer-reset recovery path that fails specifically when the timeout-backed interrupt waiter stops preserving interrupt wait-kind, clearing only the timeout arm, and waking via the later real interrupt)
- optional bare-metal QEMU scheduler reset wake-clear probe (wrapper over the broad scheduler-reset mixed-state path that fails specifically when stale queued wakes survive `command_scheduler_reset` or leak back after idle ticks)
- optional bare-metal QEMU scheduler reset timer-clear probe (wrapper over the broad scheduler-reset mixed-state path that fails specifically when stale pending timer bookkeeping survives `command_scheduler_reset` or a fresh post-reset timer no longer rearms cleanly)
- optional bare-metal QEMU scheduler reset config-preservation probe (wrapper over the broad scheduler-reset mixed-state path that fails specifically when timer quantum or `next_timer_id` drift across `command_scheduler_reset`, or the first fresh re-arm stops reusing the preserved `next_timer_id`)
- optional bare-metal QEMU interrupt filter probe (`task_wait_interrupt(any)` wakes on vector `200`, vector-scoped `task_wait_interrupt(13)` ignores non-matching `200`, then wakes on matching `13`, and invalid vector `65536` is rejected with `-22` against the freestanding PVH artifact)
- optional bare-metal QEMU task-terminate interrupt-timeout probe (`command_task_terminate` on a `task_wait_interrupt_for` waiter clears the timeout arm and wait state, leaves no wake-queue residue, prevents later ghost interrupt/timeout wake delivery for the terminated task, and keeps `timer_dispatch_count=0` against the freestanding PVH artifact)
- optional bare-metal QEMU task-terminate mixed-state probe (live mixed `command_task_wait_for`, `command_scheduler_wake_task`, survivor wake, and `command_task_terminate` proof, validating current timer-cancel-on-manual-wake semantics plus targeted wake-queue cleanup for the terminated task against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt-timeout arm-preservation probe (wrapper over the broad interrupt-timeout interrupt-wins path that fails specifically when the waiter stops preserving its armed timeout identity, interrupt wait-kind, and zero wake-queue state immediately before the interrupt lands)
- optional bare-metal QEMU interrupt-timeout interrupt-wake-payload probe (wrapper over the broad interrupt-timeout interrupt-wins path that fails specifically when the first wake stops being the exact `interrupt@31` payload for the waiting task with `timer_id=0`)
- optional bare-metal QEMU interrupt-timeout wait-clear probe (wrapper over the broad interrupt-timeout interrupt-wins path that fails specifically when the interrupt wake stops clearing wait-kind/vector/timeout state and the timer table back to idle)
- optional bare-metal QEMU interrupt-timeout no-stale-timer probe (wrapper over the broad interrupt-timeout interrupt-wins path that fails specifically when extra slack ticks after the interrupt start leaking a second wake or timer dispatch activity)
- optional bare-metal QEMU interrupt-timeout telemetry-preserve probe (wrapper over the broad interrupt-timeout interrupt-wins path that fails specifically when the interrupt-first recovery stops preserving interrupt count/vector telemetry and the shared last-wake tick)
- optional bare-metal QEMU timer-disable interrupt probe (`command_timer_disable` suppresses timer dispatch while `command_trigger_interrupt` still wakes an interrupt waiter immediately, and the deferred one-shot timer wake is only delivered after `command_timer_enable` against the freestanding PVH artifact)
- optional bare-metal QEMU timer-disable interrupt immediate-wake probe (wrapper over the broad timer-disable interrupt path that fails specifically when the interrupt waiter stops waking first with `reason=interrupt`, `vector=200`, `timer_id=0`, and zero timer-first misclassification)
- optional bare-metal QEMU timer-disable interrupt arm-preservation probe (wrapper over the broad timer-disable interrupt path that fails specifically when the pure one-shot waiter stops preserving its armed timer entry immediately after the interrupt while timers remain disabled)
- optional bare-metal QEMU timer-disable interrupt paused-window probe (wrapper over the broad timer-disable interrupt path that fails specifically when the disabled pause window stops preserving the armed entry, waiting task state, single queued interrupt wake, and zero timer-dispatch drift)
- optional bare-metal QEMU timer-disable interrupt deferred-timer-wake probe (wrapper over the broad timer-disable interrupt path that fails specifically when the later one-shot wake stops appearing only after `command_timer_enable` with `reason=timer`, `vector=0`, and the original `timer_id`)
- optional bare-metal QEMU timer-disable interrupt telemetry-preserve probe (wrapper over the broad timer-disable interrupt path that fails specifically when the deferred one-shot timer wake stops preserving the earlier interrupt count/vector telemetry)
- optional bare-metal QEMU periodic-interrupt baseline-fire probe (wrapper over the broad periodic-interrupt path that fails specifically when the first queued wake stops being the timer-driven baseline periodic fire for task `1` before the interrupt lands)
- optional bare-metal QEMU periodic-interrupt interrupt-wake-payload probe (wrapper over the broad periodic-interrupt path that fails specifically when the middle queued wake stops being the exact `interrupt@31` payload for task `2` before the timeout deadline)
- optional bare-metal QEMU periodic-interrupt periodic-cadence probe (wrapper over the broad periodic-interrupt path that fails specifically when the periodic source stops firing a second time after the interrupt wake or stops re-arming beyond the second fire tick)
- optional bare-metal QEMU periodic-interrupt cancel-no-late-timeout probe (wrapper over the broad periodic-interrupt path that fails specifically when `command_timer_cancel_task` stops collapsing armed timer state to zero entries or the mixed lane starts leaking a late timeout wake after settlement)
- optional bare-metal QEMU periodic-interrupt telemetry-ordering probe (wrapper over the broad periodic-interrupt path that fails specifically when mixed timer/interrupt telemetry or wake ordering stop remaining coherent across the full settle window)
- optional bare-metal QEMU panic-recovery probe (`command_trigger_panic_flag` freezes dispatch and budget burn under active load, `command_set_mode(mode_running)` resumes the same task immediately, and `command_set_boot_phase(runtime)` restores boot diagnostics against the freestanding PVH artifact)
- optional bare-metal QEMU panic-recovery wrapper probes (five isolated checks over the same broad lane: pre-panic baseline state, panic freeze-state, idle panic preservation, mode-recovery resume semantics, and final recovered task-state telemetry)
- optional bare-metal QEMU panic-wake recovery probe (`command_trigger_panic_flag` preserves interrupt + timer wake delivery while dispatch stays frozen, then `command_set_mode(mode_running)` and `command_set_boot_phase(runtime)` resume the preserved ready queue in order against the freestanding PVH artifact)
- optional bare-metal QEMU panic-wake recovery wrapper probes (five isolated checks over the same broad lane: pre-panic waiting baseline, panic freeze-state, preserved interrupt+timer wake queue delivery, mode-recovery dispatch resume, and final recovered task-state telemetry)
- optional bare-metal QEMU manual-wait interrupt probe (`task_wait` remains blocked with `wake_queue_len=0` and manual wait-kind intact after interrupt `44`, then recovers via explicit `scheduler_wake_task` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue selective probe (timer, interrupt, and manual wake generation plus `pop_reason`, `pop_vector`, `pop_reason_vector`, and `pop_before_tick` queue drains, with live vector/reason+vector/before-tick telemetry snapshot checks against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue selective wrapper validation (five isolated wrappers over the same mixed queue lane, failing directly on baseline queue composition, reason drain, vector drain, exact reason+vector drain, and the final before-tick/invalid-pair preserved-state boundary against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue reason-pop probe (dedicated `command_wake_queue_pop_reason` lane on a small mixed queue, proving FIFO removal of only the matching `interrupt` wakes and invalid-reason rejection without vector/overflow setup noise)
- optional bare-metal QEMU wake-queue reason-pop wrapper validation (baseline queue composition, first matching-pop survivor ordering, final manual-only survivor ordering, invalid-reason rejection, and invalid-reason nonmutation on the dedicated four-entry mixed queue lane)
- optional bare-metal QEMU wake-queue vector-pop probe (dedicated `command_wake_queue_pop_vector` lane on a small mixed queue, proving FIFO removal of only matching vector `13` wakes and invalid-vector rejection without overflow setup noise)
- optional bare-metal QEMU wake-queue vector-pop wrapper validation (baseline queue composition, first matching-vector survivor ordering, final manual-plus-`31` survivor ordering, invalid-vector rejection, and invalid-vector nonmutation on the dedicated four-entry mixed queue lane)
- optional bare-metal QEMU wake-queue before-tick probe (dedicated `command_wake_queue_pop_before_tick` lane on a small mixed queue, proving single oldest stale removal, bounded deadline-window drain, and final `result_not_found` without overflow setup noise)
- optional bare-metal QEMU wake-queue selective-overflow probe (wrapped 64-entry interrupt wake ring selective drain proof, preserving FIFO survivor ordering after `pop_vector(13,31)` and final `pop_reason_vector(interrupt@13)` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue selective-overflow wrapper probes (`baremetal-qemu-wake-queue-selective-overflow-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-selective-overflow-vector-drain-probe-check.ps1`, `baremetal-qemu-wake-queue-selective-overflow-vector-survivors-probe-check.ps1`, `baremetal-qemu-wake-queue-selective-overflow-reason-vector-drain-probe-check.ps1`, and `baremetal-qemu-wake-queue-selective-overflow-reason-vector-survivors-probe-check.ps1`) fail directly on the wrapped-ring baseline, post-vector collapse, lone retained `interrupt@13` survivor ordering, post-reason+vector collapse, and final all-`vector=31` survivor ordering against the freestanding PVH artifact
- optional bare-metal QEMU wake-queue before-tick-overflow probe (wrapped 64-entry interrupt wake ring deadline-drain proof, preserving FIFO survivor ordering through two `pop_before_tick` threshold drains and a final empty-queue `result_not_found` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue before-tick-overflow wrapper probes (`baremetal-qemu-wake-queue-before-tick-overflow-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-before-tick-overflow-first-cutoff-probe-check.ps1`, `baremetal-qemu-wake-queue-before-tick-overflow-first-survivor-window-probe-check.ps1`, `baremetal-qemu-wake-queue-before-tick-overflow-second-cutoff-probe-check.ps1`, and `baremetal-qemu-wake-queue-before-tick-overflow-final-empty-preserve-probe-check.ps1`) reuse the broad wrapped deadline-drain lane and fail directly on the wrapped baseline, first threshold cutoff, first survivor window, second cutoff to only `seq=66`, and final empty/notfound preserved-state invariants
- optional bare-metal QEMU wake-queue before-tick wrapper probes (`baremetal-qemu-wake-queue-before-tick-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-before-tick-first-cutoff-probe-check.ps1`, `baremetal-qemu-wake-queue-before-tick-bounded-drain-probe-check.ps1`, `baremetal-qemu-wake-queue-before-tick-notfound-probe-check.ps1`, and `baremetal-qemu-wake-queue-before-tick-notfound-preserve-state-probe-check.ps1`) reuse the broad stale-entry lane and fail directly on baseline queue composition, first stale cutoff, bounded second drain to the final survivor, final `result_not_found`, and preserved final survivor state after the rejected drain
- optional bare-metal QEMU wake-queue reason-overflow probe (wrapped 64-entry mixed `manual`/`interrupt` wake ring drain proof, preserving FIFO survivor ordering through `pop_reason(manual,31)` and final `pop_reason(manual,99)` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue reason-overflow wrapper probes (`baremetal-qemu-wake-queue-reason-overflow-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-reason-overflow-manual-drain-probe-check.ps1`, `baremetal-qemu-wake-queue-reason-overflow-manual-survivors-probe-check.ps1`, `baremetal-qemu-wake-queue-reason-overflow-interrupt-drain-probe-check.ps1`, and `baremetal-qemu-wake-queue-reason-overflow-interrupt-survivors-probe-check.ps1`) reuse the broad wrapped mixed-reason lane and fail directly on the overflow baseline, post-manual drain collapse, lone retained manual survivor ordering, post-final manual drain collapse, and final all-interrupt survivor ordering
- optional bare-metal QEMU wake-queue FIFO probe (`command_wake_queue_pop` removes the logical oldest wake first, preserves the second queued manual wake as the new head, and returns `result_not_found` once the queue is empty)
- optional bare-metal QEMU wake-queue FIFO wrapper probes (`baremetal-qemu-wake-queue-fifo-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-fifo-first-pop-probe-check.ps1`, `baremetal-qemu-wake-queue-fifo-survivor-probe-check.ps1`, `baremetal-qemu-wake-queue-fifo-drain-empty-probe-check.ps1`, and `baremetal-qemu-wake-queue-fifo-notfound-preserve-probe-check.ps1`) reuse the broad FIFO lane and fail directly on the two-entry baseline, first-pop oldest-first removal, survivor payload preservation, drained-empty collapse, and final `result_not_found` plus empty-state invariants
- optional bare-metal QEMU wake-queue summary/age probe (exported `oc_wake_queue_summary_ptr` and `oc_wake_queue_age_buckets_ptr_quantum_2` snapshots before and after selective queue drains against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue summary/age wrapper probes (`baremetal-qemu-wake-queue-summary-age-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-summary-age-pre-summary-probe-check.ps1`, `baremetal-qemu-wake-queue-summary-age-pre-age-probe-check.ps1`, `baremetal-qemu-wake-queue-summary-age-post-summary-probe-check.ps1`, and `baremetal-qemu-wake-queue-summary-age-post-age-probe-check.ps1`) reuse the broad exported-summary lane and fail directly on the five-entry baseline shape, pre-drain summary snapshot, pre-drain age-bucket snapshot, post-drain summary snapshot, and post-drain age-bucket plus final-stability invariants
- optional bare-metal QEMU wake-queue count snapshot probe (live `oc_wake_queue_count_query_ptr` / `oc_wake_queue_count_snapshot_ptr` proof over a mixed timer/interrupt/manual queue, validating vector, before-tick, and reason+vector counts at three query points against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue count snapshot wrapper probes (`baremetal-qemu-wake-queue-count-snapshot-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-count-snapshot-query1-probe-check.ps1`, `baremetal-qemu-wake-queue-count-snapshot-query2-probe-check.ps1`, `baremetal-qemu-wake-queue-count-snapshot-query3-probe-check.ps1`, and `baremetal-qemu-wake-queue-count-snapshot-nonmutating-read-probe-check.ps1`) reuse the broad count-snapshot lane and fail directly on baseline ordering, staged query deltas, and nonmutating mailbox-read invariants
- optional bare-metal QEMU wake-queue overflow probe (sustained manual wake pressure over one waiting task, proving the 64-entry ring retains the newest window with `overflow=2` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue overflow wrapper probes (`baremetal-qemu-wake-queue-overflow-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-overflow-shape-probe-check.ps1`, `baremetal-qemu-wake-queue-overflow-oldest-entry-probe-check.ps1`, `baremetal-qemu-wake-queue-overflow-newest-entry-probe-check.ps1`, and `baremetal-qemu-wake-queue-overflow-mailbox-state-probe-check.ps1`) reuse the broad sustained-manual-pressure lane and fail directly on the `66`-wake baseline, wrapped ring shape, oldest retained payload, newest retained payload, and final mailbox receipt
- optional bare-metal QEMU wake-queue clear wrapper probes (`baremetal-qemu-wake-queue-clear-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-clear-collapse-probe-check.ps1`, `baremetal-qemu-wake-queue-clear-pending-reset-probe-check.ps1`, `baremetal-qemu-wake-queue-clear-reuse-shape-probe-check.ps1`, and `baremetal-qemu-wake-queue-clear-reuse-payload-probe-check.ps1`) reuse the broad clear-and-reuse lane and fail directly on the wrapped baseline, post-clear ring collapse, post-clear pending-wake reset, post-reuse queue shape, and post-reuse payload invariants
- optional bare-metal QEMU wake-queue batch-pop probe (post-overflow batch-drain and refill proof over one waiting task, proving survivor ordering `65/66`, empty recovery, and reuse at `seq=67` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue batch-pop wrapper probes (`baremetal-qemu-wake-queue-batch-pop-overflow-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-batch-pop-survivor-pair-probe-check.ps1`, `baremetal-qemu-wake-queue-batch-pop-single-survivor-probe-check.ps1`, `baremetal-qemu-wake-queue-batch-pop-drain-empty-probe-check.ps1`, and `baremetal-qemu-wake-queue-batch-pop-refill-reuse-probe-check.ps1`) reuse the broad batch-pop lane and fail directly on overflow baseline, survivor-pair, single-survivor, drained-empty, and refill/reuse boundaries
- optional bare-metal QEMU wake-queue reason-vector-pop probe (dedicated exact-pair drain proof over a four-entry `manual` / `interrupt@13` / `interrupt@13` / `interrupt@19` queue, preserving surrounding FIFO survivors while rejecting `reason+vector=0` against the freestanding PVH artifact)
- optional bare-metal QEMU wake-queue reason-vector-pop wrapper probes (`baremetal-qemu-wake-queue-reason-vector-pop-baseline-probe-check.ps1`, `baremetal-qemu-wake-queue-reason-vector-pop-first-match-probe-check.ps1`, `baremetal-qemu-wake-queue-reason-vector-pop-survivor-order-probe-check.ps1`, `baremetal-qemu-wake-queue-reason-vector-pop-invalid-pair-probe-check.ps1`, and `baremetal-qemu-wake-queue-reason-vector-pop-invalid-preserve-state-probe-check.ps1`) reuse the broad exact-pair lane and fail directly on baseline composition, first exact-pair removal, final survivor ordering, invalid-pair rejection, and invalid-pair nonmutation
- optional bare-metal QEMU wake-queue vector-pop probe (dedicated `command_wake_queue_pop_vector` proof over a four-entry mixed queue, proving only vector `13` wakes are removed in FIFO order and the final vector `255` drain returns `result_not_found` against the freestanding PVH artifact)
- optional bare-metal QEMU allocator syscall probe (alloc/free plus syscall register/invoke/block/disable/re-enable/clear-flags/unregister, then live `command_allocator_reset` + `command_syscall_reset` recovery proof against the freestanding PVH artifact)
- optional bare-metal QEMU allocator syscall reset probe (dirty allocator alloc plus syscall register/invoke state, then dedicated `command_allocator_reset` + `command_syscall_reset` recovery proof showing both subsystems collapse independently back to steady baseline against the freestanding PVH artifact)
- optional bare-metal QEMU syscall saturation probe (fill the 64-entry syscall table, reject the 65th `register`, reclaim one slot with `unregister`, reuse it with a fresh syscall ID/token, and prove the reused slot invokes cleanly against the freestanding PVH artifact)
- optional bare-metal QEMU syscall saturation reset probe (fill the 64-entry syscall table, dirty dispatch telemetry with a real invoke, run `command_syscall_reset`, prove the fully saturated table returns to steady state, and then prove a fresh syscall restarts cleanly from slot `0` against the freestanding PVH artifact)
- optional bare-metal QEMU allocator saturation reset probe (fill all 64 allocator records, reject the next `command_allocator_alloc` with `no_space`, run `command_allocator_reset`, prove counters/bitmap/records collapse to steady state, and then prove a fresh 2-page allocation restarts cleanly from slot `0` against the freestanding PVH artifact)
- optional bare-metal QEMU allocator saturation reuse probe (fill all 64 allocator records, reject the next `command_allocator_alloc` with `no_space`, free allocator record slot `5`, prove the slot becomes reusable while the table returns to full occupancy, and prove first-fit page search lands on pages `64-65` against the freestanding PVH artifact)
- optional bare-metal QEMU allocator free failure probe (allocate 2 pages, prove wrong-pointer `command_allocator_free` returns `result_not_found`, wrong-size returns `result_invalid_argument`, successful free updates `last_free_*`, double-free returns `result_not_found`, and a fresh allocation restarts from page `0` against the freestanding PVH artifact)
- optional bare-metal QEMU syscall control probe (isolated live `command_syscall_register` re-register, `command_syscall_set_flags`, blocked invoke, disable/enable, successful invoke, unregister, and missing-entry mutation proof against the freestanding PVH artifact)
- optional bare-metal QEMU syscall wrapper validation batch (wrapper probes over the broad syscall lanes, isolating re-register token-update/no-growth, blocked invoke preservation, disabled invoke preservation, saturation overflow full-table retention, slot reuse semantics, and post-reset slot-zero restart)
- optional bare-metal QEMU allocator syscall failure probe (invalid-alignment, no-space, blocked-syscall, and disabled-syscall result semantics plus command-result counters against the freestanding PVH artifact)
- optional bare-metal QEMU command-result counters probe (live mailbox result-category accounting plus `command_reset_command_result_counters` reset semantics against the freestanding PVH artifact)
- optional bare-metal QEMU reset counters probe (live `command_reset_counters` proof after dirtying interrupt, exception, scheduler, allocator, syscall, timer, wake-queue, mode, boot-phase, command-history, and health-history state against the freestanding PVH artifact)
- optional bare-metal QEMU task lifecycle probe (live `task_wait -> scheduler_wake_task -> task_resume -> task_terminate` control path plus post-terminate rejected wake semantics, including queue purge for the terminated task, against the freestanding PVH artifact)
- optional bare-metal QEMU task-lifecycle wrapper probes (five isolated checks over the same broad lane: initial wait baseline, first manual wake delivery, second wait baseline, second manual wake delivery after `command_task_resume`, and final terminate plus rejected-wake telemetry with queue purge for the terminated task against the freestanding PVH artifact)
- optional bare-metal QEMU active-task terminate probe (live `command_task_terminate` against the currently running high-priority task, proving immediate failover to the remaining ready task, idempotent repeat terminate semantics, and final empty-run collapse against the freestanding PVH artifact)
- optional bare-metal QEMU active-task terminate wrapper probes (five isolated checks over the same broad lane: pre-terminate active baseline, immediate failover after the first terminate, repeat-idempotent receipt, survivor low-task progress after the repeat terminate, and final empty-run collapse telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt mask exception probe (masked external vector remains blocked while an exception vector still wakes the waiting task and records history telemetry against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt mask profile probe (external-all, custom unmask/remask, ignored-count reset, external-high, invalid profile rejection, and clear-all recovery against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt mask control probe (direct `command_interrupt_mask_set`, invalid vector/state rejection, ignored-count reset, and final `clear_all` recovery against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt mask clear-all recovery probe (dedicated `command_interrupt_mask_clear_all` proof after direct mask manipulation, showing wake delivery resumes, ignored-count telemetry collapses back to `0`, and the runtime returns to profile `none` against the freestanding PVH artifact)
- optional bare-metal QEMU interrupt mask custom-profile preserve probe (wrapper over the profile probe that isolates the `custom` profile drift contract, per-vector ignored counts, and last-masked vector retention without relying on later cleanup stages)
- optional bare-metal QEMU interrupt mask invalid-input preserve-state probe (wrapper over the control probe that isolates invalid vector/state rejection and proves those failures do not clobber the live custom-profile mask state)
- optional bare-metal QEMU interrupt mask reset-ignored preserve-mask probe (wrapper over the profile probe that isolates `command_interrupt_mask_reset_ignored_counts` and proves it clears ignored-count telemetry without mutating the active custom mask table)
- optional bare-metal QEMU interrupt mask profile boundary probe (wrapper over the profile probe that isolates the `external_high` `63/64` boundary and invalid-profile rejection while preserving the active profile)
- optional bare-metal QEMU interrupt mask exception-delivery probe (wrapper over the exception probe that isolates masked external suppression plus non-maskable exception wake delivery and matching interrupt/exception telemetry)
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
- bare-metal optional QEMU feature-flags set-success probe in validate stage
- bare-metal optional QEMU tick-batch valid-update probe in validate stage
- bare-metal optional QEMU tick-batch invalid-preserve probe in validate stage
- bare-metal optional QEMU feature-flags tick-batch mailbox-state probe in validate stage
- bare-metal optional QEMU feature-flags tick-batch state-preserve probe in validate stage
- bare-metal optional QEMU scheduler probe in validate stage
- bare-metal optional QEMU scheduler timeslice-update probe in validate stage
- bare-metal optional QEMU scheduler timeslice baseline probe in validate stage
- bare-metal optional QEMU scheduler timeslice update-4 probe in validate stage
- bare-metal optional QEMU scheduler timeslice update-2 probe in validate stage
- bare-metal optional QEMU scheduler timeslice invalid-zero preserve probe in validate stage
- bare-metal optional QEMU scheduler timeslice final task-state probe in validate stage
- bare-metal optional QEMU scheduler disable-enable probe in validate stage
- bare-metal optional QEMU scheduler disable-enable baseline probe in validate stage
- bare-metal optional QEMU scheduler disable-enable disabled-freeze probe in validate stage
- bare-metal optional QEMU scheduler disable-enable idle-preserve probe in validate stage
- bare-metal optional QEMU scheduler disable-enable resume probe in validate stage
- bare-metal optional QEMU scheduler disable-enable final task-state probe in validate stage
- bare-metal optional QEMU scheduler reset probe in validate stage
- bare-metal optional QEMU scheduler reset mixed-state probe in validate stage
- bare-metal optional QEMU scheduler reset wake-clear probe in validate stage
- bare-metal optional QEMU scheduler reset timer-clear probe in validate stage
- bare-metal optional QEMU scheduler reset config-preservation probe in validate stage
- bare-metal optional QEMU scheduler policy-switch probe in validate stage
- bare-metal optional QEMU scheduler policy-switch rr-baseline probe in validate stage
- bare-metal optional QEMU scheduler policy-switch priority-dominance probe in validate stage
- bare-metal optional QEMU scheduler policy-switch reprioritize-low probe in validate stage
- bare-metal optional QEMU scheduler policy-switch rr-return probe in validate stage
- bare-metal optional QEMU scheduler policy-switch invalid-preserve probe in validate stage
- bare-metal optional QEMU scheduler saturation probe in validate stage
- bare-metal optional QEMU scheduler saturation wrapper probes in validate stage
- bare-metal optional QEMU timer wake probe in validate stage
- bare-metal optional QEMU timer quantum probe in validate stage
- bare-metal optional QEMU timer cancel probe in validate stage
- bare-metal optional QEMU timer cancel wrapper probes in validate stage
- bare-metal optional QEMU timer cancel-task interrupt-timeout probe in validate stage
- bare-metal optional QEMU timer cancel task probe in validate stage
- bare-metal optional QEMU timer pressure wrapper probes in validate stage
- bare-metal optional QEMU timer reset recovery probe in validate stage
- bare-metal optional QEMU timer-disable reenable arm-preservation probe in validate stage
- bare-metal optional QEMU timer-disable reenable deadline-hold probe in validate stage
- bare-metal optional QEMU timer-disable reenable deferred-wake-order probe in validate stage
- bare-metal optional QEMU timer-disable reenable wake-payload probe in validate stage
- bare-metal optional QEMU timer-disable reenable dispatch-drain probe in validate stage
- bare-metal optional QEMU timer-reset wait-kind isolation probe in validate stage
- bare-metal optional QEMU task-resume timer-clear probe in validate stage
- bare-metal optional QEMU task-resume interrupt-timeout probe in validate stage
- bare-metal optional QEMU scheduler-wake timer-clear probe in validate stage
- bare-metal optional QEMU task-resume interrupt probe in validate stage
- bare-metal optional QEMU periodic timer probe in validate stage
- bare-metal optional QEMU periodic interrupt probe in validate stage
- bare-metal optional QEMU interrupt timeout probe in validate stage
- bare-metal optional QEMU interrupt timeout manual-wake probe in validate stage
- bare-metal optional QEMU interrupt manual-wake probe in validate stage
- bare-metal optional QEMU interrupt timeout timer probe in validate stage
- bare-metal optional QEMU masked interrupt timeout probe in validate stage
- bare-metal optional QEMU masked interrupt timeout wrapper probes in validate stage
- bare-metal optional QEMU interrupt timeout clamp probe in validate stage
- bare-metal optional QEMU timer-disable reenable probe in validate stage
- bare-metal optional QEMU timer-disable paused-state probe in validate stage
- bare-metal optional QEMU timer-disable reenable one-shot recovery probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-enable probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-enable arm-preservation probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-enable deadline-hold probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-enable paused-window probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-enable deferred-timer-wake probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-enable telemetry-preserve probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-reenable timer probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-interrupt probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-interrupt immediate-wake probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-interrupt timeout-clear probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-interrupt disabled-state probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-interrupt reenable-no-stale-timer probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-interrupt telemetry-preserve probe in validate stage
- bare-metal optional QEMU interrupt-timeout disable-interrupt recovery probe in validate stage
- bare-metal optional QEMU timer-disable interrupt immediate-wake probe in validate stage
- bare-metal optional QEMU timer-disable interrupt arm-preservation probe in validate stage
- bare-metal optional QEMU timer-disable interrupt paused-window probe in validate stage
- bare-metal optional QEMU timer-disable interrupt deferred-timer-wake probe in validate stage
- bare-metal optional QEMU timer-disable interrupt telemetry-preserve probe in validate stage
- bare-metal optional QEMU interrupt-timeout arm-preservation probe in validate stage
- bare-metal optional QEMU interrupt-timeout interrupt-wake-payload probe in validate stage
- bare-metal optional QEMU interrupt-timeout wait-clear probe in validate stage
- bare-metal optional QEMU interrupt-timeout no-stale-timer probe in validate stage
- bare-metal optional QEMU interrupt-timeout telemetry-preserve probe in validate stage
- bare-metal optional QEMU interrupt filter probe in validate stage
- bare-metal optional QEMU task-terminate interrupt-timeout probe in validate stage
- bare-metal optional QEMU task-terminate mixed-state probe in validate stage
- bare-metal optional QEMU manual-wait interrupt probe in validate stage
- bare-metal optional QEMU descriptor bootdiag probe in validate stage
- bare-metal optional QEMU bootdiag/history-clear probe in validate stage
- bare-metal optional QEMU descriptor table content probe in validate stage
- bare-metal optional QEMU descriptor dispatch probe in validate stage
- bare-metal optional QEMU vector counter reset probe in validate stage
- bare-metal optional QEMU vector history overflow probe in validate stage
- bare-metal optional QEMU vector history clear probe in validate stage
- bare-metal optional QEMU command-health history probe in validate stage
- bare-metal optional QEMU command-history overflow clear probe in validate stage
- bare-metal optional QEMU health-history overflow clear probe in validate stage
- bare-metal optional QEMU mailbox header validation probe in validate stage
- bare-metal optional QEMU mailbox stale-seq probe in validate stage
- bare-metal optional QEMU mailbox seq-wraparound probe in validate stage
- bare-metal optional QEMU mode/boot-phase history probe in validate stage
- bare-metal optional QEMU mode/boot-phase history clear probe in validate stage
- bare-metal optional QEMU mode-history overflow clear probe in validate stage
- bare-metal optional QEMU boot-phase-history overflow clear probe in validate stage
- bare-metal optional QEMU scheduler priority budget probe in validate stage
- bare-metal optional QEMU scheduler priority budget wrapper probes in validate stage
- bare-metal optional QEMU scheduler default-budget invalid probe in validate stage
- bare-metal optional QEMU scheduler round-robin probe in validate stage
- bare-metal optional QEMU scheduler round-robin wrapper probes in validate stage
- bare-metal optional QEMU wake-queue selective probe in validate stage
- bare-metal optional QEMU wake-queue selective wrapper probes in validate stage
- bare-metal optional QEMU wake-queue reason-pop probe in validate stage
- bare-metal optional QEMU wake-queue reason-pop wrapper probes in validate stage
- bare-metal optional QEMU wake-queue vector-pop probe in validate stage
- bare-metal optional QEMU wake-queue vector-pop wrapper probes in validate stage
- bare-metal optional QEMU wake-queue before-tick probe in validate stage
- bare-metal optional QEMU wake-queue selective-overflow probe in validate stage
- bare-metal optional QEMU wake-queue selective-overflow wrapper probes in validate stage
- bare-metal optional QEMU wake-queue before-tick-overflow probe in validate stage
- bare-metal optional QEMU wake-queue before-tick-overflow wrapper probes in validate stage
- bare-metal optional QEMU wake-queue before-tick wrapper probes in validate stage
- bare-metal optional QEMU wake-queue reason-overflow probe in validate stage
- bare-metal optional QEMU wake-queue reason-overflow wrapper probes in validate stage
- bare-metal optional QEMU wake-queue reason-vector-pop probe in validate stage
- bare-metal optional QEMU wake-queue reason-vector-pop wrapper probes in validate stage
- bare-metal optional QEMU wake-queue FIFO probe in validate stage
- bare-metal optional QEMU wake-queue FIFO wrapper probes in validate stage
- bare-metal optional QEMU wake-queue summary/age probe in validate stage
- bare-metal optional QEMU wake-queue summary/age wrapper probes in validate stage
- bare-metal optional QEMU wake-queue overflow probe in validate stage
- bare-metal optional QEMU wake-queue overflow wrapper probes in validate stage
- bare-metal optional QEMU wake-queue clear probe in validate stage
- bare-metal optional QEMU wake-queue clear wrapper probes in validate stage
- bare-metal optional QEMU wake-queue batch-pop probe in validate stage
- bare-metal optional QEMU wake-queue batch-pop wrapper probes in validate stage
- bare-metal optional QEMU wake-queue vector-pop probe in validate stage
- bare-metal optional QEMU allocator syscall probe in validate stage
- bare-metal optional QEMU allocator syscall reset probe in validate stage
- bare-metal optional QEMU syscall saturation probe in validate stage
- bare-metal optional QEMU syscall saturation reset probe in validate stage
- bare-metal optional QEMU allocator saturation reset probe in validate stage
- bare-metal optional QEMU allocator saturation reuse probe in validate stage
- bare-metal optional QEMU allocator free failure probe in validate stage
- bare-metal optional QEMU syscall control probe in validate stage
- bare-metal optional QEMU syscall reregister preserve-count probe in validate stage
- bare-metal optional QEMU syscall blocked-invoke preserve-state probe in validate stage
- bare-metal optional QEMU syscall disabled-invoke preserve-state probe in validate stage
- bare-metal optional QEMU syscall saturation overflow preserve-full probe in validate stage
- bare-metal optional QEMU syscall saturation reuse-slot probe in validate stage
- bare-metal optional QEMU syscall saturation-reset restart probe in validate stage
- bare-metal optional QEMU allocator syscall failure probe in validate stage
- bare-metal optional QEMU allocator/syscall reset wrapper probes in validate stage
- bare-metal optional QEMU command-result counters probe in validate stage
- bare-metal optional QEMU reset counters probe in validate stage
- bare-metal optional QEMU reset-command-result preserve-runtime probe in validate stage
- bare-metal optional QEMU reset-counters preserve-config probe in validate stage
- bare-metal optional QEMU reset-bootdiag preserve-state probe in validate stage
- bare-metal optional QEMU clear-command-history preserve-health probe in validate stage
- bare-metal optional QEMU clear-health-history preserve-command probe in validate stage
- command-result / bootdiag-history-clear / reset-counters wrapper probes now enforce isolated reset-preservation boundaries for runtime state, histories, and config as dedicated workflow gates
- bare-metal optional QEMU task lifecycle probe in validate stage
- bare-metal optional QEMU active-task terminate probe in validate stage
- bare-metal optional QEMU panic-recovery probe in validate stage
- bare-metal optional QEMU panic-wake recovery probe in validate stage
- bare-metal optional QEMU interrupt mask exception probe in validate stage
- bare-metal optional QEMU interrupt mask profile probe in validate stage
- bare-metal optional QEMU interrupt mask control probe in validate stage
- bare-metal optional QEMU interrupt mask clear-all recovery probe in validate stage
- bare-metal optional QEMU interrupt mask custom-profile preserve probe in validate stage
- bare-metal optional QEMU interrupt mask invalid-input preserve-state probe in validate stage
- bare-metal optional QEMU interrupt mask reset-ignored preserve-mask probe in validate stage
- bare-metal optional QEMU interrupt mask profile boundary probe in validate stage
- bare-metal optional QEMU interrupt mask exception-delivery probe in validate stage
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
./scripts/zig-github-mirror-release-check.ps1
./scripts/zig-bootstrap-from-github-mirror.ps1 -DryRun
```

Track local/remote mismatch in:

- `docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md`

Policy:

- Use Codeberg `master` as the canonical freshness target.
- Use `adybag14-cyber/zig` `latest-master` when the goal is a fast Windows toolchain refresh.
- Use `adybag14-cyber/zig` `upstream-<sha>` when the goal is reproducible CI, bisects, or release recreation.


