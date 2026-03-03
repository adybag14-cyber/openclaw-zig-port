# Phase Checklist

Release lock: no release tag is allowed until all phases are complete and parity is measured at 100%.

## Phase 1 - Foundation
- [x] Initialize Zig workspace layout (`gateway`, `protocol`, `bridge`, config/runtime slices)
- [x] Add build/test commands (`zig build`, `zig build test`, local syntax-check script)
- [x] Add config parser + env override skeleton
- [x] Add `/health` endpoint contract in dispatcher (`health` RPC route with JSON payload)

## Phase 2 - Protocol + Gateway Core
- [x] Implement JSON-RPC envelope parsing/serialization
- [x] Build method registry and dispatcher
- [x] Implement HTTP RPC route + graceful shutdown
- [x] Add contract tests for error codes and method routing

## Phase 3 - Runtime + Tooling
- [x] Add runtime state/session primitives
- [x] Implement initial tool runtime actions (`exec`, file read/write)
- [x] Add queue/worker scaffolding for async jobs
- [x] Add integration tests for request lifecycle

## Phase 4 - Security + Diagnostics
- [x] Port core guard flow (prompt/tool policy checks)
- [x] Implement `doctor` and `security.audit` base commands
- [x] Add remediation/reporting contract outputs

## Phase 5 - Browser/Auth/Channels
- [ ] Implement web login manager (`start/wait/complete/status`)
- [x] Implement browser completion bridge contract (Lightpanda-only provider policy)
- [ ] Implement Telegram command/reply surface
- [ ] Add smoke coverage for auth + reply loops

## Phase 6 - Memory + Edge
- [ ] Port memory persistence primitives
- [ ] Port edge handler contracts
- [ ] Port wasm runtime/sandbox lifecycle contracts

## Phase 7 - Validation + Release
- [ ] Run full parity diff against Go baseline
- [ ] Run full test matrix and smoke checks
- [ ] Build release binaries + checksums
- [ ] Publish first Zig preview release

## Latest Validation Snapshot
- [x] `zig build`
- [x] `zig build test`
- [x] `scripts/zig-syntax-check.ps1`
- [x] `scripts/zig-codeberg-master-check.ps1` (reports local vs remote master hash)
- [x] `scripts/docker-smoke-check.ps1` (host + Docker HTTP 200 checks on `/health` and `/rpc`)
- [x] Serve smoke: `GET /health` and `POST /rpc` (`shutdown`) both returned HTTP 200
- [x] Serve smoke: `POST /rpc` `file.write`, `file.read`, and `exec.run` returned HTTP 200 with real payloads
- [x] Serve smoke: `POST /rpc` `security.audit` and `doctor` return structured diagnostics payloads
