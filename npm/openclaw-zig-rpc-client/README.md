# @adybag14-cyber/openclaw-zig-rpc-client

Node.js JSON-RPC client for OpenClaw Zig gateway endpoints.

## Install

```bash
npm install @adybag14-cyber/openclaw-zig-rpc-client
```

GitHub release tarball fallback for the current edge tag:

```bash
npm install "https://github.com/adybag14-cyber/openclaw-zig-port/releases/download/v0.2.0-zig-edge.28/adybag14-cyber-openclaw-zig-rpc-client-0.2.0-zig-edge.28.tgz"
```

## Usage

```js
const { OpenClawClient } = require("@adybag14-cyber/openclaw-zig-rpc-client");

async function main() {
  const client = new OpenClawClient({
    baseUrl: "http://127.0.0.1:8080",
    timeoutMs: 30000,
  });

  const health = await client.health();
  console.log("health:", health);

  const plan = await client.updatePlan({ channel: "stable" });
  console.log("update plan:", plan.selection);

  const run = await client.updateRun({ targetVersion: "edge", dryRun: true });
  console.log("update run:", run.status, run.phase);
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
```

## Core helpers

- `health()`
- `status()`
- `connect(params)`
- `send(params)`
- `poll(params)`
- `updatePlan(params)`
- `updateRun(params)`
- `updateStatus(params)`

Use `client.rpc(method, params)` for any other OpenClaw RPC surface.

