# openclaw-zig-rpc-client

Python JSON-RPC client and CLI for OpenClaw Zig gateway endpoints.

## Install

```bash
pip install openclaw-zig-rpc-client
```

Or run directly with `uvx` after publishing:

```bash
uvx --from openclaw-zig-rpc-client openclaw-zig-rpc health --base-url http://127.0.0.1:8080
```

## Python Usage

```python
from openclaw_zig_rpc_client import OpenClawClient

client = OpenClawClient(base_url="http://127.0.0.1:8080", timeout_seconds=30)
health = client.health()
print(health)
```

## CLI Usage

```bash
openclaw-zig-rpc health --base-url http://127.0.0.1:8080
openclaw-zig-rpc rpc update.plan --params-json '{"channel":"edge"}'
openclaw-zig-rpc rpc update.run --params-json '{"targetVersion":"edge","dryRun":true}'
```
