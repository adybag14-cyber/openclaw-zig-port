# Browser and Auth

## Policy

OpenClaw Zig enforces a Lightpanda-only browser policy.

- accepted: `lightpanda`
- rejected by contract: `playwright`, `puppeteer`

## Login Lifecycle

- `web.login.start` (create pending provider session)
- `web.login.wait` (poll pending/completed state)
- `web.login.complete` (finalize code/guest completion token)
- `web.login.status` (inspect active session state)

OAuth alias methods are also supported:

- `auth.oauth.providers`
- `auth.oauth.start`
- `auth.oauth.wait`
- `auth.oauth.complete`
- `auth.oauth.logout`
- `auth.oauth.import`

## Provider Behavior

Supported provider surface includes:

- `chatgpt`, `codex`, `claude`, `gemini`, `openrouter`, `opencode`
- guest-capable browser-session flows:
  - `qwen`
  - `zai` (`glm-5`)
  - `inception` (`mercury-2`)
- additional aliases:
  - `minimax`, `kimi`, `zhipuai`

## Guest Flow Support

For guest-capable providers, runtime contracts expose guest bypass metadata and compatibility commands so mobile/browser-based flows can complete without API keys where provider policies allow.

## `browser.request` Completion Execution

`browser.request` supports both auth-readiness probing and direct completion execution.

- Auth-readiness/probe mode:
  - call without completion payload
  - returns provider/model/auth metadata, endpoint probe telemetry, and `bridgeCompletion.requested=false`
- Completion execution mode:
  - enabled when `messages` is present, or prompt fallback keys are present (`prompt`, `message`, `text`)
  - request is forwarded to Lightpanda bridge `/v1/chat/completions`

Supported input aliases include:

- provider/model:
  - `provider`, `targetProvider`
  - `model`, `targetModel`
- endpoint/timeouts:
  - `endpoint`, `bridgeEndpoint`, `lightpandaEndpoint`
  - `requestTimeoutMs`, `timeoutMs`
- completion payload:
  - `messages`
  - fallback prompt keys: `prompt`, `message`, `text`
  - `temperature`
  - `max_tokens`, `maxTokens`
  - `loginSessionId`, `login_session_id`
  - `apiKey`, `api_key`

## Response Semantics

- Top-level probe telemetry is always included (`probe.ok`, `probe.statusCode`, `probe.url`, latency, error).
- When completion is not requested:
  - top-level `ok=true`, `status="completed"` for successful auth-readiness contract resolution
  - `bridgeCompletion.requested=false`
- When completion is requested:
  - top-level `ok` mirrors execution success/failure
  - top-level `status` becomes `"completed"` on success or `"failed"` on execution failure
  - `message` contains bridge failure text when execution fails

`bridgeCompletion` telemetry fields:

- `requested`
- `ok`
- `provider`
- `endpoint`
- `requestUrl`
- `requestTimeoutMs`
- `statusCode`
- `model`
- `assistantText`
- `latencyMs`
- `error`

## Smoke Validation

```powershell
./scripts/web-login-smoke-check.ps1
```
