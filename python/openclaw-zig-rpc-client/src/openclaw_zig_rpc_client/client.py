from __future__ import annotations

import json
import socket
import time
import urllib.error
import urllib.request
from typing import Any, Dict, Optional


class OpenClawRpcError(RuntimeError):
    def __init__(self, message: str, details: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.details = details or {}


class OpenClawClient:
    def __init__(
        self,
        *,
        base_url: str = "http://127.0.0.1:8080",
        rpc_path: str = "/rpc",
        timeout_seconds: float = 30.0,
        headers: Optional[Dict[str, str]] = None,
    ) -> None:
        self.base_url = base_url
        self.rpc_path = rpc_path
        self.timeout_seconds = timeout_seconds
        self.headers = headers or {}

    def rpc_url(self) -> str:
        return f"{self.base_url.rstrip('/')}{self.rpc_path}"

    def rpc(
        self,
        method: str,
        params: Optional[Dict[str, Any]] = None,
        request_id: Optional[str] = None,
    ) -> Any:
        if not isinstance(method, str) or not method.strip():
            raise OpenClawRpcError("method must be a non-empty string")

        payload = {
            "id": request_id or f"rpc-{int(time.time() * 1000)}",
            "method": method,
            "params": params or {},
        }

        body = json.dumps(payload).encode("utf-8")
        headers = {"content-type": "application/json"}
        headers.update(self.headers)
        req = urllib.request.Request(
            self.rpc_url(),
            data=body,
            headers=headers,
            method="POST",
        )

        try:
            with urllib.request.urlopen(req, timeout=self.timeout_seconds) as response:
                status = getattr(response, "status", 200)
                raw = response.read()
                if status < 200 or status >= 300:
                    raise OpenClawRpcError(
                        f"rpc http error ({status})",
                        {"status": status},
                    )
        except urllib.error.HTTPError as exc:
            raise OpenClawRpcError(
                f"rpc http error ({exc.code})",
                {"status": exc.code, "statusText": str(exc.reason)},
            ) from exc
        except (urllib.error.URLError, TimeoutError, socket.timeout) as exc:
            raise OpenClawRpcError(
                "rpc request failed",
                {"method": method, "cause": str(exc)},
            ) from exc

        try:
            frame = json.loads(raw.decode("utf-8"))
        except Exception as exc:
            raise OpenClawRpcError("rpc response was not valid JSON") from exc

        if isinstance(frame, dict) and frame.get("error"):
            err = frame["error"]
            msg = err.get("message", "rpc error") if isinstance(err, dict) else "rpc error"
            details = err if isinstance(err, dict) else {"error": err}
            raise OpenClawRpcError(msg, details)

        if isinstance(frame, dict):
            return frame.get("result")
        raise OpenClawRpcError("rpc response frame was invalid")

    def health(self) -> Any:
        return self.rpc("health", {})

    def status(self) -> Any:
        return self.rpc("status", {})

    def connect(self, params: Optional[Dict[str, Any]] = None) -> Any:
        return self.rpc("connect", params or {})

    def send(self, params: Optional[Dict[str, Any]] = None) -> Any:
        return self.rpc("send", params or {})

    def poll(self, params: Optional[Dict[str, Any]] = None) -> Any:
        return self.rpc("poll", params or {})

    def update_plan(self, params: Optional[Dict[str, Any]] = None) -> Any:
        return self.rpc("update.plan", params or {})

    def update_run(self, params: Optional[Dict[str, Any]] = None) -> Any:
        return self.rpc("update.run", params or {})

    def update_status(self, params: Optional[Dict[str, Any]] = None) -> Any:
        return self.rpc("update.status", params or {})
