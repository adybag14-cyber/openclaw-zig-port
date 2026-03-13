# OpenClaw Zig Port

Zig runtime port of OpenClaw with parity-first delivery, deterministic validation gates, and Lightpanda-only browser bridge policy.

## Current Status

- RPC method surface in Zig: `174`
- Pinned parity gate (tri-baseline, CI/docs):
  - Go baseline (`v2.14.0-go`): `134/134` covered
- Original OpenClaw baseline (`v2026.3.11`): `99/99` covered
- Original OpenClaw beta baseline (`v2026.3.11-beta.1`): `99/99` covered
- Union baseline: `140/140` covered (`MISSING_IN_ZIG=0`)
  - Gateway events: stable `19/19`, beta `19/19`, union `19/19` (`UNION_EVENTS_MISSING_IN_ZIG=0`)
- Latest local validation: `zig build test --summary all` -> main `223/223` + bare-metal host `141/141` passing
- Latest published edge release tag: `v0.2.0-zig-edge.28`
- Toolchain policy: Codeberg `master` is canonical; `adybag14-cyber/zig` publishes rolling `latest-master` and immutable `upstream-<sha>` Windows releases for refresh and reproducibility.
- CI policy: keep hosted build/test/parity/docs on Zig `master`, but pin the freestanding bare-metal compile/probe lane to the known-good Linux build `0.16.0-dev.2736+3b515fbed` until the upstream Linux `master` compiler crash on `zig build baremetal -Doptimize=ReleaseFast` is resolved.
- Recent FS1 progress (2026-03-06):
  - runtime recovery posture is now surfaced on live diagnostics and maintenance RPCs
  - `doctor.memory.status` now includes Go-visible health envelope fields
  - `agent.identity.get` now reports stable `startedAt` + gateway `authMode`
  - `status` now includes Go-visible summary keys alongside Zig runtime/security telemetry
  - strict FS1 runtime/core closure is now reached locally: `node.pending.enqueue` + `node.pending.drain` are implemented and the parity gate is at zero missing methods against Go + stable + beta
- Recent FS4 progress (2026-03-12):
  - `secrets.store.status` now reports backend truth explicitly instead of implying native-provider support
  - support levels are now explicit for `env`, `encrypted-file`, native fallback requests, and unsupported backend requests
  - strict FS4 secret-store lifecycle is now smoke-gated via `scripts/security-secret-store-smoke-check.ps1`
- Current strict hosted-phase focus:
  - `FS2` provider/channel completion is locally closed against the hard matrix at [`docs/zig-port/FS2_PROVIDER_CHANNEL_MATRIX.md`](docs/zig-port/FS2_PROVIDER_CHANNEL_MATRIX.md)
  - `FS3` memory/knowledge depth is now locally closed against the hard matrix at [`docs/zig-port/FS3_MEMORY_KNOWLEDGE_MATRIX.md`](docs/zig-port/FS3_MEMORY_KNOWLEDGE_MATRIX.md)
  - `browser-request-memory-context-smoke-check.ps1` and `telegram-reply-memory-context-smoke-check.ps1` are now part of the strict FS3 CI lane
  - `FS5` is now locally strict-closed through the hard matrix at [`docs/zig-port/FS5_EDGE_WASM_FINETUNE_MATRIX.md`](docs/zig-port/FS5_EDGE_WASM_FINETUNE_MATRIX.md)
  - `edge-wasm-lifecycle-smoke-check.ps1` and `edge-finetune-lifecycle-smoke-check.ps1` are now part of the strict FS5 CI lane
  - strict FS4 matrix source is [`docs/zig-port/FS4_SECURITY_TRUST_MATRIX.md`](docs/zig-port/FS4_SECURITY_TRUST_MATRIX.md)
- Current hardware pivot (`FS5.5`):
  - framebuffer/console is now strict-closed in [`docs/zig-port/FS5_5_HARDWARE_DRIVERS_SYSTEMS.md`](docs/zig-port/FS5_5_HARDWARE_DRIVERS_SYSTEMS.md)
  - `src/baremetal/framebuffer_console.zig` now contains a real Bochs/QEMU BGA linear-framebuffer console path
  - `src/baremetal/pci.zig` discovers the display BAR and enables decode on the selected PCI display function
  - `src/pal/framebuffer.zig` exposes the framebuffer path through the bare-metal PAL
  - `scripts/baremetal-qemu-framebuffer-console-probe-check.ps1` proves live MMIO banner pixels against the freestanding PVH artifact
  - keyboard/mouse is now strict-closed in [`docs/zig-port/FS5_5_HARDWARE_DRIVERS_SYSTEMS.md`](docs/zig-port/FS5_5_HARDWARE_DRIVERS_SYSTEMS.md)
  - `src/baremetal/ps2_input.zig` now contains a real x86 port-I/O backed PS/2 controller path
  - `scripts/baremetal-qemu-ps2-input-probe-check.ps1` proves IRQ-driven keyboard/mouse state updates against the freestanding PVH artifact
  - shared storage backend routing is now live through `src/baremetal/storage_backend.zig`
  - `src/baremetal/ata_pio_disk.zig` now provides a real ATA PIO path with `IDENTIFY`, `READ`, `WRITE`, and `FLUSH`
  - PAL storage and bare-metal tool-layout now route through the backend facade instead of talking directly to the RAM disk
  - `scripts/baremetal-qemu-ata-storage-probe-check.ps1` now proves live ATA-backed raw block mutation + readback plus ATA-backed tool-layout and filesystem persistence against the freestanding PVH artifact
  - Ethernet L2 is now strict-closed in [`docs/zig-port/FS5_5_HARDWARE_DRIVERS_SYSTEMS.md`](docs/zig-port/FS5_5_HARDWARE_DRIVERS_SYSTEMS.md)
  - `src/baremetal/rtl8139.zig` now contains the real RTL8139 PCI-discovered bring-up, raw-frame TX/RX path, and loopback-friendly datapath checks
  - `src/pal/net.zig` and `src/baremetal_main.zig` now expose the raw-frame PAL + bare-metal ABI/export surface through the same driver path
  - `scripts/baremetal-qemu-rtl8139-probe-check.ps1` now proves live MAC readout, TX, RX loopback, payload validation, and TX/RX counter advance against the freestanding PVH artifact
  - the first TCP/IP slices are now also live:
    - `src/protocol/ethernet.zig` + `src/protocol/arp.zig` provide Ethernet/ARP framing
    - `src/protocol/ipv4.zig` provides IPv4 header encode/decode plus checksum handling
    - `src/protocol/udp.zig` provides UDP encode/decode plus pseudo-header checksum handling
    - `src/pal/net.zig` now exposes `sendArpRequest` / `pollArpPacket`, `sendIpv4Frame` / `pollIpv4PacketStrict`, and `sendUdpPacket` / `pollUdpPacketStrictInto`
    - `scripts/baremetal-qemu-rtl8139-arp-probe-check.ps1`, `scripts/baremetal-qemu-rtl8139-ipv4-probe-check.ps1`, and `scripts/baremetal-qemu-rtl8139-udp-probe-check.ps1` now prove live ARP, IPv4, and UDP loopback/decode over the freestanding PVH artifact
  - TCP, DHCP, and DNS remain the next networking slices above the now-real Ethernet + ARP + IPv4 + UDP path
  - path-based filesystem usage is now locally strict-closed:
    - `src/baremetal/filesystem.zig` implements directory creation plus file read/write/stat on the shared storage backend
    - `src/pal/fs.zig` routes the freestanding PAL filesystem surface through that layer
    - hosted and host validation now prove persistence over both RAM-disk and ATA PIO backends
- Recent FS6 progress (2026-03-06):
  - `update.*` now has a real `canary` rollout lane instead of collapsing `canary` into `edge`
  - appliance rollout boundary is now enforced by live smoke validation (`canary` selection, secure-boot block, canary apply, stable promotion)
  - minimal appliance profile is now a live runtime contract surfaced in `status`, `doctor`, `system.boot.status`, and maintenance responses
  - appliance profile readiness is now enforced by live smoke validation (persisted state, control-plane auth, secure-boot gate, signer, current verification)
  - FS6 now has a single appliance/bare-metal closure gate (`scripts/appliance-baremetal-closure-smoke-check.ps1`) that composes appliance control-plane, minimal profile, rollout, restart recovery, bare-metal smoke, and the optional QEMU smoke/runtime/command-loop lane into one required receipt
  - Windows-local QEMU smoke exit-code capture is now normalized in the PVH smoke scripts, so the same FS6 closure gate validates cleanly on the workstation and in CI
  - bare-metal timer wake behavior is now enforced by a live QEMU+GDB probe (`command_timer_reset`, `command_timer_set_quantum`, `command_task_create`, `command_task_wait_for`) against the freestanding PVH artifact
  - bare-metal allocator/syscall behavior is now enforced by a live QEMU+GDB probe (`command_allocator_*`, `command_syscall_*`) including blocked and disabled syscall paths
  - bare-metal mixed task-termination cleanup is now enforced again by a live QEMU+GDB probe that validates the current timer-cancel-on-manual-wake semantics before `command_task_terminate`, targeted wake-queue cleanup for the terminated task, and idle stability without ghost timer delivery
  - bare-metal direct `command_wake_queue_pop_reason` control is now enforced by a live QEMU+GDB probe on a small mixed queue, proving FIFO removal of only matching `interrupt` wakes and invalid-reason rejection without vector/overflow noise
  - bare-metal direct `command_wake_queue_pop_vector` control now has a dedicated QEMU wrapper family that fails directly on baseline queue composition, first matching-vector survivor order, final manual-plus-`31` survivor order, invalid-vector rejection, and invalid-vector nonmutation on the dedicated four-entry mixed queue lane
  - bare-metal direct `command_wake_queue_pop_before_tick` control is now enforced by a live QEMU+GDB probe on a small mixed queue, proving single oldest stale removal, bounded deadline-window drain, and final `result_not_found` without overflow-only setup
  - bare-metal syscall saturation behavior is now enforced by a dedicated live QEMU+GDB probe that fills the 64-entry syscall table, rejects the 65th registration with `no_space`, reclaims one slot, and proves clean slot reuse plus invoke behavior
  - bare-metal syscall saturation reset recovery is now enforced by a dedicated live QEMU+GDB probe that fills the 64-entry syscall table, dirties dispatch telemetry with a real invoke, proves `command_syscall_reset` clears the fully saturated table back to steady state, and then proves a fresh syscall restarts cleanly from slot `0`
  - bare-metal allocator saturation reset recovery is now enforced by both the host suite and a dedicated live QEMU+GDB probe that fills all 64 allocator records, rejects the next allocation with `no_space`, proves `command_allocator_reset` collapses counters/bitmap/records back to steady state, and then proves a fresh 2-page allocation restarts cleanly from slot `0`
  - bare-metal allocator saturation reuse is now enforced by both the host suite and a dedicated live QEMU+GDB probe that fills all 64 allocator records, rejects the next allocation with `no_space`, frees record slot `5`, proves that slot becomes reusable while the table stays saturated after a fresh 2-page allocation, and proves first-fit page search advances to pages `64-65` when page `6` still blocks the freed region
  - bare-metal allocator free failure handling is now enforced by both the host suite and a dedicated live QEMU+GDB probe that proves wrong-pointer `not_found`, wrong-size `invalid_argument`, valid free recovery, double-free `not_found`, and clean reallocation from page `0` without clobbering `last_free_*` metadata
  - bare-metal allocator free failure wrapper isolation is now enforced by dedicated QEMU wrappers that fail directly on the initial allocation baseline, wrong-pointer `not_found` preservation, wrong-size `invalid_argument` preservation, successful free metadata update, and double-free plus clean realloc restart boundaries
  - bare-metal syscall control mutation behavior is now enforced by a dedicated live QEMU+GDB probe (`command_syscall_register`, `command_syscall_set_flags`, `command_syscall_disable`, `command_syscall_enable`, `command_syscall_unregister`) proving re-register, blocked/disabled invoke, successful invoke, and missing-entry mutation semantics against the freestanding PVH artifact
  - bare-metal syscall control wrapper isolation is now enforced by a dedicated direct stage family that fails directly on the register baseline, re-register token update without entry-count growth, blocked invoke state, enabled invoke telemetry, unregister cleanup, and final steady-state invariants
  - bare-metal syscall saturation/reset wrapper isolation remains enforced separately on the full-table overflow, reclaimed-slot reuse, and post-reset restart lanes
  - bare-metal allocator/syscall reset recovery is now enforced by both the host suite and the live QEMU+GDB probe, proving dirty allocator/syscall state is cleared by `command_allocator_reset` and `command_syscall_reset` after real alloc/register/invoke activity instead of only at setup time
  - bare-metal interrupt-mask/exception behavior is now enforced by a live QEMU+GDB probe (masked external interrupt remains blocked while exception delivery still wakes a waiting task and records interrupt/exception histories)
  - bare-metal interrupt-mask profile control is now enforced by a live QEMU+GDB probe (`command_interrupt_mask_apply_profile`, `command_interrupt_mask_set`, `command_interrupt_mask_reset_ignored_counts`, `command_interrupt_mask_clear_all`) covering external-all, custom unmask/remask, external-high, invalid profile rejection, and clear-all recovery
  - bare-metal interrupt-mask profile wrapper probes now enforce that lane directly too: external-all masked baseline, direct unmask wake recovery on vector `200`, `custom` profile drift plus ignored-count accumulation, ignored-count reset without mask-table mutation, and final `none` / `clear_all` recovery with preserved wake payload and ready task state
  - bare-metal scheduler-wake timer-clear recovery is now enforced by both the host suite and a dedicated live QEMU+GDB probe, proving `command_scheduler_wake_task` clears a pure timer wait, queues exactly one manual wake, prevents a later ghost timer wake, and preserves fresh timer allocation from the current `next_timer_id`
  - scheduler-wake timer-clear wrapper probes now enforce that lane directly too: pre-wake armed baseline, cleared wait/timer state after `command_scheduler_wake_task`, preserved canceled timer-entry state, exact manual wake payload, and final rearm/dispatch telemetry
  - bare-metal timer-cancel-task interrupt-timeout recovery is now enforced by both the host suite and a dedicated live QEMU+GDB probe, proving `command_timer_cancel_task` clears timeout-backed interrupt waits back to steady state without losing the later real interrupt wake path
  - bare-metal timer-cancel-task interrupt-timeout wrapper validation now fails directly on the armed timeout snapshot, immediate cancel-clear state, preserved interrupt-only recovery, no-stale-timeout settle window, and final mailbox/telemetry envelope on that dedicated cancel-task recovery lane
  - bare-metal interrupt-mask clear-all recovery is now enforced by a dedicated live QEMU+GDB probe, proving `command_interrupt_mask_clear_all` restores real interrupt wake delivery, clears ignored-count telemetry, and returns the runtime to the `none` profile after direct mask manipulation
  - bare-metal interrupt-mask clear-all recovery wrapper probes now enforce that lane directly too: masked baseline, clear-collapse of profile/masked-count/ignored telemetry, restored wake delivery, preserved single interrupt-history payload, and final mailbox-state invariants
  - bare-metal task-terminate interrupt-timeout cleanup is now enforced by both the host suite and a dedicated live QEMU+GDB probe, proving `command_task_terminate` clears timeout-backed interrupt waits, leaves no queued wake or timer residue, and prevents later ghost interrupt/timeout wake delivery for the terminated task
  - bare-metal panic freeze and recovery behavior is now enforced by a live QEMU+GDB probe (`command_trigger_panic_flag`, `command_set_mode(mode_running)`, `command_set_boot_phase(runtime)`) proving panic freezes dispatch cleanly, mode recovery resumes the same task immediately, and boot diagnostics stay panicked until explicitly restored
  - bare-metal periodic timer pause/resume behavior is now enforced by a live QEMU+GDB probe (`command_timer_schedule_periodic`, `command_timer_disable`, `command_timer_enable`) that snapshots the first resumed periodic fire against the freestanding PVH artifact
  - bare-metal periodic timer saturation behavior is now enforced by a live QEMU+GDB probe that arms a periodic timer at `u64::max-1`, proves the first fire lands at `18446744073709551615`, re-arms to the same saturated deadline instead of wrapping, and then holds stable after the runtime tick counter wraps to `0`
  - bare-metal periodic timer saturation now also has a dedicated QEMU wrapper family that fails directly on the baseline near-`u64::max` arm state, first-fire wrap semantics, saturated re-arm invariants, post-wrap hold stability, and final timer-wake telemetry instead of relying only on the broad clamp probe
  - `scripts/package-registry-status.ps1` now treats the resolved default npm/PyPI package names as the executable source of truth when called with only `-ReleaseTag`, so local release diagnostics correctly show public-registry `404` state instead of silently skipping checks
  - bare-metal wake-queue summary/age telemetry is now enforced by a live QEMU+GDB probe (`oc_wake_queue_summary_ptr`, `oc_wake_queue_age_buckets_ptr_quantum_2`) before and after selective queue drains over mixed timer/interrupt/manual wake queues
  - bare-metal selective wake-queue telemetry is now enforced by a live QEMU+GDB probe through a generic count-query snapshot helper (`oc_wake_queue_count_query_ptr`, `oc_wake_queue_count_snapshot_ptr`), proving live vector counts (`13`, `31`), exact reason+vector counts (`interrupt@31`), before-tick counts, and invalid `reason+vector=0` rejection in the same selective-drain run
  - bare-metal wake-queue reason-selective overflow behavior is now enforced by a live QEMU+GDB probe that drives `66` alternating manual / interrupt wake cycles through one task and proves `command_wake_queue_pop_reason` preserves FIFO survivor ordering across the wrapped ring (`seq 3 -> 66`, then `seq 4 -> 66`, then interrupt-only `seq 4 -> 66`)
  - bare-metal wake-queue overflow retention is now enforced by a live QEMU+GDB probe that drives `66` manual wakes through one waiting task and proves the 64-entry ring retains the newest window (`seq 3 -> 66`) with `overflow=2`
  - bare-metal wake-queue overflow retention now also has a dedicated QEMU wrapper family that fails directly on the `66`-wake baseline, wrapped ring shape (`count=64`, `head/tail=2`, `overflow=2`), oldest retained payload, newest retained payload, and final mailbox receipt instead of relying only on the broad overflow probe
  - bare-metal wake-queue clear recovery is now enforced by a live QEMU+GDB probe that clears the wrapped ring after `66` manual wakes, proves the queue resets to `count/head/tail/overflow = 0`, and then reuses the queue cleanly from `seq=1`
  - optimized freestanding bare-metal builds now retain the Multiboot2 header again because the final bare-metal artifact disables link-time section garbage collection for `.multiboot`, and the generic bare-metal smoke scripts now validate that contract through the same optimized path used for release packaging
  - bare-metal wake-queue post-overflow recovery is now enforced by a live QEMU+GDB probe that batch-drains the wrapped ring, proves survivor ordering (`seq 65 -> 66`), drains to empty, and then reuses the queue without a clear/reset (`seq 67`)
  - bare-metal descriptor-table contents are now enforced by a live QEMU+GDB probe (`gdtr`, `idtr`, `gdt`, `idt`, `oc_interrupt_stub`) across descriptor reinit/load, including segment entry fields and interrupt-stub wiring
  - bare-metal descriptor reinit/load plus post-load dispatch coherence is now enforced by a live QEMU+GDB probe (`command_trigger_interrupt`, `command_trigger_exception`, interrupt/exception history rings) in the same run as descriptor reinit/load
  - bare-metal vector-counter and history-overflow behavior is now enforced by a live QEMU+GDB probe covering interrupt saturation (`35 -> len 32 / overflow 3`) and exception saturation (`19 -> len 16 / overflow 3`) with per-vector counter validation
  - bare-metal command-history and health-history ring behavior is now enforced by a live QEMU+GDB probe covering repeated `command_set_health_code` mailbox execution, command ring saturation (`35 -> len 32 / overflow 3`), and health ring saturation (`71 -> len 64 / overflow 7`) with retained-oldest/newest payload validation
  - bare-metal reset-counters behavior is now enforced by a live QEMU+GDB probe that dirties interrupt, exception, scheduler, allocator, syscall, timer, wake-queue, mode, boot-phase, command-history, and health-history state before proving `command_reset_counters` collapses the runtime back to its steady baseline
  - bare-metal scheduler default-budget and priority-reordering behavior is now enforced by a live QEMU+GDB probe proving `command_scheduler_set_default_budget` seeds zero-budget task creation and `command_task_set_priority` can flip live dispatch order under the priority scheduler
  - bare-metal mailbox header-validation and sequence-control invariants are now enforced by live QEMU+GDB probes proving invalid `magic` and `api_version` are rejected without execution, stale `command_seq` replays stay no-op, and `u64` mailbox sequence wraparound still preserves deterministic `ack` and command-history ordering
  - bare-metal scheduler default-budget rejection behavior is now enforced by a live QEMU+GDB probe proving `command_scheduler_set_default_budget(0)` returns `result_invalid_argument` without clobbering the active default budget or fresh zero-budget task inheritance
  - bare-metal feature-flags and tick-batch control is now enforced by both a host test and a live QEMU+GDB probe, proving `command_set_feature_flags` persists a new flag mask, `command_set_tick_batch_hint` changes runtime tick progression from `1` to `4`, and an invalid zero hint is rejected without clobbering the active batch size
  - feature-flags/tick-batch wrapper probes now enforce the narrow boundaries directly: stage-1 feature-flag success, stage-2 valid tick-batch update, stage-3 invalid-zero preservation, final mailbox opcode/sequence stability, and final preserved flag/batch/tick accumulation over the same live PVH run
  - mailbox wrapper probes now enforce the narrow mailbox-control boundaries directly: invalid `magic` preservation, invalid `api_version` preservation, a dedicated five-stage stale-seq family (`baseline`, `first state`, `stale preserve`, `fresh recovery state`, `final mailbox state`), and a dedicated five-stage `u32` sequence-wraparound family (`baseline`, `pre-wrap state`, `pre-wrap mailbox seq`, `post-wrap state`, `post-wrap mailbox state`) over the same live PVH run
  - interrupt-timeout disable-interrupt wrapper probes now enforce the narrow boundaries directly: immediate interrupt wake while timers stay disabled, cleared timeout arm and wait-vector state, preserved disabled timer state after the wake, no stale timer wake after `command_timer_enable`, and preserved interrupt/last-wake telemetry across the full recovery path
  - `zig build test` now includes the host-run `src/baremetal_main.zig` suite, and that newly surfaced bare-metal wake-queue assertion drift has been corrected instead of remaining hidden outside the default test gate
  - bare-metal wake-queue FIFO consumption is now enforced by a live QEMU+GDB probe, proving `command_wake_queue_pop` removes the logical oldest event first, preserves the second queued manual wake as the new head (`seq=2`, `tick=7`), and returns `result_not_found` once the queue is empty
  - bare-metal direct timer-ID cancellation is now enforced by a live QEMU+GDB probe, proving `command_timer_cancel` captures the armed timer ID from the live entry, cancels that exact timer in place, preserves the canceled slot metadata, and returns `result_not_found` on a second cancel
  - bare-metal vector-counter reset is now enforced by a live QEMU+GDB probe, proving `command_reset_vector_counters` zeroes the interrupt/exception per-vector tables while preserving aggregate interrupt counts, exception counts, and last-vector telemetry
- Dual runtime profiles available:
  - OS-hosted profile: `openclaw-zig` (`--serve`, doctor, security audit, full RPC stack)
- Bare-metal profile: `openclaw-zig-baremetal.elf` (`zig build baremetal`, freestanding runtime loop + Multiboot2 header)
  - smoke gate validates ELF class/endianness, Multiboot2 location/alignment, `.multiboot` section, and required exported symbols
  - smoke gate also validates Multiboot2 header field contract and checksum
  - optional QEMU validation path available via `zig build baremetal -Dbaremetal-qemu-smoke=true`, `scripts/baremetal-qemu-smoke-check.ps1`, `scripts/baremetal-qemu-runtime-oc-tick-check.ps1`, `scripts/baremetal-qemu-command-loop-check.ps1`, `scripts/baremetal-qemu-mailbox-header-validation-probe-check.ps1`, `scripts/baremetal-qemu-mailbox-invalid-magic-preserve-state-probe-check.ps1`, `scripts/baremetal-qemu-mailbox-invalid-api-version-preserve-state-probe-check.ps1`, `scripts/baremetal-qemu-mailbox-header-ack-sequence-probe-check.ps1`, `scripts/baremetal-qemu-mailbox-header-tick-batch-recovery-probe-check.ps1`, `scripts/baremetal-qemu-mailbox-valid-recovery-probe-check.ps1`, `scripts/baremetal-qemu-mailbox-stale-seq-probe-check.ps1`, `scripts/baremetal-qemu-mailbox-stale-seq-preserve-state-probe-check.ps1`, `scripts/baremetal-qemu-mailbox-seq-wraparound-probe-check.ps1`, `scripts/baremetal-qemu-mailbox-seq-wraparound-recovery-probe-check.ps1`, `scripts/baremetal-qemu-feature-flags-tick-batch-probe-check.ps1`, `scripts/baremetal-qemu-descriptor-bootdiag-probe-check.ps1`, `scripts/baremetal-qemu-bootdiag-history-clear-probe-check.ps1`, `scripts/baremetal-qemu-reset-bootdiag-preserve-state-probe-check.ps1`, `scripts/baremetal-qemu-clear-command-history-preserve-health-probe-check.ps1`, `scripts/baremetal-qemu-clear-health-history-preserve-command-probe-check.ps1`, `scripts/baremetal-qemu-descriptor-table-content-probe-check.ps1`, `scripts/baremetal-qemu-descriptor-dispatch-probe-check.ps1`, `scripts/baremetal-qemu-vector-counter-reset-probe-check.ps1`, `scripts/baremetal-qemu-vector-history-overflow-probe-check.ps1`, `scripts/baremetal-qemu-vector-history-clear-probe-check.ps1`, `scripts/baremetal-qemu-reset-interrupt-counters-preserve-history-probe-check.ps1`, `scripts/baremetal-qemu-reset-exception-counters-preserve-history-probe-check.ps1`, `scripts/baremetal-qemu-clear-interrupt-history-preserve-exception-probe-check.ps1`, `scripts/baremetal-qemu-reset-vector-counters-preserve-aggregate-probe-check.ps1`, `scripts/baremetal-qemu-reset-vector-counters-preserve-last-vector-probe-check.ps1`, `scripts/baremetal-qemu-command-health-history-probe-check.ps1`, `scripts/baremetal-qemu-scheduler-probe-check.ps1`, `scripts/baremetal-qemu-scheduler-priority-budget-probe-check.ps1`, `scripts/baremetal-qemu-scheduler-default-budget-invalid-probe-check.ps1`, `scripts/baremetal-qemu-timer-wake-probe-check.ps1`, `scripts/baremetal-qemu-timer-quantum-probe-check.ps1`, `scripts/baremetal-qemu-timer-cancel-probe-check.ps1`, `scripts/baremetal-qemu-timer-cancel-task-interrupt-timeout-probe-check.ps1`, `scripts/baremetal-qemu-task-resume-timer-clear-probe-check.ps1`, `scripts/baremetal-qemu-task-resume-interrupt-probe-check.ps1`, `scripts/baremetal-qemu-scheduler-wake-timer-clear-probe-check.ps1`, `scripts/baremetal-qemu-periodic-timer-probe-check.ps1`, `scripts/baremetal-qemu-periodic-interrupt-probe-check.ps1`, `scripts/baremetal-qemu-interrupt-timeout-probe-check.ps1`, `scripts/baremetal-qemu-interrupt-manual-wake-probe-check.ps1`, `scripts/baremetal-qemu-interrupt-timeout-timer-probe-check.ps1`, `scripts/baremetal-qemu-task-terminate-interrupt-timeout-probe-check.ps1`, `scripts/baremetal-qemu-interrupt-filter-probe-check.ps1`, `scripts/baremetal-qemu-panic-recovery-probe-check.ps1`, `scripts/baremetal-qemu-panic-wake-recovery-probe-check.ps1`, `scripts/baremetal-qemu-wake-queue-selective-probe-check.ps1`, `scripts/baremetal-qemu-wake-queue-reason-overflow-probe-check.ps1`, `scripts/baremetal-qemu-wake-queue-fifo-probe-check.ps1`, `scripts/baremetal-qemu-wake-queue-summary-age-probe-check.ps1`, `scripts/baremetal-qemu-wake-queue-clear-probe-check.ps1`, `scripts/baremetal-qemu-allocator-syscall-probe-check.ps1`, `scripts/baremetal-qemu-allocator-syscall-baseline-probe-check.ps1`, `scripts/baremetal-qemu-allocator-syscall-alloc-stage-probe-check.ps1`, `scripts/baremetal-qemu-allocator-syscall-invoke-stage-probe-check.ps1`, `scripts/baremetal-qemu-allocator-syscall-guard-stage-probe-check.ps1`, `scripts/baremetal-qemu-allocator-syscall-final-reset-state-probe-check.ps1`, `scripts/baremetal-qemu-syscall-saturation-probe-check.ps1`, `scripts/baremetal-qemu-syscall-control-probe-check.ps1`, `scripts/baremetal-qemu-allocator-syscall-failure-probe-check.ps1`, `scripts/baremetal-qemu-command-result-counters-probe-check.ps1`, `scripts/baremetal-qemu-reset-command-result-preserve-runtime-probe-check.ps1`, `scripts/baremetal-qemu-reset-counters-probe-check.ps1`, `scripts/baremetal-qemu-reset-counters-preserve-config-probe-check.ps1`, `scripts/baremetal-qemu-manual-wait-interrupt-probe-check.ps1`, `scripts/baremetal-qemu-interrupt-mask-exception-probe-check.ps1`, `scripts/baremetal-qemu-interrupt-mask-profile-probe-check.ps1`, and `scripts/baremetal-qemu-interrupt-mask-clear-all-recovery-probe-check.ps1` (auto-skips when QEMU/GDB or PVH toolchain pieces are unavailable)
  - optional QEMU descriptor bootdiag probe validates `reset_boot_diagnostics`, stack capture, boot-phase transition, invalid boot-phase rejection, descriptor-table reinit, and descriptor-load telemetry against the freestanding PVH artifact
  - optional QEMU descriptor bootdiag wrapper probes now fail directly on the same lane's bootstrap baseline, reset+stack-capture envelope, `set_boot_phase(init)` transition, invalid-phase preservation, and final descriptor-load plus mailbox-state boundaries
  - optional QEMU bootdiag/history-clear probe validates `command_reset_boot_diagnostics`, `command_clear_command_history`, and `command_clear_health_history` semantics end to end, including pre-reset stack/phase state capture and post-clear ring contents against the freestanding PVH artifact
  - optional QEMU bootdiag/history-clear wrapper probes now fail directly on that lane's baseline/source marker, pre-reset boot-diagnostics payloads, post-reset collapse, command-history clear-event shape, and health-history preservation boundaries
  - optional QEMU feature-flags/tick-batch probe validates `command_set_feature_flags` plus `command_set_tick_batch_hint` end to end, proving feature flags update, runtime tick progression changes from `1` to `4`, and an invalid zero hint returns `LAST_RESULT=-22` without changing the active batch size
  - optional QEMU descriptor table content probe validates `gdtr/idtr` limits+bases, code/data `gdt` entries, and `idt[0]/idt[255]` selector/type/stub wiring after live descriptor reinit/load against the freestanding PVH artifact
  - optional QEMU descriptor table content wrapper probes now fail directly on the same lane's baseline mailbox envelope, descriptor pointer metadata, exact GDT entry fields, exact IDT entry fields, and final interrupt-stub plus mailbox-state invariants
  - optional QEMU descriptor dispatch probe validates descriptor reinit/load plus post-load `interrupt` and `exception` dispatch coherence, including interrupt/exception counters and history-ring payloads, against the freestanding PVH artifact
  - optional QEMU descriptor-dispatch wrapper probes now enforce the same lane in five isolated checks: bootstrap baseline, descriptor reinit/load telemetry deltas, final aggregate interrupt/exception state, exact interrupt-history payloads, and final exception-history plus mailbox receipt
  - optional QEMU vector counter reset probe validates `command_reset_vector_counters` after live dispatch, proving interrupt vectors `10/200/14` and exception vectors `10/14` collapse back to `0` while aggregate interrupt/exceptions counts stay at `4/3` and last-vector telemetry stays on vector `14`
  - optional QEMU vector history overflow probe validates interrupt/exception counter resets plus repeated dispatch saturation, proving interrupt history overflow (`35 -> len 32 / overflow 3`), exception history overflow (`19 -> len 16 / overflow 3`), and per-vector telemetry against the freestanding PVH artifact
  - optional QEMU vector history overflow wrapper probes now fail directly on the broad lane's baseline mailbox receipt, phase-A interrupt overflow boundary, phase-B exception overflow boundary, phase-B vector telemetry, and final mailbox-state invariants
  - optional QEMU vector history clear probe validates the dedicated mailbox clear paths end to end, proving `command_reset_interrupt_counters` and `command_reset_exception_counters` zero aggregate interrupt/exception counters without disturbing the retained history/vector tables, then `command_clear_interrupt_history` and `command_clear_exception_history` zero only their history rings/overflow counters against the freestanding PVH artifact
  - optional QEMU vector history clear wrapper probes now isolate that same lane in five checks: final mailbox baseline, retained pre-clear interrupt payloads, retained pre-clear exception payload, interrupt-reset preservation plus interrupt-clear boundary, and exception-reset preservation plus final clear-state boundary
  - optional QEMU command-health history probe validates repeated `command_set_health_code` mailbox execution against the freestanding PVH artifact, proving command history overflow (`35 -> len 32 / overflow 3`), health history overflow (`71 -> len 64 / overflow 7`), and retained oldest/newest command + health payload ordering
  - optional QEMU command-health history wrapper probes now isolate that same lane in five checks: final mailbox baseline, command-ring shape, command oldest/newest payloads, health-ring shape, and health oldest/newest payloads
  - optional QEMU health-history overflow clear wrapper probes now isolate the companion clear lane in five checks: broad baseline, overflow window shape (`seq 8 -> 71`), retained oldest/newest health payloads plus trailing ack telemetry, single-receipt clear collapse (`seq=1`, `code=200`, `mode=running`, `tick=6`, `ack=6`), and preserved command-history tail state
  - optional QEMU command-history overflow-clear probe validates the combined overflow, clear, and restart lane end to end, proving the wrapped command ring retains `seq 4 -> 35`, `command_clear_command_history` collapses it to the single clear receipt, and the next mailbox command restarts the ring at the expected post-clear boundary without disturbing health-history overflow state
  - optional QEMU command-history overflow-clear wrapper probes now isolate that same lane in five checks: broad-lane baseline, overflow-window shape, oldest/newest overflow payloads, clear-event collapse plus preserved health-history length, and post-clear restart-event payloads
  - optional QEMU health-history overflow-clear probe validates the combined overflow, clear, and restart lane end to end, proving the wrapped health ring retains `seq 8 -> 71`, `command_clear_health_history` collapses it to the single clear receipt at `seq 1`, and the next mailbox health event restarts the ring cleanly without disturbing command-history overflow state
  - optional QEMU task lifecycle probe validates `task_wait -> scheduler_wake_task -> task_resume -> task_terminate` against the freestanding PVH artifact, including post-terminate rejection (`ACK=10`, `LAST_OPCODE=45`, `LAST_RESULT=-2`, manual wake queue `1 -> 2 -> 0`, terminated state `4`)
  - optional QEMU task-lifecycle wrapper probes validate the same lane in five isolated checks: initial wait baseline, first manual wake delivery, second wait baseline, second manual wake delivery after `command_task_resume`, and final terminate plus rejected-wake telemetry with the terminated task's queue entries fully purged
  - optional QEMU active-task terminate probe validates terminating the currently running high-priority task against the freestanding PVH artifact, proving immediate failover to the remaining ready task (`POST_TERMINATE_TASK_COUNT=1`, `POST_TERMINATE_RUNNING_SLOT=0`, `LOW_RUN=0 -> 1`), idempotent repeat terminate semantics (`REPEAT_TERMINATE_RESULT=0`), and final empty-run collapse (`ACK=10`, `LAST_OPCODE=28`, `LAST_RESULT=0`, `TASK_COUNT=0`, `RUNNING_SLOT=255`)
  - optional QEMU active-task terminate wrapper probes validate the same lane in five isolated checks: pre-terminate active baseline, immediate failover after the first terminate, repeat-idempotent receipt, survivor low-task progress after the repeat terminate, and final empty-run collapse telemetry
  - optional QEMU task-terminate mixed-state wrapper probes now validate the queued-wake plus canceled-timer cleanup lane in five isolated checks: wrapped mixed-state baseline before termination, immediate target-clear collapse, preserved survivor wake handoff, explicit cleared wait-kind/timeout state for both task slots, and settled no-stale-dispatch plus preserved quantum/next-timer telemetry after idle ticks
  - optional QEMU panic-recovery probe validates `command_trigger_panic_flag` under active scheduler load, proving panic mode freezes dispatch/budget burn, `command_set_mode(mode_running)` resumes the same task immediately, and `command_set_boot_phase(runtime)` restores boot diagnostics while dispatch continues (`ACK=7`, `LAST_OPCODE=16`, `LAST_RESULT=0`, `PANIC_COUNT=1`, `TASK0_RUN_COUNT=3`, `TASK0_BUDGET_REMAINING=3`)
  - optional QEMU panic-recovery wrapper probes validate the same lane in five isolated checks: pre-panic baseline state, panic freeze-state, idle panic preservation, mode-recovery resume semantics, and final recovered task-state telemetry
  - optional QEMU panic-wake recovery probe validates preserved interrupt + timer wake delivery across panic mode, proving panic holds scheduler dispatch at `0` while interrupt/timer waiters become ready, then `command_set_mode(mode_running)` and `command_set_boot_phase(runtime)` resume the preserved ready queue in order (`ACK=13`, `LAST_OPCODE=16`, `TASK_COUNT=2`, `RUNNING_SLOT=1`, `TASK1_BUDGET_REMAINING=6`)
  - optional QEMU panic-wake recovery wrapper probes validate the same lane in five isolated checks: pre-panic waiting baseline, panic freeze-state, preserved interrupt+timer wake queue delivery, mode-recovery dispatch resume, and final recovered task-state telemetry
  - optional QEMU mode/boot-phase history probe validates live command/runtime/panic reason ordering, then clears and saturates both 64-entry rings against the freestanding PVH artifact, proving retained oldest/newest mode + boot-phase payload ordering (`66 -> len 64 / overflow 2`)
  - optional QEMU mode/boot-phase history wrapper probes split that lane into five isolated checks: final mailbox baseline, semantic mode ordering, semantic boot-phase ordering, retained mode-history overflow-window payloads, and retained boot-phase overflow-window payloads
  - optional QEMU mode/boot-phase setter probe validates direct `command_set_boot_phase` and `command_set_mode` mailbox control end to end, proving same-value setters stay idempotent, invalid boot-phase `99` and invalid mode `77` are rejected without clobbering retained state/history, and direct `mode_panicked` / `mode_running` transitions do not mutate panic counters or boot-phase state against the freestanding PVH artifact
  - optional QEMU mode/boot-phase setter wrapper probes split that lane into five isolated checks: final mailbox baseline, boot no-op plus invalid boot-phase preservation, invalid mode preservation, exact mode-history payload ordering, and exact boot-phase-history payload ordering
  - optional QEMU allocator/syscall failure wrapper probes split that lane into five isolated checks: final mailbox baseline, invalid-alignment allocator-state preservation, no-space allocator-state preservation, blocked-syscall state preservation, and final disabled-syscall/result-counter invariants
  - optional QEMU mode/boot-phase history clear probe validates the dedicated mailbox clear paths end to end, proving `command_clear_mode_history` and `command_clear_boot_phase_history` zero ring len/head/overflow/seq independently, preserve the non-cleared companion ring until its own clear, and restart both histories at `seq=1` on the next live transitions
  - optional QEMU mode/boot-phase history clear wrapper probes split that lane into five isolated checks: clear-lane baseline, retained pre-clear panic semantics, mode-ring collapse with preserved boot-history state, boot-ring collapse, and dual-ring restart semantics after both clear commands
  - optional QEMU mode-history overflow-clear probe validates the combined overflow, clear, and restart lane end to end, proving the wrapped 64-entry mode-history ring retains `seq 3 -> 66`, `command_clear_mode_history` drops only the mode ring to zero, and the next live mode transitions restart the ring at `seq 1` without disturbing boot-phase history
  - optional QEMU mode-history overflow-clear wrapper probes split that lane into five isolated checks: final mailbox baseline, wrapped overflow-window shape, wrapped oldest/newest mode payloads, dedicated clear collapse with preserved boot-history length, and post-clear restart-event payload ordering
  - optional QEMU boot-phase-history overflow-clear probe validates the combined overflow, clear, and restart lane end to end, proving the wrapped 64-entry boot-phase-history ring retains `seq 3 -> 66`, `command_clear_boot_phase_history` drops only the boot-phase ring to zero, and the next live boot-phase transitions restart the ring at `seq 1` without disturbing mode-history state
  - optional QEMU boot-phase-history overflow-clear wrapper probes split that lane into five isolated checks: final mailbox baseline, wrapped overflow-window shape, wrapped oldest/newest boot-phase payloads, dedicated clear collapse with preserved mode-history length, and post-clear restart-event payload ordering
  - optional QEMU allocator/syscall failure probe validates invalid-alignment, no-space, blocked-syscall, and disabled-syscall result semantics plus command-result counters against the freestanding PVH artifact
  - optional QEMU syscall saturation probe validates the 64-entry syscall-table boundary: full table registration, `no_space` on the 65th entry, slot reclaim via `unregister`, clean slot reuse with a fresh syscall ID/token, and successful post-reuse invoke against the freestanding PVH artifact
  - optional QEMU syscall saturation reset probe validates the fully saturated reset lane: fill all 64 syscall slots, dirty dispatch state with a real invoke, run `command_syscall_reset`, prove the table and dispatch telemetry collapse to steady state, then prove a fresh syscall restarts cleanly from slot `0`
  - optional QEMU syscall control probe validates isolated syscall mutation semantics: re-register without entry-count growth, blocked invoke `-17`, disabled invoke `-38`, re-enabled successful invoke, unregister, and missing-entry mutation paths against the freestanding PVH artifact
  - optional QEMU scheduler probe validates scheduler reset/timeslice/task-create/policy-enable flow end to end against the freestanding PVH artifact
  - optional QEMU scheduler wrapper probes validate the same lane in five isolated checks: bootstrap reachability, final scheduler config state, exact task shape, dispatch/budget progress telemetry, and final mailbox receipt invariants
  - optional QEMU scheduler priority/budget probe validates `command_scheduler_set_default_budget`, live priority-policy dispatch, reprioritization, and invalid-input preservation end to end, proving a zero-budget low-priority task inherits the configured default budget (`9`), the high-priority task dispatches first, a later low-task reprioritization flips the next dispatch, and invalid policy/task mutations preserve the active priority scheduler state (`ACK=11`, `LAST_OPCODE=56`, `LAST_RESULT=-2`)
  - optional QEMU scheduler priority/budget wrapper probes validate the same lane in five isolated checks: baseline bootstrap, zero-budget default-budget inheritance, initial high-priority dominance, low-task takeover after reprioritize, and invalid-input preservation against the freestanding PVH artifact
  - optional QEMU scheduler round-robin probe validates the default scheduler policy ignores priority bias and rotates dispatch fairly across two live tasks (`ACK=6`, `POLICY=0`, run counts `1/0 -> 1/1 -> 2/1`, budgets `3 -> 3 -> 2`) against the freestanding PVH artifact
  - optional QEMU scheduler round-robin wrapper probes validate the same lane in five isolated checks: baseline task/policy bootstrap, first-dispatch first-task-only delivery, second-dispatch rotation onto the second task, third-dispatch return to the first task, and final scheduler/task-state telemetry
  - optional QEMU scheduler timeslice-update probe validates live `command_scheduler_set_timeslice` changes under active load, proving budget consumption immediately follows the new timeslice (`1 -> 4 -> 2`) and invalid zero is rejected without changing the active value (`ACK=6`, `LAST_OPCODE=29`, `LAST_RESULT=-22`, task budget remaining `9 -> 5 -> 3 -> 1`)
  - optional QEMU scheduler timeslice wrapper probes validate the same lane in five isolated checks: baseline `timeslice=1`, first update `timeslice=4`, second update `timeslice=2`, invalid-zero preservation, and final dispatch/task-state telemetry on the live task
  - optional QEMU scheduler disable-enable probe validates live `command_scheduler_disable` and `command_scheduler_enable` under active load, proving dispatch and budget burn freeze while disabled and resume immediately on re-enable (`ACK=5`, `LAST_OPCODE=24`, `DISPATCH_COUNT 1 -> 1 -> 2`, task budget remaining `4 -> 4 -> 3`)
  - optional QEMU scheduler disable-enable wrapper probes validate the same lane in five isolated checks: baseline pre-disable state, disabled freeze-state, idle disabled preservation, re-enable resume metadata, and final task-state telemetry on the resumed task
  - optional QEMU scheduler reset probe validates live `command_scheduler_reset` under active load, proving scheduler state returns to defaults, task state is wiped, task IDs restart at `1`, and fresh dispatch resumes cleanly after re-enable (`ACK=6`, `POST_RESET_NEXT_TASK_ID=1`, `POST_CREATE_TASK0_ID=1`, final `TASK0_BUDGET_REMAINING=5`)
  - optional QEMU scheduler reset wrapper probes validate the same lane in five isolated checks: dirty pre-reset baseline, immediate reset collapse, task-ID restart, restored scheduler defaults, and final resumed task-state telemetry after re-enable
  - optional QEMU scheduler reset mixed-state probe validates live `command_scheduler_reset` against stale mixed load, proving queued wakes and armed task timers are scrubbed alongside the task table, timeout arms are cleared, timer quantum is preserved, and fresh timer scheduling resumes from the preserved `next_timer_id` (`ACK=10`, `PRE_WAKE_COUNT=1`, `PRE_TIMER_COUNT=1`, `POST_WAKE_COUNT=0`, `POST_TIMER_COUNT=0`, `REARM_TIMER_ID=2`)
  - optional QEMU scheduler reset mixed-state wrapper probes validate the same lane in five isolated checks: dirty mixed baseline, immediate post-reset collapse, preserved timer configuration, idle stability after reset, and fresh timer re-arm state
  - optional QEMU scheduler policy-switch probe validates live round-robin to priority to round-robin transitions under active load, proving the dispatch strategy flips immediately, low-task reprioritization takes effect on the next priority tick, and an invalid policy request is rejected without changing the active round-robin policy (`ACK=10`, `LAST_OPCODE=55`, `LAST_RESULT=-22`, final run counts `3/3`, final budgets `3/3`)
  - optional QEMU scheduler saturation probe validates the 16-slot task-table pressure path end to end, proving the 17th `command_task_create` returns `result_no_space`, task count holds at `16`, then a terminated slot is reused cleanly with a fresh task ID (`6 -> 17`) and the requested replacement priority/budget (`99`, `7`)
  - optional QEMU scheduler saturation wrapper validation now fails directly on the 16-slot baseline fill, overflow rejection without task-count drift, terminated-slot capture, reuse-slot replacement semantics, and final scheduler state on that pressure lane
  - optional QEMU timer wake probe validates timer reset/quantum/task-wait flow end to end, including fired timer entries and wake-queue telemetry against the freestanding PVH artifact
  - timer-wake wrapper probes now enforce the same lane in five isolated checks: bootstrap baseline, final task-state telemetry, fired timer telemetry, exact timer wake payload, and final mailbox receipt after the one-shot wake path settles
  - optional QEMU timer quantum probe validates one-shot timer quantum suppression end to end, proving the task stays waiting with an empty wake queue at the pre-boundary tick and only wakes on the next quantum boundary against the freestanding PVH artifact
  - optional QEMU timer quantum wrapper probes validate the same lane in five isolated checks: armed baseline capture, computed quantum-boundary hold, pre-boundary blocked state, exact timer wake payload, and final timer/task-state telemetry after the delayed one-shot fire
  - optional QEMU timer cancel probe validates `command_timer_cancel` by live timer ID end to end, proving the armed timer entry is canceled in place, `timer_entry_count` drops to `0`, and a second cancel of the same timer ID returns `result_not_found`
  - optional QEMU timer cancel wrapper probes validate that same broad lane at five narrower boundaries, failing directly on the armed baseline, cancel collapse to zero live timer entries, preserved canceled-slot metadata, second-cancel `result_not_found`, and zero wake/dispatch telemetry
  - optional QEMU timer cancel-task probe validates `command_timer_cancel_task` end to end, proving the first cancellation collapses `timer_entry_count` to `0`, preserves the canceled timer slot state, and the second cancellation returns `result_not_found` against the freestanding PVH artifact
  - optional QEMU timer pressure probe validates the full runnable timer window end to end, proving 16 live task timers arm cleanly with IDs `1 -> 16`, one canceled slot is reused in place with fresh timer ID `17`, and the timer subsystem stays free of stray wakes or dispatches while the scheduler remains disabled
  - timer-pressure wrapper probes now enforce that same lane directly at five narrower boundaries: full saturation baseline (`16/16`, IDs `1 -> 16`), cancel collapse to `15` live timer entries, in-place slot reuse with fresh timer ID `17`, preserved waiting-state plus next-fire semantics on the reused task, and zero wake/dispatch telemetry through the full disabled-scheduler sequence
  - optional QEMU timer reset recovery probe validates `command_timer_reset` recovery end to end, proving live timer entries, timeout-backed interrupt waits, and disabled/quantized timer state collapse back to steady baseline, stale timeout wakes do not leak after reset, manual and interrupt wake recovery still work, and the next timer re-arms cleanly from `timer_id=1`
  - timer-reset-recovery wrapper probes now enforce that same lane directly at five narrower boundaries: dirty pre-reset armed baseline, immediate post-reset timer collapse, preserved pure-timer/manual plus interrupt-any wait isolation after reset, exact manual wake payload after explicit recovery, and final interrupt wake plus rearm telemetry on the next timer arm
  - optional QEMU task-resume timer-clear probe validates `command_task_resume` on a timer-backed wait end to end, proving the armed timer entry is canceled in place, exactly one manual wake is queued, no later ghost timer wake appears after idle ticks, timer quantum is preserved, and fresh timer scheduling resumes from the preserved `next_timer_id`
  - task-resume timer-clear wrapper probes now enforce that same lane directly at five narrower boundaries: pre-resume timer-backed waiting baseline, cleared wait-kind/timeout state after `command_task_resume`, preserved canceled-slot metadata, exact manual wake payload, and final no-stale-timer plus rearm/telemetry invariants
  - optional QEMU task-resume interrupt-timeout probe validates `command_task_resume` on an interrupt-timeout waiter end to end, proving the pending timeout is cleared to `none`, exactly one manual wake is queued, no delayed timer wake appears after additional slack ticks, and the timer subsystem remains at `next_timer_id=1`
  - optional QEMU task-resume interrupt probe validates `command_task_resume` on a pure `task_wait_interrupt` waiter end to end, proving the interrupt wait is cleared to `none`, exactly one manual wake is queued, a later interrupt still increments telemetry without creating a second wake, and the timer subsystem remains idle with `next_timer_id=1`
  - optional QEMU periodic timer probe validates periodic timer scheduling plus disable/enable pause-resume behavior end to end, capturing the first resumed periodic fire and queued wake telemetry against the freestanding PVH artifact
  - periodic-timer wrapper probes now enforce that same lane directly at five narrower boundaries: scheduler/task/timer baseline capture, first periodic fire payload and counters, disabled-window counter hold, resumed periodic cadence with the next-fire deadline advanced by `period_ticks`, and final command/wake/task telemetry preservation
  - optional QEMU periodic interrupt probe validates mixed periodic timer plus interrupt wake ordering end to end, proving the interrupt wake lands before the deadline, the periodic source keeps its cadence, and cancellation prevents a later timeout leak against the freestanding PVH artifact
  - optional QEMU interrupt-timeout probe validates `task_wait_interrupt_for` wakeup precedence end to end, proving an interrupt wake clears the timeout arm and does not later leak a second timer wake against the freestanding PVH artifact
  - interrupt-timeout interrupt-wins wrapper probes now enforce the narrow interrupt-first boundaries directly: preserved armed timeout state before the interrupt lands, exact interrupt wake payload semantics, cleared wait-kind/vector/timeout state after the interrupt wake, no stale timer wake after additional slack ticks, and preserved interrupt plus last-wake telemetry through the full interrupt-first recovery path
  - optional QEMU interrupt-timeout manual-wake probe validates the manual-recovery path end to end, proving `command_scheduler_wake_task` clears the pending timeout, queues exactly one manual wake, and does not allow a delayed timer wake to appear against the freestanding PVH artifact
  - interrupt-timeout manual-wake wrapper probes now enforce the narrow boundaries directly: preserved armed timeout state before the manual wake, single manual wake-queue delivery, cleared wait-kind/vector/timeout state after `command_scheduler_wake_task`, no stale timer wake after additional idle ticks, and preserved zero-interrupt plus last-wake telemetry through the full recovery path
  - optional QEMU timer-cancel-task interrupt-timeout probe validates `command_timer_cancel_task` on a timeout-backed interrupt waiter end to end, proving the timeout arm is cleared without losing the later real interrupt wake path, leaving `wait_timeout=0`, `timer_entry_count=0`, and a single subsequent `interrupt` wake against the freestanding PVH artifact
  - optional QEMU timer-cancel-task wrapper probes validate the pure task-cancel lane in five isolated checks: armed task baseline capture, first-cancel collapse to zero live timer entries, preserved canceled-slot metadata on `timer0`, second-cancel `result_not_found`, and zero wake/dispatch telemetry through the full task-targeted cancel flow
  - optional QEMU interrupt manual-wake probe validates `command_scheduler_wake_task` on a pure `task_wait_interrupt` waiter end to end, proving the interrupt wait clears to `none`, exactly one manual wake is queued, and a later interrupt only advances telemetry without adding a second wake against the freestanding PVH artifact
  - interrupt manual-wake wrapper probes now enforce the narrow pure-interrupt recovery boundaries directly: ready-task baseline, cleared wait-kind/vector/timeout state after `command_scheduler_wake_task`, exact manual wake payload semantics, preserved single-wake state after the later real interrupt, and final mailbox plus timer/interrupt telemetry invariants
  - optional QEMU scheduler-wake timer-clear probe validates `command_scheduler_wake_task` on a pure timer waiter end to end, proving the armed timer entry is canceled in place, exactly one manual wake is queued, no later ghost timer wake appears after idle ticks, and fresh timer scheduling resumes from the preserved `next_timer_id`
  - scheduler-wake timer-clear wrapper probes now enforce that lane directly too: preserved armed baseline, cleared wait/timer state, preserved canceled timer-entry state, exact manual wake payload, and final rearm/dispatch telemetry
  - optional QEMU interrupt-timeout timer probe validates the no-interrupt timeout path end to end, proving the waiter stays blocked until the deadline, then wakes with `reason=timer`, `vector=0`, and zero interrupt telemetry against the freestanding PVH artifact
  - interrupt-timeout timer wrapper probes now enforce the narrow timer-only boundaries directly: preserved armed timeout identity before the timer path wins, deadline-edge blocked state with zero wake queue, timer wake payload semantics after the deadline, no duplicate timer wake after additional slack ticks, and preserved zero-interrupt telemetry through the full timeout-only recovery path
  - optional QEMU masked-interrupt timeout probe validates the masked-interrupt timeout path end to end, proving `command_interrupt_mask_apply_profile(external_all)` suppresses vector `200`, preserves the waiting task with no wake-queue entry, and then falls through to a timer wake with `reason=timer`, `vector=0` against the freestanding PVH artifact
  - optional QEMU interrupt-timeout clamp probe validates the near-`u64::max` timeout path end to end, proving the armed deadline saturates at `18446744073709551615`, the wake event records that saturated tick, and the runtime wake boundary wraps cleanly to `0` without losing the queued timer wake
  - optional QEMU timer-disable reenable probe validates a pure one-shot timer waiter across `command_timer_disable` and `command_timer_enable`, proving the waiter survives idle time past the original deadline, the overdue wake lands exactly once after re-enable, and the runtime records a single timer wake against the freestanding PVH artifact
  - optional QEMU interrupt-timeout disable-enable probe validates a timeout-backed interrupt waiter across `command_timer_disable` and `command_timer_enable`, proving the timeout arm survives the disabled window, no wake is emitted while timers stay disabled, and the overdue timer wake lands exactly once after re-enable with `reason=timer`, `vector=0`
  - optional QEMU interrupt-timeout disable-enable arm-preservation probe validates the narrow immediate-disable boundary directly, proving the timeout arm, interrupt wait-kind, waiting task state, zero wake queue, and zero interrupt telemetry are all preserved immediately after `command_timer_disable`
  - optional QEMU interrupt-timeout disable-enable deadline-hold probe validates the narrow past-deadline boundary directly, proving the waiter remains blocked with the original timeout deadline intact even after the runtime tick passes that deadline while timers stay disabled
  - optional QEMU interrupt-timeout disable-enable paused-window probe validates the narrow paused disabled-window boundary directly, proving zero queued wakes, zero timer-entry usage, zero interrupt telemetry, and zero timer dispatch drift throughout the disabled pause window
  - optional QEMU interrupt-timeout disable-enable deferred-timer-wake probe validates the narrow re-enable boundary directly, proving the deferred wake targets the original waiting task, clears wait state to `none`, and lands as a timer-only wake at the paused-window wake boundary
  - optional QEMU interrupt-timeout disable-enable telemetry-preserve probe validates the narrow timer-only telemetry boundary directly, proving the deferred wake preserves zero interrupt count, zero timer last-interrupt count, and zero last-interrupt vector across the full disable/enable path
  - interrupt-timeout disable-enable wrapper probes now enforce the narrow boundaries directly: preserved timeout arm immediately after disable, continued waiting after the original deadline while timers remain disabled, paused-window zero-wake stability, deferred timer-only wake only after `command_timer_enable`, and preserved zero-interrupt telemetry across the later timer wake
  - optional QEMU interrupt-timeout disable-interrupt probe validates a timeout-backed interrupt waiter across `command_timer_disable` with a real interrupt arriving while timers are disabled, proving the waiter wakes immediately on the interrupt path for vector `200`, the timeout arm is cleared, and re-enabling timers later does not leak a stale timer wake
  - optional QEMU interrupt-timeout disable-interrupt immediate-wake probe validates the narrow disabled-window wake boundary directly, proving the first queued wake is the real interrupt wake, the task is already ready, and interrupt telemetry increments immediately while timers remain disabled
  - optional QEMU interrupt-timeout disable-interrupt timeout-clear probe validates the narrow recovery boundary directly, proving the interrupt wake clears wait-kind, wait-vector, timeout-arm, and timer-entry state immediately instead of leaving stale timeout bookkeeping behind
  - optional QEMU interrupt-timeout disable-interrupt disabled-state probe validates the narrow disabled-timer boundary directly, proving timers stay disabled, timer dispatch stays at `0`, and the disabled-window runtime state remains internally consistent after the interrupt wake
  - optional QEMU interrupt-timeout disable-interrupt reenable-no-stale-timer probe validates the narrow post-`command_timer_enable` boundary directly, proving the retained wake stays the original interrupt wake and no stale timer wake is added after timers resume
  - optional QEMU interrupt-timeout disable-interrupt telemetry-preserve probe validates the narrow telemetry boundary directly, proving interrupt counters, last-interrupt vector, and last-wake tick remain coherent across the disabled-window wake and later re-enable settle period
  - optional QEMU timer-disable interrupt immediate-wake probe validates the narrow interrupt-first boundary directly, proving the disabled-window interrupt waiter wakes first with `reason=interrupt`, `vector=200`, `timer_id=0`, and no timer wake is misclassified as the first event
  - optional QEMU timer-disable interrupt arm-preservation probe validates the narrow armed-state boundary directly, proving the pure one-shot waiter remains armed immediately after the interrupt while timers stay disabled and the wake queue still contains only the interrupt event
  - optional QEMU timer-disable interrupt paused-window probe validates the narrow paused disabled-window boundary directly, proving the one-shot waiter, armed timer entry, wake queue length, and zero timer dispatch count all stay stable through extra idle ticks while timers remain disabled
  - optional QEMU timer-disable interrupt deferred-timer-wake probe validates the narrow re-enable boundary directly, proving the deferred one-shot timer wake appears only after `command_timer_enable` with `reason=timer`, `vector=0`, and the original `timer_id`
  - optional QEMU timer-disable interrupt telemetry-preserve probe validates the narrow interrupt-telemetry boundary directly, proving the later deferred timer wake preserves the earlier interrupt count and vector telemetry instead of zeroing or drifting it
  - timer-disable interrupt wrapper probes now enforce the narrow boundaries directly: immediate interrupt wake while timers stay disabled, preserved armed one-shot timer state immediately after the interrupt, stable paused disabled-window state with no ghost wake or dispatch drift, deferred one-shot timer wake only after `command_timer_enable`, and preserved interrupt telemetry on the later timer wake
  - timer-recovery wrapper probes now enforce the narrow boundaries directly: paused disabled-state stability for pure one-shot waits, one-shot overdue wake recovery after re-enable, timeout-backed interrupt recovery on timer re-enable, timeout-backed interrupt recovery on direct interrupt while timers are disabled, and timer-reset wait-kind isolation between pure timer waits and interrupt waiters
  - periodic-interrupt wrapper probes now enforce the narrow mixed-lane boundaries directly: first periodic wake ordering before the interrupt lands, exact interrupt wake payload semantics, preserved periodic cadence after the interrupt wake, clean cancel-with-no-late-timeout-leak behavior, and preserved mixed interrupt/timer telemetry after settlement
  - optional QEMU periodic timer clamp probe validates the periodic helper saturation path end to end, proving a timer armed at `u64::max-1` first fires at `18446744073709551615`, re-arms to the same saturated deadline, and then remains stable after the runtime tick counter wraps to `0`
  - optional QEMU interrupt-filter probe validates `command_task_wait_interrupt` vector filtering end to end, proving interrupt-any waiters wake on `200`, vector-scoped waiters ignore non-matching `200`, then wake on matching `13`, and invalid vector `65536` is rejected with `LAST_RESULT=-22` against the freestanding PVH artifact
  - optional QEMU task-terminate interrupt-timeout probe validates `command_task_terminate` on a timeout-backed interrupt waiter end to end, proving the terminated task keeps `state=4`, queued wake count stays `0`, timer entry count stays `0`, timeout state is cleared back to `none`, and a later interrupt only advances telemetry without producing a stale wake against the freestanding PVH artifact
  - task-terminate interrupt-timeout wrapper probes now enforce that lane directly too: preserved armed interrupt-timeout baseline before terminate, immediate target-clear collapse with `state=4`, preserved interrupt telemetry after the post-terminate interrupt injection, settled no-stale-timeout invariants after slack ticks, and final mailbox plus budget state on the terminated task
  - mixed task-recovery wrapper probes now enforce the narrow boundaries directly: `command_task_resume` on timeout-backed interrupt waits must clear wait state to `none` and queue exactly one manual wake, `command_scheduler_wake_task` on pure timer waits must cancel the armed timer while preserving clean re-arm, `command_timer_cancel_task` on timeout-backed interrupt waits must clear the timeout yet still allow the later real interrupt wake, and mixed terminate flow must preserve only the survivor wake after termination
  - task-resume interrupt-timeout wrapper probes now enforce that lane directly too: ready-task baseline after resume, cleared wait state, exactly one manual wake payload, no stale timeout wake after the slack window, and preserved final mailbox/interrupt telemetry
  - task-resume interrupt wrapper probes now enforce that pure-interrupt lane directly too: ready-task baseline after resume, cleared interrupt wait state, exact manual wake payload, preserved single-wake state after the later real interrupt, and final mailbox/interrupt telemetry
  - optional QEMU interrupt-filter probe validates `command_task_wait_interrupt` vector filtering end to end, proving interrupt-any waiters wake on `200`, vector-scoped waiters ignore non-matching `200`, then wake on matching `13`, and invalid vector `65536` is rejected with `LAST_RESULT=-22` against the freestanding PVH artifact
- optional QEMU interrupt-filter wrapper validation now fails directly on the interrupt-any waiting baseline, exact any-wake payload, blocked vector-scoped nonmatch state, exact matching-vector wake payload, and invalid-vector preserved mailbox/wake invariants on that dedicated interrupt-filter lane
- optional QEMU vector-counter-reset wrapper validation now fails directly on the baseline artifact/mailbox state, dirty aggregate counts, dirty pre-reset vector tables, preserved aggregate totals, preserved last-vector telemetry, zeroed post-reset vector tables, and final reset-mailbox receipt on that dedicated reset lane
- optional QEMU manual-wait interrupt probe validates `command_task_wait` isolation end to end, proving a manual waiter remains blocked with an empty wake queue after interrupt `44`, then resumes correctly through an explicit `command_scheduler_wake_task` against the freestanding PVH artifact
  - optional QEMU manual-wait interrupt wrapper validation now fails directly on the one-task baseline, blocked post-interrupt waiting state, preserved interrupt telemetry, exact manual-wake payload, and final ready-state/mailbox invariants on that dedicated manual-wait lane
  - optional QEMU wake-queue FIFO probe validates `command_wake_queue_pop` end to end, proving the oldest queued manual wake is removed first, the second queued wake becomes the new logical head (`seq=2`, `tick=7`), and a final pop on the empty queue returns `result_not_found`
  - optional QEMU wake-queue FIFO wrapper validation now fails directly on the two-entry baseline, first-pop oldest-first removal, survivor payload preservation, drained-empty collapse, and final notfound-plus-empty-state invariants on that dedicated FIFO lane
  - optional QEMU wake-queue summary/age wrapper validation now fails directly on the five-entry baseline shape, pre-drain summary snapshot, pre-drain age-bucket snapshot, post-drain summary snapshot, and post-drain age-bucket plus final-stability invariants on that exported summary-pointer lane
  - optional QEMU wake-queue selective probe validates timer, interrupt, and manual wake generation plus `pop_reason`, `pop_vector`, `pop_reason_vector`, and `pop_before_tick` queue drains end to end against the freestanding PVH artifact
  - optional QEMU wake-queue selective wrapper validation now fails directly on the baseline five-entry mixed queue shape, reason-drain survivor ordering, vector-drain survivor ordering, exact reason+vector drain survivor ordering, and the final before-tick/invalid-pair preserved-state boundary on that dedicated mixed-queue lane
  - optional QEMU wake-queue selective-overflow probe validates wrapped-ring selective drains end to end, proving `66` alternating `interrupt@13` / `interrupt@31` wakes retain FIFO survivor ordering through `command_wake_queue_pop_vector` and `command_wake_queue_pop_reason_vector`
  - optional QEMU wake-queue selective-overflow wrapper validation now fails directly on the wrapped overflow baseline, post-vector drain collapse, lone retained `interrupt@13` survivor ordering, post-reason+vector collapse, and final all-`vector=31` survivor ordering on that dedicated wrapped-ring lane
  - optional QEMU wake-queue before-tick-overflow probe validates wrapped-ring deadline drains end to end, proving the same `66` alternating `interrupt@13` / `interrupt@31` wakes can be drained in FIFO windows via `command_wake_queue_pop_before_tick` down to empty, with the final empty-queue call returning `result_not_found`
  - optional QEMU wake-queue before-tick-overflow wrapper validation now fails directly on the wrapped baseline, the first threshold cutoff, the first survivor window, the second cutoff to only `seq=66`, and the final empty/notfound preserved-state boundary on that dedicated wrapped deadline-drain lane
  - optional QEMU wake-queue before-tick wrapper validation now fails directly on the baseline four-entry queue shape, first stale cutoff, bounded second drain to the final survivor, final `result_not_found`, and preserved final survivor state after the rejected drain on that dedicated mixed-queue lane
  - optional QEMU wake-queue reason-overflow probe validates wrapped-ring mixed manual/interrupt drains end to end, proving `66` alternating manual / `interrupt@13` wakes preserve FIFO survivor ordering through `command_wake_queue_pop_reason(manual,31)` and final `command_wake_queue_pop_reason(manual,99)`
  - optional QEMU wake-queue reason-overflow wrapper validation now fails directly on the wrapped mixed-reason baseline, post-manual drain collapse, lone retained manual survivor ordering, post-final manual drain collapse, and final all-interrupt survivor ordering on that dedicated wrapped-ring lane
  - optional QEMU wake-queue summary/age probe validates exported summary and age-bucket telemetry snapshots before and after selective queue drains against the freestanding PVH artifact
  - optional QEMU wake-queue count-snapshot wrapper probes validate the live count-query lane directly, failing on baseline queue ordering, staged query-count deltas, and nonmutating mailbox-read invariants without relying only on the broad mixed-queue script output
  - optional QEMU wake-queue overflow probe validates sustained manual wake pressure end to end, proving the 64-entry ring saturates cleanly with `head/tail=2`, `overflow=2`, and retained oldest/newest manual wake payloads at `seq 3` and `seq 66`
  - optional QEMU wake-queue overflow wrapper validation now fails directly on the `66`-wake baseline, wrapped ring shape, oldest retained payload, newest retained payload, and final mailbox receipt on that dedicated sustained-manual-pressure lane
  - optional QEMU wake-queue clear probe validates wrapped-ring clear-and-reuse end to end, proving `command_wake_queue_clear` resets `count/head/tail/overflow` to `0`, clears pending wake telemetry, and restarts the next manual wake at `seq 1`
  - optional QEMU wake-queue clear wrapper validation now fails directly on the wrapped baseline, post-clear ring collapse, post-clear pending-wake reset, post-reuse queue shape, and post-reuse payload invariants on that dedicated clear-and-reuse lane
  - optional QEMU wake-queue batch-pop probe validates post-overflow recovery end to end, proving a `62`-entry batch drain leaves `seq 65/66`, a default pop leaves only `seq 66`, a final drain empties the queue, and the next manual wake reuses the ring at `seq 67`
  - optional QEMU wake-queue batch-pop wrapper probes validate that same broad lane at five narrower boundaries, failing directly on overflow baseline stability, retained survivor pair `seq 65/66`, single-survivor state, drained-empty state, and refill/reuse receipt invariants instead of only at the end of the full overflow-to-refill sequence
  - optional QEMU wake-queue vector-pop probe validates the dedicated `command_wake_queue_pop_vector` lane end to end, proving a four-entry mixed queue (`manual`, `interrupt@13`, `interrupt@13`, `interrupt@31`) removes only the matching vector-`13` wakes in FIFO order and returns `result_not_found` for vector `255`
  - optional QEMU wake-queue reason-vector-pop probe validates the dedicated `command_wake_queue_pop_reason_vector` lane end to end, proving a four-entry mixed queue (`manual`, `interrupt@13`, `interrupt@13`, `interrupt@19`) removes only the exact `interrupt@13` pairs in FIFO order and rejects `reason+vector=0` with `-22`
  - optional QEMU wake-queue reason-vector-pop wrapper validation now fails directly on baseline composition, first exact-pair removal, final survivor ordering, invalid-pair rejection, and invalid-pair state preservation on that dedicated four-entry mixed queue lane
  - optional QEMU allocator/syscall probe validates alloc/free plus syscall register/invoke/block/disable/re-enable/clear-flags/unregister flow end to end against the freestanding PVH artifact, then proves `command_allocator_reset` and `command_syscall_reset` collapse the dirty runtime state back to allocator/syscall steady baseline
  - optional QEMU allocator/syscall reset probe validates the dedicated dirty-state recovery lane without saturation noise, proving live allocator alloc plus syscall register/invoke state is visible before reset, `command_allocator_reset` and `command_syscall_reset` independently collapse both subsystems back to steady baseline, and a final missing-entry invoke returns `result_not_found`
  - optional QEMU syscall saturation probe validates the dedicated syscall-table capacity and reuse lane without allocator noise, proving 64/64 registration, overflow rejection, reclaimed-slot reuse, and fresh invoke telemetry against the freestanding PVH artifact
  - optional QEMU syscall saturation reset probe validates the dedicated reset lane without allocator noise, proving a fully saturated syscall table plus dirty dispatch telemetry collapse back to reset steady state and that the next fresh syscall register/invoke path restarts cleanly from slot `0`
- optional QEMU syscall saturation reset wrapper probes isolate that lane into the final mailbox baseline, dirty pre-reset saturated shape, post-reset zero-entry baseline, clean slot-0 restart, and fresh post-reset invoke telemetry checks against the freestanding PVH artifact
  - optional QEMU allocator saturation reset probe validates the dedicated allocator-table reset lane without syscall noise, proving all 64 allocator records fill cleanly, the next allocation returns `no_space`, `command_allocator_reset` collapses counters/bitmap/records to steady state, and a fresh 2-page allocation restarts cleanly from slot `0`
  - optional QEMU allocator saturation reuse probe validates the dedicated allocator-table reuse lane without syscall noise, proving the full 64-record table rejects overflow, `command_allocator_free` reclaims a middle slot, the next 2-page allocation reuses that record slot, and first-fit page search moves to pages `64-65` because page `6` still blocks the freed region
  - optional QEMU allocator free-failure probe validates the dedicated `command_allocator_free` error lane without syscall noise, proving wrong-pointer `not_found`, wrong-size `invalid_argument`, successful free metadata updates, double-free `not_found`, and post-failure reallocation from page `0`
  - optional QEMU allocator free-failure wrapper validation isolates the narrower allocator-free contracts on top of the broad probe: initial allocation baseline, wrong-pointer `not_found` preservation, wrong-size `invalid_argument` preservation, successful free metadata update, and double-free plus clean realloc restart
  - optional QEMU syscall control probe validates the dedicated mutation lane (`command_syscall_register`, `command_syscall_set_flags`, `command_syscall_disable`, `command_syscall_enable`, `command_syscall_unregister`) plus invoke behavior without allocator noise against the freestanding PVH artifact
  - optional QEMU direct syscall-control wrapper validation isolates the narrower dedicated mutation stages on top of the broad probe: register baseline, re-register token update without growth, blocked invoke state, enabled invoke telemetry, unregister cleanup, and final steady state
  - optional QEMU command-result counters probe validates categorized mailbox result accounting live under QEMU+GDB, proving `ok`, `invalid`, `not_supported`, and `other_error` buckets increment correctly and `command_reset_command_result_counters` collapses the struct back to a single reset `ok`
  - optional QEMU command-result counter wrapper probes now isolate the narrow pre-reset envelope and each mailbox result bucket directly: baseline status/counter shape, `ok`, `invalid_argument`, `not_supported`, and `other_error`
  - optional QEMU reset-counters probe validates `command_reset_counters` end to end after dirtying interrupt, exception, scheduler, allocator, syscall, timer, wake-queue, mode, boot-phase, command-history, and health-history state, proving the runtime collapses back to the expected steady baseline under QEMU+GDB
  - optional QEMU reset-preservation wrapper probes now enforce the narrow recovery boundaries directly: `reset-counters` preserves configured `feature_flags` and `tick_batch_hint`; `reset_boot_diagnostics` preserves runtime mode and existing histories; `clear_command_history` preserves health history; `clear_health_history` preserves command history; and `reset_command_result_counters` preserves live runtime posture while collapsing counters to the single reset receipt
  - optional QEMU reset-counters wrapper probes now isolate the broader runtime reset boundary directly: baseline mailbox/status envelope, vector counter/history collapse, command/health/mode/boot history collapse, scheduler/allocator/syscall/timer/wake subsystem collapse, and final command-result receipt shape after `command_reset_counters`
  - optional QEMU interrupt/exception reset-isolation wrapper probes now enforce the narrow vector-control boundaries directly: `reset_interrupt_counters` preserves interrupt history plus exception aggregates; `reset_exception_counters` preserves exception history plus interrupt history; `clear_interrupt_history` preserves sibling exception history; and `reset_vector_counters` preserves aggregate counts plus last-vector telemetry while the per-vector tables zero
  - optional QEMU interrupt-mask/exception probe validates masked external vectors stay blocked while exception vectors still flow through wait/wake and history telemetry against the freestanding PVH artifact
  - optional QEMU interrupt-mask/exception wrapper probes isolate the masked baseline, blocked external suppression, exception wake delivery, captured histories, and final ready-state wake payload on top of the same PVH lane
  - optional QEMU interrupt-mask profile probe validates profile application, selective unmask/remask, ignored-count reset, external-high masking, invalid profile rejection, and clear-all recovery against the freestanding PVH artifact
  - bare-metal ABI now includes exported kernel info + command mailbox hooks (`oc_kernel_info_ptr`, `oc_command_ptr`, `oc_submit_command`, `oc_tick_n`)
  - bare-metal boot diagnostics ABI now exported with phase/command/tick telemetry and stack snapshot helpers (`oc_boot_diag_ptr`, `oc_boot_diag_capture_stack`)
  - bare-metal command history ABI now exported for mailbox execution tracing (`oc_command_history_capacity`, `oc_command_history_len`, `oc_command_history_event`, `oc_command_history_clear`)
  - bare-metal health history ABI now exported for tick/command health telemetry (`oc_health_history_capacity`, `oc_health_history_len`, `oc_health_history_event`, `oc_health_history_clear`)
  - bare-metal mode history ABI now exported for runtime/command panic transition telemetry (`oc_mode_history_capacity`, `oc_mode_history_len`, `oc_mode_history_event`, `oc_mode_history_clear`)
  - bare-metal boot-phase history ABI now exported for init/runtime/panic phase transitions (`oc_boot_phase_history_capacity`, `oc_boot_phase_history_len`, `oc_boot_phase_history_event`, `oc_boot_phase_history_clear`)
  - bare-metal command-result counters ABI now exported for mailbox result-category telemetry (`oc_command_result_total_count`, `oc_command_result_count_ok`, `oc_command_result_count_invalid_argument`, `oc_command_result_count_not_supported`, `oc_command_result_count_other_error`, `oc_command_result_counters_clear`)
  - bare-metal scheduler/task ABI now exported for cooperative kernel scheduling telemetry and control (`oc_scheduler_state_ptr`, `oc_scheduler_enabled`, `oc_scheduler_task_capacity`, `oc_scheduler_task_count`, `oc_scheduler_task`, `oc_scheduler_tasks_ptr`, `oc_scheduler_reset`)
  - bare-metal memory allocator + syscall table ABI now exported for kernel heap-page allocation and syscall dispatch control (`oc_allocator_state_ptr`, `oc_allocator_page_count`, `oc_allocator_page_bitmap_ptr`, `oc_allocator_allocation_count`, `oc_allocator_allocation`, `oc_allocator_reset`, `oc_syscall_state_ptr`, `oc_syscall_entry_count`, `oc_syscall_entry`, `oc_syscall_reset`)
  - command mailbox interrupt controls are available (`trigger_interrupt`, `trigger_exception`, `reset_interrupt_counters`, `reset_exception_counters`, `reset_vector_counters`, `clear_interrupt_history`, `clear_exception_history`, `reinit_descriptor_tables`)
  - wake queue selective controls are available:
    - reason-selective drain (`command_wake_queue_pop_reason`) with reason-count telemetry (`oc_wake_queue_reason_count`)
    - vector-selective drain (`command_wake_queue_pop_vector`) with vector-count telemetry (`oc_wake_queue_vector_count`)
    - stale-entry drain by deadline (`command_wake_queue_pop_before_tick`) with deadline-count telemetry (`oc_wake_queue_before_tick_count`)
    - reason+vector selective drain (`command_wake_queue_pop_reason_vector`) with pair-count telemetry (`oc_wake_queue_reason_vector_count`)
    - count-query snapshot pointers (`oc_wake_queue_count_query_ptr`, `oc_wake_queue_count_snapshot_ptr`) for live vector/reason/deadline backlog snapshots without mutating queue state
    - queue summary snapshot export (`oc_wake_queue_summary`) with reason mix, nonzero-vector count, stale count, and oldest/newest tick telemetry
    - queue age-bucket snapshot export (`oc_wake_queue_age_buckets`) with current-tick, quantum, stale/future split, and stale-older-than-quantum telemetry
- x86 bootstrap exports now include descriptor table pointers, load telemetry, interrupt telemetry, exception/fault counters, vector counters, and bounded interrupt/exception history rings (`oc_gdtr_ptr`, `oc_idtr_ptr`, `oc_gdt_ptr`, `oc_idt_ptr`, `oc_descriptor_tables_loaded`, `oc_descriptor_load_attempt_count`, `oc_descriptor_load_success_count`, `oc_try_load_descriptor_tables`, `oc_interrupt_count`, `oc_last_interrupt_vector`, `oc_interrupt_vector_count`, `oc_exception_vector_count`, `oc_last_exception_vector`, `oc_exception_count`, `oc_last_exception_code`, `oc_interrupt_history_capacity`, `oc_interrupt_history_len`, `oc_interrupt_history_event`, `oc_interrupt_history_clear`, `oc_exception_history_capacity`, `oc_exception_history_len`, `oc_exception_history_event`, `oc_exception_history_clear`, `oc_descriptor_init_count`, `oc_interrupt_state_ptr`)
- Recent bare-metal wrapper-isolation slices:
  - timer disable/re-enable lane now has dedicated QEMU wrappers for arm preservation, deadline hold beyond the original fire tick, deferred wake ordering after re-enable, timer-only wake payload retention, and post-reenable dispatch/drain semantics
  - scheduler policy-switch lane now has dedicated QEMU wrappers for round-robin baseline fairness, high-priority dominance after switching to priority policy, low-task takeover after reprioritization, round-robin return ordering, and invalid-policy preservation
- Recent optimization slices (2026-03-04):
  - memory/runtime/channel queue compaction and retention hardening
  - diagnostics docker probe caching
  - registry lookup hot-path optimization
  - dispatcher bounded-history one-pass compaction
  - browser completion execution telemetry hardening (`bridgeCompletion` failure/success semantics)
  - browser context-injection hardening for completion payloads:
    - new request controls: `sessionId|session_id`, `includeToolContext`, `includeMemoryContext`, `memoryContextLimit`
    - completion path now injects runtime tool capability context + session memory recap
    - response telemetry now exposes injection status (`context.toolContextInjected`, `context.memoryContextInjected`, `context.memoryEntriesUsed`, `context.error`)
  - Telegram runtime authorized-chat bridge path:
    - authorized non-command Telegram messages now attempt live Lightpanda completion before echo fallback
    - `send` responses now expose `replySource` (`bridge_completion`, `runtime_echo`, `auth_required`, `command`) for deterministic reply provenance
  - send channel-alias parity:
    - `send` now accepts Go-compatible channel aliases (`web`, `console`, `terminal`, `tg`, `tele`) and normalizes to canonical channels (`webchat`, `cli`, `telegram`)
    - omitted-channel `send|chat.send|sessions.send` now inherit the session channel (defaulting to `webchat` when no session channel is known)
    - session-channel routing is now persisted in compat state (`sessionChannels`) and survives history trimming/restarts
    - `poll` remains Telegram-only and returns deterministic unsupported-channel errors for non-Telegram polling requests
  - runtime policy hardening:
    - configurable filesystem sandbox for `file.read` / `file.write` (`OPENCLAW_ZIG_RUNTIME_FILE_SANDBOX_ENABLED`, `OPENCLAW_ZIG_RUNTIME_FILE_ALLOWED_ROOTS`)
    - configurable `exec.run` gate + allowlist (`OPENCLAW_ZIG_RUNTIME_EXEC_ENABLED`, `OPENCLAW_ZIG_RUNTIME_EXEC_ALLOWLIST`)
- Next-generation update/release slice:
  - channel-aware update lifecycle (`update.plan`, `update.status`, `update.run`)
  - npm client package and release pipeline (`@adybag14-cyber/openclaw-zig-rpc-client`)
  - Python client package + PyPI/uvx release pipeline (`openclaw-zig-rpc-client`)

## Scope and Policy

- Preserve JSON-RPC contract compatibility while porting runtime behavior to Zig.
- Keep security, browser/auth, Telegram, memory, and edge flows fully stateful (no placeholder stubs for advertised methods).
- Browser bridge policy in Zig is **Lightpanda-only**; Playwright/Puppeteer are rejected in runtime dispatch contracts.
- Push each completed parity slice to `main`; release tags only after parity + validation gates are green for the release cut.

## Baselines

- Historical bootstrap commit: Go baseline `65c974b528e2` (`v2.10.2-go` line)
- Active parity baselines are resolved by gate script:
  - `adybag14-cyber/openclaw-go-port`
  - `openclaw/openclaw` latest stable release
  - `openclaw/openclaw` latest prerelease (beta)

## Tracking

- Plan: [`docs/zig-port/PORT_PLAN.md`](docs/zig-port/PORT_PLAN.md)
- Checklist: [`docs/zig-port/PHASE_CHECKLIST.md`](docs/zig-port/PHASE_CHECKLIST.md)
- Package publishing and install paths: [`docs/package-publishing.md`](docs/package-publishing.md)
- Local Zig toolchain notes: [`docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md`](docs/zig-port/ZIG_TOOLCHAIN_LOCAL.md)
- GitHub master tracking issue: <https://github.com/adybag14-cyber/openclaw-zig-port/issues/1>
- Full method registry (source of truth): [`src/gateway/registry.zig`](src/gateway/registry.zig)
- GitHub Pages docs site (after first deploy): <https://adybag14-cyber.github.io/openclaw-zig-port/>

## Architecture Overview

- Runtime profiles:
  - OS-hosted runtime: full HTTP/RPC gateway and feature surface.
  - Bare-metal runtime: freestanding image exporting lifecycle hooks (`_start`, `oc_tick`, `oc_tick_n`, `oc_status_ptr`) plus command/mailbox ABI (`oc_command_ptr`, `oc_submit_command`, `oc_kernel_info_ptr`), descriptor table/int-vector bootstrap exports, and a Multiboot2 header for bootloader/hypervisor integration.
- Protocol: JSON-RPC request/response envelopes with deterministic error semantics.
- Gateway: HTTP/WebSocket server with `GET /health`, `GET /ui`, `POST /rpc`, and websocket RPC routes (`GET /ws` + root compatibility on `GET /`), graceful shutdown via RPC.
- Dispatcher: method routing and contract handling across runtime, security, browser/auth, channels, memory, and edge domains.
- Runtime: session/job state, tool runtime actions, compat state surfaces.
- Security: guard, loop-guard, doctor/security audit, remediation (`--fix`) path.
- Browser/Auth: Lightpanda browser request contract + web login session lifecycle.
- Channels: Telegram command/reply queue with auth/model controls and polling.
- Memory: persistent local store with history/trim/delete/compact primitives.
- Edge: wasm lifecycle, routing/acceleration/swarm/multimodal/voice, enclave/mesh/homomorphic/finetune and related advanced contracts.

## Feature Coverage

All major runtime feature domains are implemented and dispatchable. Representative method groups are listed below; full list is in [`registry.zig`](src/gateway/registry.zig).

### 1) Protocol and Gateway

- Connectivity and health:
  - `connect`, `health`, `status`, `shutdown`
- Gateway routes:
  - `GET /health`
  - `POST /rpc`
  - `GET /ws` websocket upgrade route (JSON-RPC over text and binary websocket frames)
  - `GET /` websocket compatibility route for legacy bridge clients
- Contract coverage guard:
  - test asserts every registered method resolves in dispatcher (no registry/dispatcher drift).

### 2) Runtime and Tool Runtime

- Tool execution and filesystem actions:
  - `exec.run`
  - `file.read`
  - `file.write`
- Runtime and session surfaces:
  - `sessions.list`, `sessions.preview`, `session.status`
  - `sessions.patch`, `sessions.resolve`
  - `sessions.history`, `chat.history`
  - `sessions.reset`, `sessions.delete`, `sessions.compact`
  - `sessions.usage`, `sessions.usage.timeseries`, `sessions.usage.logs`
- Queue/runtime telemetry:
  - exposed through status/doctor and channel status snapshots.

### 3) Security and Diagnostics

- Prompt/tool safety layers:
  - risk scoring + loop guard behavior
  - blocked pattern policy checks
- Diagnostics methods:
  - `security.audit`
  - `doctor`
  - `doctor.memory.status`
- CLI diagnostics:
  - `--doctor`
  - `--security-audit --deep`
  - `--security-audit --deep --fix` (remediation actions)
- Secrets/config resolution:
  - `secrets.reload`
  - `secrets.resolve` with config overlay and env alias fallback resolution.

### 4) Browser Bridge and Auth

- Browser runtime policy:
  - Lightpanda-only runtime in dispatcher contracts.
  - Playwright/Puppeteer requests are intentionally rejected.
- Browser and login lifecycle:
  - `browser.request`
  - `browser.open`
  - `web.login.start`
  - `web.login.wait`
  - `web.login.complete`
  - `web.login.status`
- OAuth alias surfaces for compatibility:
  - `auth.oauth.providers`
  - `auth.oauth.start`
  - `auth.oauth.wait`
  - `auth.oauth.complete`
  - `auth.oauth.logout`
  - `auth.oauth.import`
- Provider/auth breadth:
  - `chatgpt`, `codex`, `claude`, `gemini`, `openrouter`, `opencode`
  - guest-capable browser session providers: `qwen`, `zai/glm-5`, `inception/mercury-2`
  - additional provider aliases: `minimax`, `kimi`, `zhipuai`

### 5) Channels and Telegram

- Channel methods:
  - `channels.status`
  - `channels.logout`
  - `send`, `chat.send`, `sessions.send`
  - `poll`
- Telegram command surface:
  - `/auth` lifecycle (`start`, `status`, `wait`, `link`, `open`, `complete`, `guest`, `cancel`, `providers`, `bridge`)
  - `/model` lifecycle (set/status/reset)
  - account-scoped auth bindings and `--force` session rotation
- Queue behavior:
  - bounded retention (`max_queue_entries`, default `4096`)
  - single-pass FIFO compaction on poll/drain paths.

### 6) Memory System

- Persistent memory store:
  - append/history/stats/persistence roundtrip
  - session delete + trim + compact semantics
- Memory-backed runtime methods:
  - `sessions.history`
  - `chat.history`
  - `doctor.memory.status`
- Safety/perf:
  - linear compaction and batched front-removal for bounded retention.

### 7) Edge and Advanced Features

- Wasm lifecycle and marketplace:
  - `edge.wasm.marketplace.list`
  - `edge.wasm.install`
  - `edge.wasm.execute`
  - `edge.wasm.remove`
- Planning and acceleration:
  - `edge.router.plan`
  - `edge.acceleration.status`
  - `edge.swarm.plan`
  - `edge.collaboration.plan`
- Multimodal and voice:
  - `edge.multimodal.inspect`
  - `edge.voice.transcribe`
- Enclave/mesh/homomorphic:
  - `edge.enclave.status`
  - `edge.enclave.prove`
  - `edge.mesh.status`
  - `edge.homomorphic.compute`
- Finetune/self-evolution:
  - `edge.finetune.run`
  - `edge.finetune.status`
  - `edge.finetune.job.get`
  - `edge.finetune.cancel`
  - `edge.finetune.cluster.plan`
- Additional edge parity contracts:
  - `edge.identity.trust.status`
  - `edge.personality.profile`
  - `edge.handoff.plan`
  - `edge.marketplace.revenue.preview`
  - `edge.alignment.evaluate`
  - `edge.quantum.status`

### 8) Operations, Agents, Device/Node, and Compat Surfaces

- Agent and skill surfaces:
  - `agent`, `agent.identity.get`, `agent.wait`
  - `agents.list/create/update/delete`
  - `agents.files.list/get/set`
  - `skills.status/bins/install/update`
- Cron:
  - `cron.list/status/add/update/remove/run/runs`
- Device:
  - `device.pair.list/approve/reject/remove`
  - `device.token.rotate/revoke`
- Node and approval workflow:
  - `node.pair.request/list/approve/reject/verify`
  - `node.rename/list/describe/invoke/invoke.result/event`
  - `node.canvas.capability.refresh`
  - `exec.approvals.get/set`
  - `exec.approvals.node.get/set`
  - `exec.approval.request/waitdecision/resolve`
- Conversation/voice/TTS/system:
  - `talk.config`, `talk.mode`
  - `voicewake.get`, `voicewake.set`
  - `tts.status`, `tts.enable`, `tts.disable`, `tts.providers`, `tts.setProvider`, `tts.convert`
  - `models.list`, `chat.abort`, `chat.inject`
  - `usage.status`, `usage.cost`, `last-heartbeat`, `set-heartbeats`, `system-presence`, `system-event`, `wake`
  - `push.test`, `logs.tail`, `canvas.present`, `update.plan`, `update.status`, `update.run`, `wizard.start/next/cancel/status`

## Performance and Reliability Improvements

Implemented optimization hardening includes:

- memory store linear compaction and batched front-removal
- runtime queue head-offset dequeue + amortized compaction
- Telegram poll one-pass compaction and bounded queue retention
- doctor docker probe cache (process-local)
- registry supports fast-path exact-match lookup
- dispatcher bounded-history one-pass compaction for capped lists

## Known Constraints (Intentional)

- Browser runtime in Zig remains Lightpanda-only by policy.
- Local Windows zig master toolchain can lag Codeberg `master`; freshness is tracked and reported each session.
- Some cross-target failures can be toolchain-specific on local Windows while CI Linux runners pass full cross-target matrices.

## Quick Start

```bash
zig build
zig build run
zig build test
zig build baremetal
```

Run gateway serve mode:

```bash
zig build run -- --serve
```

Core routes:

- `GET /health`
- `POST /rpc`
- `GET /ws`
- `GET /` (websocket compatibility route)
- graceful shutdown via RPC method `shutdown`

## Validation and Diagnostics

Run full local syntax/build checks:

```powershell
./scripts/zig-syntax-check.ps1
```

Install docs dependencies and build docs locally:

```powershell
python -m pip install -r requirements-docs.txt
./scripts/generate-rpc-reference.ps1
mkdocs build --strict
```

Run doctor/security audit from CLI:

```powershell
zig build run -- --doctor
zig build run -- --security-audit --deep
zig build run -- --security-audit --deep --fix
```

Check Zig Codeberg freshness against local toolchain:

```powershell
./scripts/zig-codeberg-master-check.ps1
./scripts/zig-codeberg-master-check.ps1 -OutputJsonPath .\release\zig-master-freshness.json
```

Check the GitHub Windows release mirror and plan a refresh:

```powershell
./scripts/zig-github-mirror-release-check.ps1 -OutputJsonPath .\release\zig-github-mirror-release.json -OutputMarkdownPath .\release\zig-github-mirror-release.md
./scripts/zig-bootstrap-from-github-mirror.ps1 -DryRun -OutputJsonPath .\release\zig-bootstrap-dry-run.json
./scripts/zig-bootstrap-from-github-mirror.ps1 -UpstreamSha <codeberg-master-sha>
```

Mirror policy:

- `latest-master` is the fast Windows refresh lane.
- `upstream-<sha>` is the reproducible lane for CI, bisects, and release recreation.
- `scripts/zig-codeberg-master-check.ps1` compares Codeberg `master`, the local Zig binary, and the GitHub mirror release target/digest in one report.

Run parity gate and emit evidence artifacts:

```powershell
./scripts/check-go-method-parity.ps1
./scripts/check-go-method-parity.ps1 -OutputJsonPath .\release\parity-go-zig.json -OutputMarkdownPath .\release\parity-go-zig.md
./scripts/docs-status-check.ps1 -ParityJsonPath .\release\parity-go-zig.json
```

Run smoke checks:

```powershell
./scripts/docker-smoke-check.ps1
./scripts/baremetal-smoke-check.ps1
./scripts/baremetal-qemu-smoke-check.ps1
./scripts/baremetal-qemu-runtime-oc-tick-check.ps1
./scripts/baremetal-qemu-command-loop-check.ps1
./scripts/runtime-smoke-check.ps1
./scripts/appliance-control-plane-smoke-check.ps1
./scripts/appliance-restart-recovery-smoke-check.ps1
./scripts/gateway-auth-smoke-check.ps1
./scripts/websocket-smoke-check.ps1
./scripts/web-login-smoke-check.ps1
./scripts/browser-request-success-smoke-check.ps1
./scripts/browser-request-direct-provider-success-smoke-check.ps1
./scripts/telegram-reply-loop-smoke-check.ps1
```

Validate npm package publishability:

```powershell
./scripts/npm-pack-check.ps1
```

Validate python package publishability:

```powershell
./scripts/python-pack-check.ps1
```

Run local preview packaging with CI-aligned validate gates:

```powershell
./scripts/release-preview.ps1 -Version <release-tag>
```

## CI and Release

`zig-ci` workflow (`.github/workflows/zig-ci.yml`):

- Zig master build/test gates
- Zig master freshness snapshot (`scripts/zig-codeberg-master-check.ps1`) with Codeberg->GitHub mirror fallback
- Zig GitHub mirror release snapshot (`scripts/zig-github-mirror-release-check.ps1`) for rolling/immutable Windows asset evidence
- tri-baseline method/event parity enforcement (Go latest + original stable latest + original beta latest)
- docs status drift gate (`scripts/docs-status-check.ps1`) against parity snapshot + latest release tag
- freestanding bare-metal artifact smoke gate
- optional bare-metal QEMU boot smoke gate
- optional bare-metal QEMU runtime probe
- optional bare-metal QEMU command-loop probe
- optional bare-metal QEMU mailbox header validation probe
- optional bare-metal QEMU mailbox stale-seq probe
- optional bare-metal QEMU mailbox seq-wraparound probe
- optional bare-metal QEMU feature-flags/tick-batch probe
- optional bare-metal QEMU descriptor bootdiag probe
- optional bare-metal QEMU descriptor bootdiag wrapper probes
- optional bare-metal QEMU bootdiag/history-clear probe
- optional bare-metal QEMU descriptor table content probe
- optional bare-metal QEMU descriptor dispatch probe
- optional bare-metal QEMU vector counter reset probe
- optional bare-metal QEMU vector history clear probe
- optional bare-metal QEMU vector history clear wrapper probes
- optional bare-metal QEMU mode/boot-phase history clear probe
- optional bare-metal QEMU scheduler probe
- optional bare-metal QEMU scheduler default-budget invalid probe
- optional bare-metal QEMU scheduler timeslice-update probe
- optional bare-metal QEMU scheduler timeslice baseline probe
- optional bare-metal QEMU scheduler timeslice update-4 probe
- optional bare-metal QEMU scheduler timeslice update-2 probe
- optional bare-metal QEMU scheduler timeslice invalid-zero preserve probe
- optional bare-metal QEMU scheduler timeslice final task-state probe
- optional bare-metal QEMU scheduler disable-enable probe
- optional bare-metal QEMU scheduler disable-enable baseline probe
- optional bare-metal QEMU scheduler disable-enable disabled-freeze probe
- optional bare-metal QEMU scheduler disable-enable idle-preserve probe
- optional bare-metal QEMU scheduler disable-enable resume probe
- optional bare-metal QEMU scheduler disable-enable final task-state probe
- optional bare-metal QEMU scheduler reset probe
- optional bare-metal QEMU scheduler reset baseline probe
- optional bare-metal QEMU scheduler reset collapse probe
- optional bare-metal QEMU scheduler reset id-restart probe
- optional bare-metal QEMU scheduler reset defaults-preserve probe
- optional bare-metal QEMU scheduler reset final task-state probe
- optional bare-metal QEMU scheduler reset mixed-state probe
- optional bare-metal QEMU scheduler policy-switch probe
- optional bare-metal QEMU scheduler saturation probe
- optional bare-metal QEMU timer wake probe
- optional bare-metal QEMU timer quantum probe
- optional bare-metal QEMU timer quantum wrapper probes
- optional bare-metal QEMU timer cancel probe
- optional bare-metal QEMU timer cancel-task interrupt-timeout probe
- optional bare-metal QEMU timer cancel-task interrupt-timeout wrapper probes
- optional bare-metal QEMU timer cancel task probe
- optional bare-metal QEMU timer cancel task wrapper probes
- optional bare-metal QEMU timer pressure probe
- optional bare-metal QEMU timer pressure wrapper probes
- optional bare-metal QEMU timer reset recovery probe
- optional bare-metal QEMU periodic timer probe
- optional bare-metal QEMU periodic timer wrapper probes
- optional bare-metal QEMU periodic interrupt probe
- optional bare-metal QEMU interrupt timeout probe
- optional bare-metal QEMU interrupt timeout manual wake probe
- optional bare-metal QEMU scheduler-wake timer-clear probe
- optional bare-metal QEMU scheduler-wake timer-clear wrapper probes
- optional bare-metal QEMU interrupt timeout timer probe
- optional bare-metal QEMU masked interrupt timeout probe
- optional bare-metal QEMU masked interrupt timeout wrapper probes
- optional bare-metal QEMU interrupt timeout clamp probe
- optional bare-metal QEMU interrupt-timeout clamp wrappers:
  - baseline
  - arm-preservation
  - saturated-boundary
  - wake-payload
  - final-telemetry
- optional bare-metal QEMU interrupt filter probe
- optional bare-metal QEMU task-terminate interrupt-timeout probe
- optional bare-metal QEMU task-terminate interrupt-timeout wrapper probes
- optional bare-metal QEMU timer-disable interrupt probe
- optional bare-metal QEMU timer-disable reenable probe
- optional bare-metal QEMU timer-disable paused-state probe
- optional bare-metal QEMU timer-disable reenable one-shot recovery probe
- optional bare-metal QEMU interrupt-timeout disable-enable probe
- optional bare-metal QEMU interrupt-timeout disable-reenable timer probe
- optional bare-metal QEMU interrupt-timeout disable-interrupt probe
- optional bare-metal QEMU interrupt-timeout disable-interrupt recovery probe
- optional bare-metal QEMU timer-reset wait-kind isolation probe
- optional bare-metal QEMU timer-reset pure-wait recovery probe
- optional bare-metal QEMU timer-reset timeout-interrupt recovery probe
- optional bare-metal QEMU scheduler reset wake-clear probe
- optional bare-metal QEMU scheduler reset timer-clear probe
- optional bare-metal QEMU scheduler reset config-preservation probe
- optional bare-metal QEMU manual wait interrupt probe
- optional bare-metal QEMU manual wait interrupt wrapper probes
- optional bare-metal QEMU wake-queue selective probe
- optional bare-metal QEMU wake-queue selective wrapper probes
- optional bare-metal QEMU wake-queue selective-overflow probe
- optional bare-metal QEMU wake-queue selective-overflow wrapper probes
- optional bare-metal QEMU wake-queue before-tick-overflow probe
- optional bare-metal QEMU wake-queue before-tick-overflow wrapper probes
- optional bare-metal QEMU wake-queue before-tick wrapper probes
- optional bare-metal QEMU wake-queue reason-overflow probe
- optional bare-metal QEMU wake-queue reason-overflow wrapper probes
- optional bare-metal QEMU wake-queue summary/age probe
- optional bare-metal QEMU wake-queue overflow probe
- optional bare-metal QEMU wake-queue clear wrapper probes
- optional bare-metal QEMU wake-queue batch-pop probe
- optional bare-metal QEMU wake-queue batch-pop wrapper probes
- optional bare-metal QEMU wake-queue vector-pop probe
- optional bare-metal QEMU wake-queue reason-vector-pop probe
- optional bare-metal QEMU wake-queue reason-vector-pop wrapper probes
- optional bare-metal QEMU allocator syscall probe
- optional bare-metal QEMU allocator syscall reset probe
- optional bare-metal QEMU syscall saturation probe
- optional bare-metal QEMU syscall saturation reset probe
- optional bare-metal QEMU syscall saturation reset wrapper probes
- optional bare-metal QEMU allocator saturation reset probe
- optional bare-metal QEMU allocator saturation reuse probe
- optional bare-metal QEMU allocator free failure probe
- optional bare-metal QEMU allocator free failure wrapper validation
- optional bare-metal QEMU syscall control probe
- optional bare-metal QEMU syscall wrapper validation
- optional bare-metal QEMU allocator syscall failure probe
- optional bare-metal QEMU command-result counters probe
- optional bare-metal QEMU reset counters probe
- optional bare-metal QEMU task lifecycle probe
- optional bare-metal QEMU active-task terminate probe
- optional bare-metal QEMU interrupt mask exception probe
- optional bare-metal QEMU interrupt mask profile probe
- optional bare-metal QEMU interrupt mask control probe
- optional bare-metal QEMU interrupt mask control baseline probe
- optional bare-metal QEMU interrupt mask control unmask-delivery probe
- optional bare-metal QEMU interrupt mask control invalid-preserve probe
- optional bare-metal QEMU interrupt mask control reset-ignored probe
- optional bare-metal QEMU interrupt mask control final-state probe
- optional bare-metal QEMU interrupt mask clear-all recovery probe
- optional bare-metal QEMU interrupt mask custom-profile preserve probe
- optional bare-metal QEMU interrupt mask invalid-input preserve-state probe
- optional bare-metal QEMU interrupt mask reset-ignored preserve-mask probe
- optional bare-metal QEMU interrupt mask profile boundary probe
- optional bare-metal QEMU interrupt mask exception baseline probe
- optional bare-metal QEMU interrupt mask exception masked-interrupt blocked probe
- optional bare-metal QEMU interrupt mask exception-delivery probe
- optional bare-metal QEMU interrupt mask exception history-capture probe
- optional bare-metal QEMU interrupt mask exception final-state probe
- runtime smoke gate
- appliance control-plane smoke gate (`system.boot.*`, `system.rollback.*`, secure-boot-gated `update.run`)
- appliance restart recovery smoke gate (persisted `compat-state.json` replay across stop/start)
- appliance rollout boundary smoke gate (real `canary` lane selection, secure-boot block, canary-to-stable promotion)
- appliance minimal profile smoke gate (readiness contract for persisted state, control-plane auth, secure-boot gating, signer, and fresh verification)
- FS6 appliance/bare-metal closure gate (`scripts/appliance-baremetal-closure-smoke-check.ps1`, composed acceptance across appliance control-plane, minimal profile, rollout, restart recovery, bare-metal smoke, QEMU smoke, runtime, and command-loop)
- parity evidence artifact publication (`parity-go-zig.json`, `parity-go-zig.md`)

`docs-pages` workflow (`.github/workflows/docs-pages.yml`):

- regenerates and verifies `docs/rpc-reference.md` from `src/gateway/registry.zig`
- runs parity snapshot + docs status drift gate before publish
- builds MkDocs docs (`mkdocs build --strict`)
- publishes docs to GitHub Pages from `site/`
- triggers on `docs/**`, `mkdocs.yml`, and docs workflow changes

`release-preview` workflow (`.github/workflows/release-preview.yml`):

- upfront validate job (build + test + parity)
- docs status drift gate (`scripts/docs-status-check.ps1`) in release validate stage
- zig master freshness snapshot + artifact publication (`zig-master-freshness.json`)
- GitHub mirror release snapshot + artifact publication (`zig-github-mirror-release.json`, `zig-github-mirror-release.md`)
- freestanding bare-metal smoke validation
- optional bare-metal QEMU boot smoke validation
- optional bare-metal QEMU runtime validation
- optional bare-metal QEMU command-loop validation
- optional bare-metal QEMU feature-flags/tick-batch validation
- optional bare-metal QEMU descriptor bootdiag validation
- optional bare-metal QEMU descriptor bootdiag wrapper validation
- optional bare-metal QEMU descriptor table content validation
- optional bare-metal QEMU descriptor dispatch validation
- optional bare-metal QEMU vector counter reset validation
- optional bare-metal QEMU vector history clear validation
- optional bare-metal QEMU scheduler validation
- optional bare-metal QEMU timer wake validation
- optional bare-metal QEMU timer quantum validation
- optional bare-metal QEMU timer quantum wrapper validation
- optional bare-metal QEMU timer cancel validation
- optional bare-metal QEMU timer cancel wrapper validation
- optional bare-metal QEMU timer pressure validation
- optional bare-metal QEMU timer pressure wrapper validation
- optional bare-metal QEMU periodic timer validation
- optional bare-metal QEMU periodic timer wrapper validation
- optional bare-metal QEMU interrupt timeout validation
- optional bare-metal QEMU interrupt timeout manual-wake validation
- optional bare-metal QEMU interrupt timeout timer validation
- optional bare-metal QEMU masked interrupt timeout validation
- optional bare-metal QEMU masked interrupt timeout wrapper validation
- optional bare-metal QEMU interrupt timeout clamp validation
- optional bare-metal QEMU interrupt filter validation
- optional bare-metal QEMU manual wait interrupt validation
- optional bare-metal QEMU manual wait interrupt wrapper validation
- optional bare-metal QEMU wake-queue selective validation
- optional bare-metal QEMU wake-queue selective wrapper validation
- optional bare-metal QEMU wake-queue selective-overflow validation
- optional bare-metal QEMU wake-queue selective-overflow wrapper validation
- optional bare-metal QEMU wake-queue before-tick-overflow validation
- optional bare-metal QEMU wake-queue before-tick-overflow wrapper validation
- optional bare-metal QEMU wake-queue before-tick wrapper validation
- optional bare-metal QEMU wake-queue reason-overflow validation
- optional bare-metal QEMU wake-queue reason-overflow wrapper validation
- optional bare-metal QEMU wake-queue summary/age validation
- optional bare-metal QEMU wake-queue overflow validation
- optional bare-metal QEMU wake-queue clear wrapper validation
- optional bare-metal QEMU wake-queue batch-pop validation
- optional bare-metal QEMU wake-queue batch-pop wrapper validation
- optional bare-metal QEMU wake-queue vector-pop validation
- optional bare-metal QEMU wake-queue reason-pop wrapper validation
- optional bare-metal QEMU wake-queue reason-vector-pop validation
- optional bare-metal QEMU wake-queue reason-vector-pop wrapper validation
- optional bare-metal QEMU allocator syscall validation
- optional bare-metal QEMU allocator syscall reset wrapper validation
- optional bare-metal QEMU syscall saturation validation
- optional bare-metal QEMU syscall saturation reset validation
- optional bare-metal QEMU syscall saturation reset wrapper validation
- optional bare-metal QEMU allocator saturation reset validation
- optional bare-metal QEMU allocator saturation reset wrapper validation
- optional bare-metal QEMU allocator saturation reuse validation
- optional bare-metal QEMU allocator saturation reuse wrapper validation
- optional bare-metal QEMU allocator free failure validation
- optional bare-metal QEMU allocator free failure wrapper validation
- optional bare-metal QEMU syscall control validation
- optional bare-metal QEMU syscall wrapper validation
- optional bare-metal QEMU allocator syscall failure validation
- optional bare-metal QEMU command-result counters validation
- optional bare-metal QEMU reset counters validation
- optional bare-metal QEMU interrupt mask profile validation
- optional bare-metal QEMU interrupt mask control validation
- optional bare-metal QEMU interrupt mask control wrapper validation:
  - direct-mask baseline
  - unmask wake delivery
  - invalid vector/state preserve custom profile state
  - ignored-count reset after secondary direct mask
  - final clear-all steady-state recovery
- optional bare-metal QEMU interrupt mask wrapper validation
- appliance control-plane smoke validation
- appliance restart recovery validation
- appliance rollout boundary validation
- appliance minimal profile validation
- full preview artifact matrix build and publish
- includes bare-metal release artifact: `openclaw-zig-<version>-x86_64-freestanding-none.elf`
- duplicate release tag guard
- release asset parity evidence attachment
- release asset zig freshness evidence attachment
- release asset GitHub mirror release evidence attachment
- release trust evidence attachment (`release-manifest.json`, `sbom.spdx.json`, `provenance.intoto.json`)
- npm package dry-run validation gate in validate stage
- local `scripts/release-preview.ps1` mirrors parity/docs/freshness gates before packaging

`npm-release` workflow (`.github/workflows/npm-release.yml`):

- publishes `@adybag14-cyber/openclaw-zig-rpc-client` to npm
- supports `workflow_dispatch` (manual version + dist-tag) and `release.published`
- uses `NPM_TOKEN` for npmjs publish with provenance when available
- falls back to GitHub Packages publish (`npm.pkg.github.com`) when `NPM_TOKEN` is missing
- always builds and attaches the npm tarball to the matching GitHub release tag when present

`python-release` workflow (`.github/workflows/python-release.yml`):

- builds and validates `openclaw-zig-rpc-client` (unit tests + wheel/sdist + twine check)
- supports `workflow_dispatch` with explicit Python version and optional release tag
- supports `release.published` trigger with release-tag to PEP 440 version normalization
- publishes to PyPI when `PYPI_API_TOKEN` is configured
- always uploads python build artifacts and attaches them to matching GitHub release when found

Manual release-preview trigger:

```powershell
gh workflow run release-preview.yml -R adybag14-cyber/openclaw-zig-port -f version=<release-tag>
```

Manual npm release trigger:

```powershell
gh workflow run npm-release.yml -R adybag14-cyber/openclaw-zig-port -f version=<release-tag> -f dist_tag=edge
```

Manual python release trigger:

```powershell
gh workflow run python-release.yml -R adybag14-cyber/openclaw-zig-port -f version=<pep440-version> -f release_tag=<release-tag>
```




