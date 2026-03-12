# FS2 Provider and Channel Matrix

This document is the strict source of truth for FS2 provider/channel completion.

Only directly verified local evidence counts:

- registry and dispatcher implementation
- explicit Zig tests
- explicit smoke scripts
- green `zig-ci` and `docs-pages` on the pushed head

Status legend:

- `PASS`: the listed pass criteria are fully satisfied by current local evidence
- `PARTIAL`: implementation exists, but one or more strict pass criteria are still missing
- `FAIL`: required behavior is currently broken

## Dependency Rules

FS2 depends on already-closed hosted prerequisites:

- FS1 runtime/core consolidation
- FS4 security/trust hardening

FS2 proofs must use the stabilized FS1 and FS4 surfaces for:

- runtime state and queue behavior
- secret/config resolution
- auth posture and deterministic unauthorized telemetry

## Selected Supported Matrix

| Surface | Methods / path | Strict pass criteria | Current evidence | Status | Remaining gap |
| --- | --- | --- | --- | --- | --- |
| ChatGPT browser-session auth | `web.login.start`, `web.login.wait`, `web.login.complete`, `web.login.status` | `web-login-smoke-check.ps1` returns HTTP `200` for all four RPCs, exposes non-empty `loginSessionId` + `code`, and ends in authorized/completed state | `scripts/web-login-smoke-check.ps1`; `src/bridge/web_login.zig` lifecycle tests; registry + RPC docs | `PASS` | none for the auth-only lane |
| Browser completion execution | `browser.request` completion mode | at least one end-to-end completion path returns assistant text through the supported browser bridge path, with deterministic failure telemetry also covered | `scripts/browser-request-success-smoke-check.ps1`; dispatcher tests cover failure telemetry, context injection, request normalization, and bridge failure envelope | `PASS` | none for the browser bridge lane |
| Direct provider OpenAI-compatible path | `browser.request` with `directProvider=true` for `chatgpt|codex|claude` | deterministic auth semantics, deterministic missing-key telemetry, and at least one successful completion proof | dispatcher tests cover auth semantics and missing-key behavior; provider transport honors explicit endpoint override; `scripts/browser-request-direct-provider-success-smoke-check.ps1` proves HTTP `200` completion with assistant text through the direct-provider path | `PASS` | none for the OpenAI-compatible direct-provider lane |
| OpenRouter direct provider path | `browser.request` with `directProvider=true` for `openrouter` | deterministic auth semantics and endpoint telemetry, plus at least one successful completion proof | dispatcher tests; `src/bridge/provider_http.zig` tests; provider endpoint contract implemented | `PARTIAL` | no recorded success-path proof yet |
| OpenCode direct provider path | `browser.request` with `directProvider=true` for `opencode` | deterministic auth semantics and endpoint telemetry, plus at least one successful completion proof | dispatcher tests; `src/bridge/provider_http.zig` tests; provider endpoint contract implemented | `PARTIAL` | no recorded success-path proof yet |
| Telegram webhook receive | `channels.telegram.webhook.receive` | documented request/response shape, routed runtime handling, and strict proof of update ingress | dispatcher tests prove routed dry-run handling | `PARTIAL` | no dedicated ingress smoke yet |
| Telegram bot send | `channels.telegram.bot.send` | documented request/response shape, direct send path, typing/chunking telemetry, and strict proof of outbound delivery contract | dispatcher tests prove missing-token, dry-run, typing, chunking, and config-default behavior | `PARTIAL` | no dedicated delivery smoke yet |
| Telegram command/reply loop | `send`, `poll`, `/auth`, non-command chat reply | `telegram-reply-loop-smoke-check.ps1` returns HTTP `200`, proves `/auth start`, `/auth link`, `/auth complete`, non-command reply, and non-empty queue poll | `scripts/telegram-reply-loop-smoke-check.ps1`; runtime + dispatcher tests | `PASS` | none for the local reply-loop lane |
| Failure telemetry correctness | browser auth/provider failures + telegram bot missing-token path | failures are deterministic, structured, and documented | dispatcher tests cover browser failure envelopes and Telegram bot delivery failures; docs describe behavior | `PASS` | none for the documented failure-contract lane |

## Strict FS2 Closure Status

FS2 is still open.

What is now closed:

- strict matrix is defined in docs
- auth + reply-loop smoke gates exist and can be enforced in CI
- browser/session auth proof is green locally
- Telegram command/reply proof is green locally

What still blocks FS2 closure:

1. OpenRouter direct-provider success proof
2. OpenCode direct-provider success proof
3. Telegram webhook ingress smoke proof
4. Telegram bot-send delivery smoke proof

## Enforced Local Smoke Commands

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\web-login-smoke-check.ps1 -SkipBuild
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\browser-request-success-smoke-check.ps1 -SkipBuild
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\browser-request-direct-provider-success-smoke-check.ps1 -SkipBuild
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\telegram-reply-loop-smoke-check.ps1 -SkipBuild
```
