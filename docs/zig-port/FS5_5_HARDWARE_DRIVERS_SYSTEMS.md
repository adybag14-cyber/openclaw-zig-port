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

Status: `Not started`

### In-RAM Disk Persistence

Status: `Not started`

### Disk Driver / Block I/O

Status: `Not started`

### Ethernet Driver

Status: `Not started`

### TCP/IP

Status: `Not started`

### Filesystem Usage

Status: `Not started`

### Bare-Metal Tool Execution

Status: `Not started`

## Non-Goals For This Track

- hosted-only PAL wrappers do not count as FS5.5 completion
- synthetic wrapper-only proofs do not count as hardware completion by themselves
- CI green alone does not imply hardware completion

## Completion Rule

`FS5.5` is only complete when every subsystem above is implemented and validated end to end with the dependency chain satisfied.
