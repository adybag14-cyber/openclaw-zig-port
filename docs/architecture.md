# Architecture

## Runtime Layers

1. Protocol Layer
- JSON-RPC envelope parsing/encoding
- stable error contract behavior

2. Gateway Layer
- HTTP entrypoint
- request dispatch and error routing
- graceful process shutdown path

3. Dispatcher Layer
- maps `method` -> implementation
- central compatibility and policy enforcement layer
- cross-domain state orchestration

4. Domain Services
- runtime/tool runtime
- security/diagnostics
- browser/auth
- channels (telegram)
- memory
- edge/advanced contracts

5. Runtime Profiles
- OS-hosted profile (`src/main.zig`) with HTTP + JSON-RPC gateway and full feature surface
- freestanding bare-metal profile (`src/baremetal_main.zig`) with exported lifecycle hooks, command/mailbox ABI exports, descriptor/interrupt bootstrap exports, and Multiboot2 header for bootloader/hypervisor integration

## Major Modules

- `src/protocol/envelope.zig`
- `src/gateway/http_server.zig`
- `src/gateway/dispatcher.zig`
- `src/gateway/registry.zig`
- `src/runtime/*`
- `src/security/*`
- `src/channels/telegram_runtime.zig`
- `src/bridge/*`
- `src/memory/store.zig`
- `src/baremetal/abi.zig`
- `src/baremetal/x86_bootstrap.zig`
- `src/baremetal_main.zig`

## State and Lifecycle

- process-global runtime instances are initialized on demand and reset on config changes
- bounded in-memory histories are retained for compat/edge job/event surfaces
- memory store persists history for recall and diagnostics
- auth and telegram state retain provider/account/session bindings

## Browser Policy

- Browser contract handling is intentionally Lightpanda-only in Zig.
- Playwright/Puppeteer are rejected by policy at dispatcher level.
