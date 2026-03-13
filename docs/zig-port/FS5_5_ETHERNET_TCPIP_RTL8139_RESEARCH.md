# FS5.5 Ethernet/TCP-IP First Slice Research: RTL8139 on QEMU x86_64 Bare Metal

## Purpose
This report defines the first real bare-metal Ethernet slice for `openclaw-zig-port` using an RTL8139 NIC under QEMU on `x86_64-freestanding`. It is intentionally strict:

- no checklist-only progress
- no abstraction-first work without hardware proof
- no TCP/IP claims before a real L2 device path exists
- no PAL networking surface that bypasses the actual device driver

This slice is the minimum acceptable foundation for later IPv4, ARP, UDP, DHCP, DNS, TCP, and higher-level tool execution over the network.

## Current Local Status

The first strict Ethernet slice is now complete on the local source of truth:

- `src/baremetal/rtl8139.zig` is implemented
- `src/baremetal/pci.zig` discovers the RTL8139 I/O BAR and IRQ line and enables I/O plus bus-master decode
- `src/pal/net.zig` exposes the raw-frame PAL seam through the real driver path
- `src/baremetal_main.zig` exports the bare-metal Ethernet ABI surface
- `scripts/baremetal-qemu-rtl8139-probe-check.ps1` is green and proves live MAC readout, TX, RX loopback, payload validation, and TX/RX counter advance over the freestanding PVH image

This report remains relevant because the first strict networking lift above ARP is now implemented, and the next remaining strict networking slices are TCP, DHCP, and DNS above the now-real L2 + ARP + IPv4 + UDP path.

## Scope of This First Slice
This slice must deliver a real, deterministic Layer 2 path:

- PCI discovery of an RTL8139 device
- device power-up and reset
- MAC address readout
- TX descriptor/buffer programming
- RX ring setup and polling
- deterministic packet send proof
- deterministic packet receive proof
- bare-metal PAL seam for raw Ethernet frames

This slice originally did **not** attempt to finish:

- ARP
- IPv4
- ICMP
- UDP
- TCP
- DHCP
- DNS
- HTTP

That constraint is now partially lifted. The repo now has real ARP, IPv4, and UDP encode/decode paths above the strict Ethernet L2 slice, but it still does **not** claim TCP, DHCP, or DNS completion.

## Current ARP + IPv4 + UDP Slice Status

The first strict ARP + IPv4 + UDP slices are now complete on the local source of truth:

- `src/protocol/ethernet.zig` provides real Ethernet header encode/decode helpers and constants
- `src/protocol/arp.zig` provides ARP request frame encode plus full ARP frame decode
- `src/protocol/ipv4.zig` provides IPv4 header encode/decode plus checksum validation
- `src/protocol/udp.zig` provides UDP header encode/decode plus pseudo-header checksum validation
- `src/pal/net.zig` now exposes:
  - `sendArpRequest`
  - `pollArpPacket`
  - `sendIpv4Frame`
  - `pollIpv4PacketStrict`
  - `sendUdpPacket`
  - `pollUdpPacketStrictInto`
- `src/baremetal_main.zig` now contains a dedicated `rtl8139_arp_probe` boot path and host regression proving ARP request loopback through the RTL8139 mock path
- `src/baremetal_main.zig` now also contains dedicated `rtl8139_ipv4_probe` and `rtl8139_udp_probe` boot paths with host regressions proving live IPv4 and UDP loopback through the RTL8139 mock path
- `scripts/baremetal-qemu-rtl8139-arp-probe-check.ps1` now proves live ARP request transmission, receipt, decode, and counter advance against the freestanding PVH image
- `scripts/baremetal-qemu-rtl8139-ipv4-probe-check.ps1` now proves live IPv4 frame transmission, receipt, decode, and counter advance against the freestanding PVH image
- `scripts/baremetal-qemu-rtl8139-udp-probe-check.ps1` now proves live UDP datagram transmission, receipt, decode, checksum validation, and counter advance against the freestanding PVH image

This closes the first real Ethernet + ARP + IPv4 + UDP slice above the hardware driver without overstating the rest of the stack. TCP, DHCP, and DNS still remain open.

---

## Why RTL8139
RTL8139 is the correct first NIC target for this repo because:

- QEMU supports it directly
- it is old but simple
- it exposes a small, well-understood register surface
- it is a better first hardware target than a modern PCIe NIC with DMA rings and larger descriptor machinery
- it is realistic enough that the PAL and later TCP/IP stack will sit on top of a real device path, not a fake transport

For the first slice, simplicity and determinism matter more than performance.

---

## Expected QEMU Topology
Target QEMU device:

- `-device rtl8139,netdev=n0`

Recommended deterministic first-proof topology:

- use RTL8139 internal loopback for the first strict TX/RX proof
- only after loopback is green, add an external peer topology

Why loopback first:

- it avoids nondeterministic slirp traffic
- it allows a single-VM proof
- it validates both TX and RX through the real device path

External peer topologies can come in the second Ethernet slice:
- QEMU socket netdev pair
- tap/bridge
- host-side frame injector

---

## Current Repo Integration Points
The repo already has the correct structural seams:

### PCI
`src/baremetal/pci.zig`

Use this file for:
- config-space discovery
- BAR discovery
- command register enablement

A network device must be discovered here rather than through an ad hoc second scanner.

### Bare-metal runtime
`src/baremetal_main.zig`

Use this file for:
- startup init order
- exported test/probe symbols
- `resetBaremetalRuntimeForTest()`
- hosted regressions

### ABI
`src/baremetal/abi.zig`

Use this file for:
- Ethernet magic/state constants
- stable struct layout for probe scripts and future PAL use

### PAL
`src/pal/net.zig`

Today this is hosted-only HTTP. That is not sufficient for bare metal.
This file needs a lower-level bare-metal device-facing seam for raw Ethernet frames.

### Style references
Follow the repo?s existing device module patterns:

- `src/baremetal/ata_pio_disk.zig`
- `src/baremetal/ps2_input.zig`

That means:
- deterministic state struct
- `init()`
- `resetForTest()`
- `statePtr()`
- hardware-backed path only under `freestanding + x86_64`
- mock-friendly hosted path for regression tests

---

## Hardware Model: RTL8139 Essentials

### PCI identity
Use standard RTL8139 PCI ID:

- vendor: `0x10EC`
- device: `0x8139`

### BAR usage
The first slice should use the I/O BAR path.

At minimum, PCI command register must enable:
- I/O space
- bus mastering

Enabling memory decode as well is acceptable if the helper remains generic, but the minimum required bits are:
- bit 0: I/O space
- bit 2: bus master

### Core registers
The first slice only needs a compact subset of the RTL8139 register surface.

#### MAC / ID
- `IDR0..IDR5` at `0x00..0x05`
- read MAC address after power-up and reset

#### Transmit
- `TSD0..TSD3` at `0x10, 0x14, 0x18, 0x1C`
- `TSAD0..TSAD3` at `0x20, 0x24, 0x28, 0x2C`

#### Receive
- `RBSTART` at `0x30`
- `CAPR` at `0x38`
- `CBR` at `0x3A`

#### Interrupts
- `IMR` at `0x3C`
- `ISR` at `0x3E`

#### Config / control
- `CR` at `0x37`
- `TCR` at `0x40`
- `RCR` at `0x44`
- `CONFIG1` at `0x52`

### Important control bits
#### `CR`
- `RE` receive enable
- `TE` transmit enable
- `RST` software reset

#### `ISR` / `IMR`
Minimum interesting bits for this slice:
- `ROK` receive OK
- `RER` receive error
- `TOK` transmit OK
- `TER` transmit error
- `RXOVW` receive overflow

#### `TCR`
For first proof:
- default transmit configuration
- optional loopback mode for deterministic single-VM proof

#### `RCR`
For first proof:
- accept broadcast
- accept physical match
- optionally accept all in loopback proof mode
- receive wrap enabled for simple ring handling

---

## First-Slice Initialization Sequence
The init sequence must be explicit and deterministic.

### 1. Discover the device
Scan PCI for:
- vendor `0x10EC`
- device `0x8139`

Capture:
- bus / device / function
- I/O BAR base
- interrupt line if available

### 2. Enable PCI command bits
Enable:
- I/O space
- bus mastering

Do not claim interrupts yet. Polling-first is the correct first slice.

### 3. Power-up the NIC
Write:
- `CONFIG1 = 0x00`

### 4. Software reset
Set `CR.RST`, then poll until clear.

### 5. Read MAC
Read `IDR0..IDR5`.

### 6. Set up RX buffer
Allocate contiguous receive buffer memory.
Recommended first slice:
- `8 KiB + 16 + 1500` bytes

### 7. Set up TX buffers
Allocate 4 transmit buffers, one per descriptor slot.

### 8. Program receive config
Set `RCR` for the minimal first slice:
- physical match
- broadcast
- wrap
- optional loopback-friendly acceptance

### 9. Program transmit config
Set `TCR` to a conservative default.
For the deterministic proof path:
- temporarily enable loopback mode

### 10. Clear interrupts
Write back pending bits in `ISR`.

### 11. Polling-first interrupt posture
Set:
- `IMR = 0`

### 12. Enable TX/RX
Set:
- `CR.RE | CR.TE`

---

## Minimal TX/RX Proof Strategy
Preferred strict proof: internal loopback.

### Success conditions
- TX descriptor completes successfully
- RX ring receives exactly one frame
- received payload matches transmitted payload byte-for-byte
- RX/TX counters both increment
- no duplicate stale frame is emitted on the next poll
- mailbox/probe state exposes the exact final telemetry

---

## Required Driver State Contract
Suggested fields for `BaremetalEthernetState`:
- `magic`
- `api_version`
- `backend`
- `initialized`
- `hardware_backed`
- `pci_bus`
- `pci_device`
- `pci_function`
- `irq_line`
- `io_base`
- `tx_enabled`
- `rx_enabled`
- `loopback_enabled`
- `link_up`
- `mac[6]`
- `tx_packets`
- `rx_packets`
- `tx_errors`
- `rx_errors`
- `rx_overflows`
- `last_tx_len`
- `last_rx_len`
- `last_tx_status`
- `last_rx_status`
- `last_rx_vector`
- `tx_index`
- `rx_consumer_offset`

---

## PAL Integration Seam
`src/pal/net.zig` must expose a lower-level bare-metal frame seam.
Suggested first functions:
- `initDevice()`
- `deviceState()`
- `macAddress()`
- `pollReceive()`
- `sendFrame(frame: []const u8)`

---

## First-Slice Exports from baremetal_main.zig
Recommended first export surface:
- `oc_ethernet_state_ptr()`
- `oc_ethernet_init()`
- `oc_ethernet_reset()`
- `oc_ethernet_poll()`
- `oc_ethernet_mac_byte(index)`
- `oc_ethernet_send_pattern(byte_len, seed)`
- `oc_ethernet_rx_byte(index)`
- `oc_ethernet_rx_len()`

---

## Host Regression Requirements
Minimum hosted regressions:
1. init populates stable state
2. reset clears counters and device posture
3. MAC address export is stable
4. send updates TX telemetry
5. mock receive path updates RX telemetry
6. PAL bare-metal frame functions route through the device state

---

## Strict Success Gates for This Slice
- PCI discovery
- Device init
- TX proof
- RX proof
- PAL seam
- CI/QEMU proof

---

## First-Slice Implementation Order
1. `src/baremetal/rtl8139.zig`
2. PCI discovery hook
3. ABI state contract
4. startup/reset/export integration
5. PAL raw-frame surface
6. hosted regressions
7. QEMU loopback proof
8. CI/release-preview wiring

This is the correct first hardware networking milestone.
