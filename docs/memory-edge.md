# Memory and Edge

## Memory

Memory layer is implemented in `src/memory/store.zig` and supports:

- append and history retrieval
- persistent storage roundtrip
- stats/count
- session removal
- bounded trim/compact flows

Methods:

- `sessions.history`
- `chat.history`
- `doctor.memory.status`

## Edge Capability Surface

### Wasm

- `edge.wasm.marketplace.list`
- `edge.wasm.install`
- `edge.wasm.execute`
- `edge.wasm.remove`

### Planning/Orchestration

- `edge.router.plan`
- `edge.acceleration.status`
- `edge.swarm.plan`
- `edge.collaboration.plan`

### Multimodal and Voice

- `edge.multimodal.inspect`
- `edge.voice.transcribe`

### Enclave/Mesh/Homomorphic

- `edge.enclave.status`
- `edge.enclave.prove`
- `edge.mesh.status`
- `edge.homomorphic.compute`

### Finetune

- `edge.finetune.run`
- `edge.finetune.status`
- `edge.finetune.job.get`
- `edge.finetune.cancel`
- `edge.finetune.cluster.plan`

### Additional Advanced Contracts

- `edge.identity.trust.status`
- `edge.personality.profile`
- `edge.handoff.plan`
- `edge.marketplace.revenue.preview`
- `edge.alignment.evaluate`
- `edge.quantum.status`

## Notes

- Edge surfaces are stateful and tested for contract behavior.
- Retention paths use compacting bounded lists to avoid unbounded memory growth in long-running runtimes.
