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

Status: `Complete`

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
- a real linear-framebuffer path now exists beyond VGA text mode:
  - `src/baremetal/framebuffer_console.zig` programs Bochs/QEMU BGA linear framebuffer mode and renders glyphs into a `640x400x32bpp` surface
  - `src/baremetal/pci.zig` discovers the display adapter BAR and enables decode on the selected PCI display function
  - `src/pal/framebuffer.zig` exposes the framebuffer path through the PAL surface
  - `src/baremetal_main.zig` exports framebuffer state/pixel access through the bare-metal ABI
- host regressions now prove the framebuffer export surface updates host-backed framebuffer state and glyph pixels
- a live bare-metal PVH/QEMU proof now passes:
  - `scripts/baremetal-qemu-framebuffer-console-probe-check.ps1`
  - exported framebuffer state has `magic=framebuffer_magic`, `api_version=2`, `width=640`, `height=400`, `cols=80`, `rows=25`
  - runtime reports `backend=linear_framebuffer`
  - the startup banner writes `OK`
  - actual MMIO framebuffer pixels read back `bg`, `O`, and `K` from the hardware-backed framebuffer BAR

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

Status: `Complete`

Current local source-of-truth evidence:

- a shared storage backend facade now exists in `src/baremetal/storage_backend.zig`
- the backend facade now selects between:
  - `src/baremetal/ram_disk.zig`
  - `src/baremetal/ata_pio_disk.zig`
- `src/baremetal/ata_pio_disk.zig` now contains a real x86 ATA PIO path with:
  - primary ATA port access (`0x1F0..0x1F7`, `0x3F6`)
  - `IDENTIFY DEVICE` bring-up
  - sector-count discovery from identify words `60/61`
  - sector `READ`, `WRITE`, and `CACHE FLUSH`
  - hosted mock-device support for deterministic regression coverage
- `src/pal/storage.zig` now routes through the backend facade instead of directly through the RAM disk
- `src/baremetal/tool_layout.zig` now routes through the backend facade instead of directly through the RAM disk
- host regressions now prove:
  - the storage facade prefers ATA PIO when a device is present
  - ATA PIO mock-device mount and identify-backed capacity detection
  - ATA PIO mock-device read/write/flush behavior
- bare-metal exports now report ATA PIO as the active backend when a device is present
- the live freestanding/QEMU ATA proof is now strict-closed through:
  - `scripts/baremetal-qemu-ata-storage-probe-check.ps1`
  - raw ATA-backed block mutation + readback at live LBAs
  - tool-layout persistence through the ATA-backed shared storage facade
  - path-based filesystem persistence through the ATA-backed shared storage facade

Notes:

- the strict FS5.5 gate only requires one real device-facing block path with live bare-metal mutation + readback proof; ATA PIO satisfies that gate now
- AHCI/NVMe remain future depth, not a blocker for current FS5.5 disk closure

### Ethernet Driver

Status: `Complete`

Current local source-of-truth evidence:

- `src/baremetal/rtl8139.zig` now contains a real RTL8139 driver path with:
  - PCI-discovered device bring-up
  - MAC readout
  - RX ring programming
  - TX slot programming
  - deterministic loopback-friendly TX/RX validation
  - explicit datapath and error telemetry
- `src/baremetal/pci.zig` now discovers vendor `0x10EC` / device `0x8139`, extracts the I/O BAR and IRQ line, and enables I/O plus bus-master decode on the selected PCI function
- `src/baremetal/abi.zig` now exports `BaremetalEthernetState`
- `src/baremetal_main.zig` now exports the bare-metal Ethernet surface:
  - `oc_ethernet_state_ptr`
  - `oc_ethernet_init`
  - `oc_ethernet_reset`
  - `oc_ethernet_mac_byte`
  - `oc_ethernet_send_pattern`
  - `oc_ethernet_poll`
  - `oc_ethernet_rx_byte`
  - `oc_ethernet_rx_len`
- `src/pal/net.zig` now exposes the bare-metal raw-frame PAL seam through the same RTL8139 driver path instead of a fake transport
- host regressions now prove mock-device initialization, raw-frame send, receive, ABI export, and PAL bridging
- the live freestanding/QEMU proof is now green:
  - `scripts/baremetal-qemu-rtl8139-probe-check.ps1`
  - MAC readout succeeds
  - TX succeeds
  - RX loopback succeeds
  - payload length and byte pattern are validated
  - TX/RX counters advance over the hardware-backed PVH image

### TCP/IP

Status: `In progress`

Notes:

- strict Ethernet L2 closure did **not** imply ARP, IPv4, UDP, DHCP, DNS, or TCP closure
- the first strict networking slices above the raw-frame RTL8139 path are now complete locally:
  - `src/protocol/ethernet.zig` encodes and decodes Ethernet headers
  - `src/protocol/arp.zig` encodes ARP request frames and decodes ARP frames
  - `src/protocol/ipv4.zig` encodes and decodes IPv4 headers and validates header checksums
  - `src/protocol/udp.zig` encodes and decodes UDP datagrams and validates pseudo-header checksums
  - `src/protocol/tcp.zig` encodes and decodes strict TCP headers, validates pseudo-header checksums, and rejects unsupported options in this slice
  - `src/pal/net.zig` exposes:
    - `sendArpRequest`
    - `pollArpPacket`
    - `sendIpv4Frame`
    - `pollIpv4PacketStrict`
    - `sendUdpPacket`
    - `pollUdpPacketStrictInto`
    - `sendTcpPacket`
    - `pollTcpPacketStrictInto`
  - host regressions prove mock-device ARP, IPv4, UDP, and TCP loopback/decode through the RTL8139 path
  - live QEMU proofs now pass:
    - `scripts/baremetal-qemu-rtl8139-arp-probe-check.ps1`
    - `scripts/baremetal-qemu-rtl8139-ipv4-probe-check.ps1`
    - `scripts/baremetal-qemu-rtl8139-udp-probe-check.ps1`
    - `scripts/baremetal-qemu-rtl8139-tcp-probe-check.ps1`
  - those proofs now cover live ARP request transmission, IPv4 frame encode/decode, UDP datagram encode/decode, TCP segment encode/decode, and TX/RX counter advance over the freestanding PVH image
- The strict staged TCP gate is now the framing/payload slice over RTL8139 loopback.
- A real DHCP framing/decode slice is now also closed locally:
  - `src/protocol/dhcp.zig` provides strict DHCP discover encode/decode
  - `src/pal/net.zig` exposes DHCP send/poll helpers for the hosted/mock path
  - `scripts/baremetal-qemu-rtl8139-dhcp-probe-check.ps1` now proves real RTL8139 TX/RX of a DHCP discover payload over a loopback-safe UDP transport envelope, followed by strict DHCP decode and TX/RX counter advance
- A real DNS framing/decode slice is now also closed locally:
  - `src/protocol/dns.zig` provides strict DNS query and A-response encode/decode
  - `src/pal/net.zig` exposes `sendDnsQuery`, `pollDnsPacket`, and `pollDnsPacketStrictInto`
  - host regressions prove DNS query encode/decode, DNS A-response decode, and strict rejection of non-DNS UDP frames over the mock RTL8139 path
  - `scripts/baremetal-qemu-rtl8139-dns-probe-check.ps1` now proves real RTL8139 TX/RX of a DNS query plus strict decode/validation of a DNS A response over the freestanding PVH artifact
- full TCP handshake/connection management remains open.

### Filesystem Usage

Status: `Complete`

Current local source-of-truth evidence:

- `src/baremetal/filesystem.zig` now implements a real path-based bare-metal filesystem layer on top of the shared storage backend
- directory creation is implemented through `createDirPath`
- file write/read/stat are implemented through `writeFile`, `readFileAlloc`, and `statNoFollow`
- `src/pal/fs.zig` now routes the freestanding PAL surface through that filesystem layer instead of requiring hosted filesystem calls
- `src/baremetal_main.zig` now exports filesystem state and entry metadata through the bare-metal ABI surface
- host regressions and module tests prove path-based persistence on:
  - the RAM-disk backend
  - the ATA PIO backend
- runtime-style state payloads now persist and reload through that path:
  - `/runtime/state/agent.json`
  - `/tools/cache/tool.txt`

### Bare-Metal Tool Execution

Status: `Not started`

## Non-Goals For This Track

- hosted-only PAL wrappers do not count as FS5.5 completion
- synthetic wrapper-only proofs do not count as hardware completion by themselves
- CI green alone does not imply hardware completion

## Completion Rule

`FS5.5` is only complete when every subsystem above is implemented and validated end to end with the dependency chain satisfied.
