# FS5.5 Hardware Drivers And Systems

## Purpose

`FS5.5` is the strict hardware-driver and bare-metal systems track that sits between hosted-phase closure (`FS1..FS5`) and appliance/bare-metal maturity (`FS6`).

This track exists to remove guesswork. It defines the real bare-metal subsystems that must exist as code, not as checklist language:

- framebuffer text and console
- keyboard input
- mouse input
- in-RAM disk persistence
- disk driver and block-device usage
- ethernet device driver
- tcp/ip stack bring-up
- bare-metal filesystem usage
- bare-metal tool execution substrate

`FS5.5` is not complete until each subsystem has:

1. a real Zig implementation path
2. a PAL-facing surface
3. host regression coverage where possible
4. at least one bare-metal proof path where hardware semantics matter
5. explicit dependency closure recorded below

## Dependency Order

The order is strict because later subsystems depend on earlier operator and storage surfaces.

1. console / framebuffer text
2. keyboard + mouse
3. in-RAM disk persistence
4. disk driver + block I/O usage
5. ethernet driver
6. tcp/ip
7. filesystem-on-block or filesystem-on-RAM-disk usage
8. bare-metal tool execution substrate

## Success Gates

### 1. Console / Framebuffer Text

Required:

- exported bare-metal console state ABI
- real VGA text-mode implementation on `freestanding + x86_64`
- host-backed test fallback for deterministic regression tests
- PAL console surface
- host regression proving clear/write/cell/cursor behavior
- bare-metal proof path reading back console state/cells

### 2. Keyboard / Mouse

Required:

- interrupt-driven input state capture
- exported key/mouse state ABI
- PAL input surface
- explicit key queue / mouse packet semantics
- bare-metal proof path showing IRQ-driven state updates

### 3. In-RAM Disk Persistence

Required:

- stable block-device abstraction
- fixed-capacity RAM disk
- read/write/flush semantics
- persistence across runtime operations inside the same boot session
- PAL storage surface

### 4. Disk Driver / Block I/O

Required:

- real device-facing block path
- request / response / error state
- read and write path
- geometry/capacity exposure
- at least one bare-metal proof of block mutation and readback

### 5. Ethernet Driver

Required:

- TX/RX ring or equivalent device state
- MAC address exposure
- packet send / receive path
- interrupt or poll-driven receive semantics
- PAL network-device surface

### 6. TCP/IP

Required:

- frame ingress/egress through the ethernet path
- IPv4 framing
- ARP handling
- UDP minimum viable send/receive
- TCP handshake + payload path or an explicitly defined staged gate if UDP is the first strict slice
- bare-metal proof of packet exchange against deterministic harness traffic

### 7. Filesystem Usage

Required:

- filesystem operations backed by RAM disk or disk driver
- directory creation
- file read/write/stat
- integration through PAL FS surface
- proof that tool or runtime state can persist via that path

### 8. Bare-Metal Tool Execution

Required:

- explicit execution model, not a hosted-process stub
- command/task dispatch substrate using bare-metal scheduler, storage, and console/network surfaces
- observable stdout/stderr or console output path
- storage/network dependencies satisfied for any claimed download or file-use scenario

## Current Status

### Console / Framebuffer Text

Status: `In progress`

Current local source-of-truth evidence:

- console ABI added
- VGA text console module added
- PAL console surface added
- host regression proves clear/write/cell/cursor behavior
- live bare-metal PVH/QEMU proof now passes:
  - exported console state has `magic=console_magic`, `api_version=2`, `cols=80`, `rows=25`
  - runtime reports `backend=vga_text`
  - runtime startup banner writes `OK`
  - raw VGA memory at `0xB8000` reads back `O` and `K`

Remaining gap before this subsystem is fully closed:

- a framebuffer path beyond VGA text mode is not implemented yet

### Keyboard / Mouse

Status: `Complete`

Current local source-of-truth evidence:

- real PS/2-style keyboard and mouse state machine shipped in `src/baremetal/ps2_input.zig`
- real x86 port-I/O backed PS/2 controller path shipped in `src/baremetal/ps2_input.zig`:
  - controller data/status/command ports `0x60` / `0x64`
  - controller config read/write
  - controller keyboard + mouse enable flow
  - output-buffer drain and mouse-byte packet assembly
- interrupt-driven capture is wired through the existing x86 interrupt history path:
  - keyboard IRQ vector `33`
  - mouse IRQ vector `44`
- exported bare-metal keyboard/mouse ABI state now exists in `src/baremetal/abi.zig`
- PAL input surface shipped in `src/pal/input.zig`
- bare-metal export surface shipped in `src/baremetal_main.zig`
- host regressions prove:
  - keyboard modifier and scancode queue capture through IRQ delivery
  - mouse packet queue and position accumulator updates through IRQ delivery
- bare-metal proof path now exists:
  - `scripts/baremetal-qemu-ps2-input-probe-check.ps1`
  - wrapper probes for:
    - baseline mailbox/device state
    - keyboard event payloads
    - keyboard modifier + queue state
    - mouse accumulator state
    - mouse packet payloads

### In-RAM Disk Persistence

Status: `Complete`

Current local source-of-truth evidence:

- stable block-device abstraction shipped in `src/baremetal/ram_disk.zig`
- fixed-capacity RAM disk implemented with:
  - `2048` blocks
  - `512` byte block size
  - read/write/flush semantics
  - dirty-state tracking
  - read/write byte and block telemetry
- PAL storage surface shipped in `src/pal/storage.zig`
- bare-metal export surface shipped in `src/baremetal_main.zig`
- tool-slot persistence layer shipped in `src/baremetal/tool_layout.zig`
- host regressions prove:
  - raw block mutation + readback
  - flush clears dirty state
  - tool-slot payload persistence across runtime operations inside the same boot session
  - clear/rewrite behavior on the same RAM-disk-backed layout

### Disk Driver / Block I/O

Status: `In progress`

Current local source-of-truth evidence:

- a real block read/write contract now exists via the RAM-disk backend
- tool-layout metadata and payload writes already exercise that block path end to end

Remaining gap before this subsystem is fully closed:

- no real hardware-facing disk controller path exists yet
- no ATA/AHCI/NVMe-style device bring-up, request queue, or hardware readback proof exists yet

### Ethernet Driver

Status: `Not started`

### TCP/IP

Status: `Not started`

### Filesystem Usage

Status: `In progress`

Current local source-of-truth evidence:

- tool-layout persistence is now backed by real RAM-disk blocks
- runtime can store and clear deterministic tool payloads through that path

Remaining gap before this subsystem is fully closed:

- no directory/file abstraction exists yet
- no `create/read/write/stat` filesystem surface is implemented on the bare-metal storage backend
- no path-based persistence proof exists yet

### Bare-Metal Tool Execution

Status: `Not started`

## Non-Goals For This Track

- hosted-only PAL wrappers do not count as FS5.5 completion
- synthetic wrapper-only proofs do not count as hardware completion by themselves
- CI green alone does not imply hardware completion

## Completion Rule

`FS5.5` is only complete when every subsystem above is implemented and validated end to end with the dependency chain satisfied.
