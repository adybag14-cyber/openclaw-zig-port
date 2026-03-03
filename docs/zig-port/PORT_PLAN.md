# Zig Port Plan

## Objective

Port OpenClaw Go runtime behavior from baseline commit `65c974b528e2` into a production Zig runtime with parity-first validation.

## Critical Points

- Preserve wire compatibility for existing RPC envelopes and method names.
- Keep behavior parity before optimization changes.
- Require tests for every vertical slice (`config + handler + integration contract`).
- Block release until parity gates and smoke checks pass.
- Push each completed parity slice to GitHub immediately; release artifacts remain blocked until parity is 100%.
- Keep security, browser bridge, and Telegram flows first-class (no stubs).

## Phases

1. Foundation
- Zig project scaffold, build scripts, lint/test harness, config loader, health endpoint.

2. Protocol + Gateway Core
- RPC envelope codec, registry, dispatcher, HTTP server, graceful shutdown.

3. Runtime + Tooling
- runtime state model, scheduler primitives, tool runtime foundation (`exec`, files, message/session ops).

4. Security + Diagnostics
- guard pipeline, policy checks, doctor/security audit command surface.

5. Browser + Auth + Channels
- browser-bridge contracts (Lightpanda-only runtime; Playwright/Puppeteer explicitly rejected), OAuth/login lifecycle, Telegram channel parity.

6. Memory + Edge
- memory store equivalents, edge method payload handling, wasm/sandbox lifecycle.

7. Validation + Release
- parity diff checks, CP-style gates, cross-platform build matrix, signed artifacts, release cut.

## Done Criteria

- RPC contract parity score: `100%`
- No unimplemented handlers in advertised method set
- Full test suite green
- End-to-end smoke for browser auth and Telegram replies
- Host + Docker smoke/system checks return HTTP 200 for gateway surfaces
- Release artifacts built for target platforms

## Current Progress Snapshot

- Phase 2 complete:
  - JSON-RPC envelope parser/encoder
  - Registry + dispatcher
  - HTTP route implementation (`GET /health`, `POST /rpc`)
  - Graceful shutdown via RPC `shutdown` method
- Phase 3 complete:
  - Runtime session primitives + queue lifecycle
  - Tool runtime actions (`exec.run`, `file.read`, `file.write`)
  - Dispatcher wiring and integration request lifecycle tests
  - Runtime status telemetry (`runtime_queue_depth`, `runtime_sessions`)
