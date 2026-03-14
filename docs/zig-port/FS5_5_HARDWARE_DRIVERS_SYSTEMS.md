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
  - first usable MBR partition mount from sector `0`, with logical LBA translation above the mounted partition base
  - hosted mock-device support for deterministic regression coverage
- `src/pal/storage.zig` now routes through the backend facade instead of directly through the RAM disk
- `src/baremetal/tool_layout.zig` now routes through the backend facade instead of directly through the RAM disk
- host regressions now prove:
  - the storage facade prefers ATA PIO when a device is present
  - ATA PIO mock-device mount and identify-backed capacity detection
  - first-partition MBR mounting with logical base-LBA translation
  - ATA PIO mock-device read/write/flush behavior
- bare-metal exports now report ATA PIO as the active backend when a device is present
- the live freestanding/QEMU ATA proof is now strict-closed through:
  - `scripts/baremetal-qemu-ata-storage-probe-check.ps1`
  - a real MBR-partitioned raw image attached to the freestanding PVH artifact
  - raw ATA-backed block mutation + readback at physical-on-disk LBAs behind the mounted logical partition view
  - tool-layout persistence through the ATA-backed shared storage facade on that partition-mounted view
  - path-based filesystem persistence through the ATA-backed shared storage facade on that partition-mounted view

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

Status: `Complete`

Notes:

- strict Ethernet L2 closure did **not** imply ARP, IPv4, UDP, DHCP, DNS, or TCP closure; that gap is now closed for the FS5.5 acceptance bar
- the strict networking slices above the raw-frame RTL8139 path are now complete locally:
  - `src/protocol/ethernet.zig` encodes and decodes Ethernet headers
  - `src/protocol/arp.zig` encodes ARP request/reply frames and decodes ARP frames
  - `src/protocol/ipv4.zig` encodes and decodes IPv4 headers and validates header checksums
  - `src/protocol/udp.zig` encodes and decodes UDP datagrams and validates pseudo-header checksums
- `src/protocol/tcp.zig` now also provides a minimal session/state machine for client/server handshake, established payload exchange, bounded four-way teardown, bounded FIN-timeout recovery during teardown, bounded multi-flow session-table management, and bounded cumulative-ACK advancement across multiple in-flight payload chunks
- `src/protocol/tcp.zig` now also provides client-side SYN retransmission/timeout recovery for the initial handshake path, established-payload retransmission/timeout recovery, client/responder FIN retransmission/timeout recovery during teardown, strict remote-window enforcement for bounded sequential payload chunking, zero-window blocking until a pure ACK reopens the remote window, and exact bytes-in-flight accounting for the bounded send path
- `src/pal/net.zig` exposes:
    - `sendArpRequest`
    - `pollArpPacket`
    - `sendIpv4Frame`
    - `pollIpv4PacketStrict`
    - `sendUdpPacket`
    - `pollUdpPacketStrictInto`
    - `sendTcpPacket`
    - `pollTcpPacketStrictInto`
    - `configureIpv4Route`
    - `configureIpv4RouteFromDhcp`
    - `resolveNextHop`
  - `learnArpPacket`
  - `sendUdpPacketRouted`
- host regressions prove mock-device ARP, IPv4, UDP, DHCP, DNS, TCP handshake/payload exchange, bounded four-way close, dropped-first-SYN retransmission/timeout recovery, dropped-first-payload retransmission/timeout recovery, dropped-first-FIN retransmission/timeout recovery on both close sides, bounded multi-flow session isolation, bounded cumulative-ACK advancement across multiple in-flight payload chunks, DHCP-driven route configuration, gateway ARP learning, routed off-subnet UDP delivery, and direct-subnet UDP bypass through the RTL8139 path
- `src/baremetal/tool_service.zig` now provides a bounded framed request/response shim on top of the bare-metal tool substrate for the TCP path, with typed `CMD`, `GET`, `PUT`, `STAT`, `PKG`, `PKGLIST`, and `PKGRUN` requests plus bounded batched request parsing/execution on one flow
- live QEMU proofs now pass:
  - `scripts/baremetal-qemu-rtl8139-arp-probe-check.ps1`
  - `scripts/baremetal-qemu-rtl8139-ipv4-probe-check.ps1`
  - `scripts/baremetal-qemu-rtl8139-udp-probe-check.ps1`
  - `scripts/baremetal-qemu-rtl8139-tcp-probe-check.ps1`
  - `scripts/baremetal-qemu-rtl8139-gateway-probe-check.ps1`
- `src/baremetal_main.zig` host regressions now also prove TCP zero-window block/reopen behavior, framed multi-request command-service exchange on a single live flow, bounded long-response chunking under the advertised remote window, bounded typed batch request multiplexing on one live flow, typed `PUT`/`GET`/`STAT` service behavior, persisted `run-script` execution through the framed TCP service seam, and package install/list/run behavior on the canonical package layout
- those proofs now cover live ARP request transmission, IPv4 frame encode/decode, UDP datagram encode/decode, TCP `SYN -> SYN-ACK -> ACK` handshake plus payload exchange, dropped-first-SYN recovery, dropped-first-payload recovery, dropped-first-FIN recovery on both close sides, bounded four-way close, bounded two-flow session isolation, zero-window block/reopen, bounded sequential payload chunking, framed TCP command-service exchange, bounded typed batch request multiplexing on one flow with concatenated framed responses, typed TCP `PUT` upload, direct filesystem readback of the uploaded script path, typed `PKG` / `PKGLIST` / `PKGRUN` package-service exchange, canonical package entrypoint readback, package output readback, and TX/RX counter advance over the freestanding PVH image
  - the live package-service extension required a real probe-stack fix: `runRtl8139TcpProbe()` now uses static scratch storage, reducing the project-built bare-metal stack frame from `0x3e78` to `0x3708` bytes before the live QEMU proof would pass with package install/list/run enabled
  - the routed UDP proof now also covers live ARP-reply learning, ARP-cache population, gateway next-hop selection for off-subnet traffic, direct-subnet gateway bypass, and routed UDP delivery with the gateway MAC on the Ethernet frame while preserving the remote IPv4 destination
- A real DHCP framing/decode slice is now also closed locally:
  - `src/protocol/dhcp.zig` provides strict DHCP discover encode/decode
  - `src/pal/net.zig` exposes DHCP send/poll helpers for the hosted/mock path
  - `scripts/baremetal-qemu-rtl8139-dhcp-probe-check.ps1` now proves real RTL8139 TX/RX of a DHCP discover payload over a loopback-safe UDP transport envelope, followed by strict DHCP decode and TX/RX counter advance
- A real DNS framing/decode slice is now also closed locally:
  - `src/protocol/dns.zig` provides strict DNS query and A-response encode/decode
  - `src/pal/net.zig` exposes `sendDnsQuery`, `pollDnsPacket`, and `pollDnsPacketStrictInto`
  - host regressions prove DNS query encode/decode, DNS A-response decode, and strict rejection of non-DNS UDP frames over the mock RTL8139 path
  - `scripts/baremetal-qemu-rtl8139-dns-probe-check.ps1` now proves real RTL8139 TX/RX of a DNS query plus strict decode/validation of a DNS A response over the freestanding PVH artifact
- deeper networking depth remains future work above the FS5.5 closure bar:
  - sliding-window and congestion-control behavior beyond the current bounded zero-window reopen + sequential chunk-and-ACK session model
  - higher-level service/runtime layers beyond the current bounded typed batch file/package seam on the bare-metal TCP path
  - higher-level protocol/service layers above the current DHCP/DNS/TCP proof surfaces

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
  - `/tools/scripts/bootstrap.oc`
  - `/tools/script/output.txt`

### Bare-Metal Tool Execution

Status: `Complete`

Current local source-of-truth evidence:

- `src/baremetal/tool_exec.zig` now provides the real freestanding builtin command substrate used by the bare-metal PAL, including persisted `run-script` execution and canonical `run-package` execution on the bare-metal filesystem.
- `src/baremetal/package_store.zig` now provides the canonical persisted package layout used by the bare-metal execution and TCP service seams:
  - `/packages/<name>/bin/main.oc`
  - `/packages/<name>/meta/package.txt`
- `src/pal/proc.zig` now exposes an explicit `runCaptureFreestanding(...)` path instead of pretending the hosted child-process path is valid on `freestanding`.
- `src/baremetal/tool_service.zig` now exposes a bounded typed framed request/response shim on top of `tool_exec.runCapture(...)`, `package_store`, and the bare-metal filesystem for the TCP path.
- the execution path now closes its dependency chain through real FS5.5 storage/filesystem layers:
  - `src/baremetal/filesystem.zig`
  - `src/pal/fs.zig`
  - `src/baremetal/storage_backend.zig`
  - attached ATA-backed media in the live probe
- the tool-exec proof is wired directly into `src/baremetal_main.zig` as a dedicated freestanding validation path.
- `scripts/baremetal-qemu-tool-exec-probe-check.ps1` now proves end-to-end bare-metal command execution over the freestanding PVH image with an attached disk by validating:
  - `help`
  - `mkdir /tools/tmp`
  - `write-file /tools/tmp/tool.txt baremetal-tool`
  - `cat /tools/tmp/tool.txt`
  - `stat /tools/tmp/tool.txt`
  - `run-script /tools/scripts/bootstrap.oc`
  - direct filesystem readback of `baremetal-tool`
  - direct filesystem readback of `script-data` after filesystem reset/re-init
  - `echo tool-exec-ok`
- host/module validation now also proves the same path through:
  - `zig test src/baremetal/tool_exec.zig`
  - `zig test src/baremetal/tool_service.zig`
  - `zig test src/baremetal/package_store.zig`
  - the hosted regression in `src/baremetal_main.zig`
- those host/module proofs now also cover:
  - persisted ATA-backed package layout roundtrips
  - typed TCP `PKG` / `PKGLIST` / `PKGRUN` service behavior
  - canonical `run-package <name>` execution against `/packages/<name>/bin/main.oc`

## Non-Goals For This Track

- hosted-only PAL wrappers do not count as FS5.5 completion
- synthetic wrapper-only proofs do not count as hardware completion by themselves
- CI green alone does not imply hardware completion

## Completion Rule

`FS5.5` is only complete when every subsystem above is implemented and validated end to end with the dependency chain satisfied.

Current local source-of-truth verdict: every FS5.5 subsystem above is now implemented and validated end to end with the stated dependency chain satisfied.
