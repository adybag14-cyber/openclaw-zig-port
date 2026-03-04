export type RpcParams = Record<string, unknown>;

export interface OpenClawClientOptions {
  baseUrl?: string;
  rpcPath?: string;
  timeoutMs?: number;
  headers?: Record<string, string>;
}

export class OpenClawRpcError extends Error {
  details: unknown;
  constructor(message: string, details?: unknown);
}

export class OpenClawClient {
  constructor(options?: OpenClawClientOptions);

  rpcUrl(): string;
  rpc<T = unknown>(method: string, params?: RpcParams, id?: string): Promise<T>;

  health<T = unknown>(): Promise<T>;
  status<T = unknown>(): Promise<T>;
  connect<T = unknown>(params?: RpcParams): Promise<T>;
  send<T = unknown>(params?: RpcParams): Promise<T>;
  poll<T = unknown>(params?: RpcParams): Promise<T>;
  updatePlan<T = unknown>(params?: RpcParams): Promise<T>;
  updateRun<T = unknown>(params?: RpcParams): Promise<T>;
  updateStatus<T = unknown>(params?: RpcParams): Promise<T>;
}
