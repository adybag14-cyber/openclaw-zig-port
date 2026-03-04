# Telegram Channel

## Channel Methods

- `channels.status`
- `channels.logout`
- `send`
- `chat.send`
- `sessions.send`
- `poll`

## Command Surface

- `/help`, `/start`
- `/model` (`status`, set, reset)
- `/auth`:
  - `providers`
  - `bridge`
  - `start`
  - `status`
  - `wait`
  - `complete`
  - `guest`
  - `cancel`

## Auth Binding Model

- provider + account scoped bindings
- backward-compatible fallback handling
- `--force` support to rotate sessions when required

## Queue Model

- FIFO queue for assistant replies/events
- bounded queue retention (`max_queue_entries` default `4096`)
- one-pass front compaction for drain/trim paths

## Smoke Validation

```powershell
./scripts/telegram-reply-loop-smoke-check.ps1
```
