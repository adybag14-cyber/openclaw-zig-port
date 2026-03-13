# FS5.5 Ethernet/TCP-IP RTL8139 Research

## Scope

This document defines the first strict real-hardware Ethernet slice for the Zig bare-metal track.

Target NIC:

- `RTL8139`
- QEMU-compatible PCI network path on `x86_64`
- freestanding Zig runtime with no hosted network fallback counted toward hardware closure

This is not a generic network abstraction report. It is the concrete first implementation order for getting the bare-metal runtime onto a real NIC path that can later carry ARP, IPv4, UDP, TCP, and higher PAL traffic.

## Why RTL8139 First

`RTL8139` is the correct first strict slice because:

- QEMU exposes it reliably
- the register model is small and deterministic
- it uses I/O BAR access instead of requiring a full MMIO descriptor engine to start
- it is sufficient for strict TX/RX bring-up before broader NIC depth

For this repo, the first network slice must behave like the existing ATA/PS2 hardware modules:

- deterministic state struct
- test-friendly hosted fallback
- freestanding `x86_64` hardware path only where the actual device exists

## Primary Hardware Model

The required device-facing control surface for the first slice is:

- PCI vendor/device discovery:
  - vendor `0x10EC`
  - device `0x8139`
- PCI command register:
  - I/O enable
  - memory decode enable
  - bus mastering enable
- I/O BAR discovery:
  - BAR0 must resolve to an I/O base
- MAC address read from device registers
- software reset through command register
- RX buffer base programming
- TX descriptor base programming
- interrupt status polling

## Register Set For First Slice

The first slice only needs the stable RTL8139 register subset:

- `IDR0..IDR5` `0x00..0x05`: MAC address
- `MAR0..MAR7` `0x08..0x0F`: multicast filter
- `TSD0..TSD3` `0x10..0x1C`: transmit status / trigger
- `TSAD0..TSAD3` `0x20..0x2C`: transmit buffer addresses
- `RBSTART` `0x30`: receive buffer address
- `CR` `0x37`: reset / RX enable / TX enable
- `CAPR` `0x38`: current RX read pointer
- `CBR` `0x3A`: current RX buffer write pointer
- `IMR` `0x3C`: interrupt mask
- `ISR` `0x3E`: interrupt status
- `TCR` `0x40`: transmit config
- `RCR` `0x44`: receive config
- `CONFIG1` `0x52`: power-on / wake state

Required status bits:

- command:
  - `RST = 0x10`
  - `RE = 0x08`
  - `TE = 0x04`
- interrupt status / mask:
  - `RxOK = 0x0001`
  - `RxErr = 0x0002`
  - `TxOK = 0x0004`
  - `TxErr = 0x0008`

## First-Slice Initialization Sequence

The first strict initialization sequence is:

1. Discover RTL8139 over PCI.
2. Enable PCI I/O + memory + bus mastering.
3. Resolve BAR0 as an I/O port base.
4. Power the NIC on through `CONFIG1 = 0x00`.
5. Issue software reset via `CR.RST`.
6. Wait until `CR.RST` clears.
7. Read MAC address from `IDR0..IDR5`.
8. Program `RBSTART` with the static RX ring base.
9. Clear `ISR`.
10. Disable interrupts for the first slice by setting `IMR = 0`.
11. Program a permissive first-slice `RCR` that allows deterministic bring-up.
12. Program a stable `TCR`.
13. Set `CR = RE | TE`.
14. Mark device initialized and export state through the bare-metal ABI.

## TX Strategy For Slice 1

The first slice should use the simplest deterministic TX path:

- four static aligned TX buffers
- one active round-robin slot pointer
- deterministic `sendPattern(byte_len, seed)` export
- copy payload into current TX buffer
- write TX buffer address to `TSADn`
- write payload length to `TSDn`
- poll `ISR` or the active `TSDn` for completion

Success does not require a higher-level protocol yet. The first hardware proof only requires:

- device present
- MAC exposed
- deterministic payload copied into the active TX buffer
- transmit command accepted and completion reflected in device/state telemetry

## RX Strategy For Slice 1

The first slice should include a real RX path, but keep it minimal:

- one static RX buffer of `8192 + 16 + 1500`
- poll `ISR` for `RxOK`
- use `CAPR` / `CBR` to detect receive progress
- parse the RTL8139 packet header:
  - packet status
  - packet length
- copy the first received frame into a small retained snapshot buffer
- advance `CAPR` correctly with alignment

This is enough to prove:

- receive state exists as code
- receive semantics are not stubbed
- the next TCP/IP slice can consume frames from a real device path

## PAL Surface Required For This Slice

The PAL layer must expose a device-facing surface separate from hosted HTTP:

- bare-metal NIC state pointer
- explicit init
- explicit poll
- deterministic test send path
- retained RX-byte readback for proofs

This is the seam later TCP/IP work will consume. TCP/IP should not talk directly to device registers.

## ABI Surface Required For This Slice

The bare-metal ABI needs a dedicated Ethernet state struct with at least:

- magic + API version
- backend identifier
- present / initialized / hardware-backed flags
- PCI address + IRQ line
- I/O base
- MAC address
- link / status snapshot
- TX/RX packet and error counters
- last TX length
- last RX length
- last `ISR` snapshot

The Ethernet ABI should be an exported state, not a checklist note.

## Strict Success Gates For Slice 1

Slice 1 is only complete when all of the following are true:

1. A real Zig module exists for RTL8139, not a stub.
2. PCI discovery for RTL8139 exists in code.
3. The module performs real reset/init against the device I/O base.
4. The MAC address is readable through exported state.
5. TX buffer descriptors are programmed by the driver.
6. A deterministic payload send path exists and updates state telemetry.
7. A real RX buffer and poll/consume path exists in code.
8. The bare-metal ABI exports Ethernet state.
9. PAL exposes the device-facing network seam.
10. Host regressions cover mock/device-state behavior.
11. A strict QEMU proof demonstrates:
   - PCI discovery
   - init success
   - MAC exposure
   - deterministic TX path acceptance

## What Does Not Count

The following do not count toward Ethernet closure:

- hosted `std.http` only
- abstract `sendPacket()` with no device module
- docs-only claims
- CI green without a real NIC path

## TCP/IP Dependency Closure

TCP/IP work starts only after the device slice exposes:

- deterministic RX ingress
- deterministic TX egress
- retained frame snapshots
- PAL network-device seam

Then the next strict order is:

1. Ethernet frame encode/decode helpers
2. ARP request/reply
3. IPv4 header encode/decode
4. UDP send/receive
5. TCP staged handshake
6. TCP payload exchange

## Implementation Order

The first implementation order should be:

1. `src/baremetal/rtl8139.zig`
2. `src/baremetal/pci.zig` RTL8139 discovery helpers
3. `src/baremetal/abi.zig` Ethernet ABI state
4. `src/baremetal_main.zig` import + export surface
5. `src/pal/net.zig` freestanding device seam
6. hosted regressions
7. first QEMU strict proof

## Notes For Later TCP/IP Work

The first Ethernet slice should preserve these later extension points:

- MAC address exposure for ARP sender identity
- retained RX snapshot for frame parser tests
- explicit link / ISR telemetry for network fault diagnosis
- send path that accepts caller-provided payload bytes later, not only seeded patterns

This keeps the first slice real while still bounded enough to land safely.
