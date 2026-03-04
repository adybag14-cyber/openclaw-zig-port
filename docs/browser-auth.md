# Browser and Auth

## Policy

OpenClaw Zig enforces a Lightpanda-only browser policy.

- accepted: `lightpanda`
- rejected by contract: `playwright`, `puppeteer`

## Login Lifecycle

- `web.login.start`
- `web.login.wait`
- `web.login.complete`
- `web.login.status`

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

## Smoke Validation

```powershell
./scripts/web-login-smoke-check.ps1
```
