from __future__ import annotations

import argparse
import json
import sys
from typing import Any, Dict, Optional

from .client import OpenClawClient, OpenClawRpcError


def _parse_params_json(value: Optional[str]) -> Dict[str, Any]:
    if not value:
        return {}
    parsed = json.loads(value)
    if not isinstance(parsed, dict):
        raise ValueError("params-json must decode to an object")
    return parsed


def _add_common_flags(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--base-url", default="http://127.0.0.1:8080")
    parser.add_argument("--rpc-path", default="/rpc")
    parser.add_argument("--timeout-seconds", type=float, default=30.0)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="openclaw-zig-rpc")
    _add_common_flags(parser)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("health")
    sub.add_parser("status")

    rpc = sub.add_parser("rpc")
    rpc.add_argument("method")
    rpc.add_argument("--params-json")
    rpc.add_argument("--id")

    for name in ("connect", "send", "poll", "update-plan", "update-run", "update-status"):
        p = sub.add_parser(name)
        p.add_argument("--params-json")
        p.add_argument("--id")

    return parser


def _run(args: argparse.Namespace) -> Any:
    client = OpenClawClient(
        base_url=args.base_url,
        rpc_path=args.rpc_path,
        timeout_seconds=args.timeout_seconds,
    )

    if args.command == "health":
        return client.health()
    if args.command == "status":
        return client.status()

    params = _parse_params_json(getattr(args, "params_json", None))
    req_id = getattr(args, "id", None)

    if args.command == "rpc":
        return client.rpc(args.method, params, req_id)
    if args.command == "connect":
        return client.connect(params)
    if args.command == "send":
        return client.send(params)
    if args.command == "poll":
        return client.poll(params)
    if args.command == "update-plan":
        return client.update_plan(params)
    if args.command == "update-run":
        return client.update_run(params)
    if args.command == "update-status":
        return client.update_status(params)

    raise ValueError(f"unsupported command: {args.command}")


def main(argv: Optional[list[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        result = _run(args)
    except (OpenClawRpcError, ValueError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
