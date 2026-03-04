"use strict";

class OpenClawRpcError extends Error {
  constructor(message, details) {
    super(message);
    this.name = "OpenClawRpcError";
    this.details = details ?? null;
  }
}

class OpenClawClient {
  constructor(options = {}) {
    this.baseUrl = options.baseUrl ?? "http://127.0.0.1:8080";
    this.rpcPath = options.rpcPath ?? "/rpc";
    this.timeoutMs = Number.isFinite(options.timeoutMs) ? options.timeoutMs : 30000;
    this.headers = { ...(options.headers ?? {}) };
  }

  rpcUrl() {
    return `${this.baseUrl.replace(/\/+$/, "")}${this.rpcPath}`;
  }

  async rpc(method, params = {}, id = undefined) {
    if (typeof method !== "string" || method.trim().length === 0) {
      throw new OpenClawRpcError("method must be a non-empty string");
    }

    const requestId = id ?? `rpc-${Date.now()}`;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.timeoutMs);
    const payload = { id: requestId, method, params };

    try {
      const response = await fetch(this.rpcUrl(), {
        method: "POST",
        signal: controller.signal,
        headers: {
          "content-type": "application/json",
          ...this.headers,
        },
        body: JSON.stringify(payload),
      });

      if (!response.ok) {
        throw new OpenClawRpcError(`rpc http error (${response.status})`, {
          status: response.status,
          statusText: response.statusText,
        });
      }

      const frame = await response.json();
      if (frame?.error) {
        throw new OpenClawRpcError(frame.error.message ?? "rpc error", frame.error);
      }
      return frame?.result;
    } catch (err) {
      if (err?.name === "AbortError") {
        throw new OpenClawRpcError(`rpc timeout after ${this.timeoutMs}ms`, {
          timeoutMs: this.timeoutMs,
          method,
        });
      }
      if (err instanceof OpenClawRpcError) throw err;
      throw new OpenClawRpcError("rpc request failed", {
        method,
        cause: String(err?.message ?? err),
      });
    } finally {
      clearTimeout(timer);
    }
  }

  health() {
    return this.rpc("health", {});
  }

  status() {
    return this.rpc("status", {});
  }

  connect(params = {}) {
    return this.rpc("connect", params);
  }

  send(params = {}) {
    return this.rpc("send", params);
  }

  poll(params = {}) {
    return this.rpc("poll", params);
  }

  updatePlan(params = {}) {
    return this.rpc("update.plan", params);
  }

  updateRun(params = {}) {
    return this.rpc("update.run", params);
  }

  updateStatus(params = {}) {
    return this.rpc("update.status", params);
  }
}

module.exports = {
  OpenClawClient,
  OpenClawRpcError,
};
