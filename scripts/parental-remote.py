#!/usr/bin/env python3
"""Parental OS Remote LAN Client CLI."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import urllib.error
import urllib.request

DOMAIN_PREFIX = "parental-guard:lan-v1:"


def compute_guardian_hash(password: str) -> str:
    payload = (DOMAIN_PREFIX + password).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def send_request(
    host: str,
    port: int,
    path: str,
    method: str = "GET",
    token: str | None = None,
    data: dict | None = None,
) -> tuple[int, dict]:
    url = f"http://{host}:{port}{path}"
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = json.dumps(data).encode("utf-8") if data else None
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=5) as res:
            return res.status, json.loads(res.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        err_body = e.read().decode("utf-8")
        try:
            return e.code, json.loads(err_body)
        except Exception:
            return e.code, {"error": err_body}
    except Exception as e:
        return 0, {"error": str(e)}


def main() -> int:
    parser = argparse.ArgumentParser(description="Parental OS Remote Client")
    parser.add_argument("--host", default="127.0.0.1", help="Target PC IP or hostname")
    parser.add_argument("--port", type=int, default=7420, help="Agent port (default 7420)")
    parser.add_argument("--password", required=True, help="Guardian master password")
    parser.add_argument("command", choices=["status", "lock", "health"], help="Remote action")
    args = parser.parse_args()

    token = compute_guardian_hash(args.password)

    if args.command == "health":
        code, resp = send_request(args.host, args.port, "/health")
    elif args.command == "status":
        code, resp = send_request(args.host, args.port, "/v1/status", method="GET", token=token)
    elif args.command == "lock":
        code, resp = send_request(args.host, args.port, "/v1/actions/lock", method="POST", token=token)
    else:
        sys.stderr.write(f"Unknown command: {args.command}\n")
        return 1

    print(json.dumps(resp, indent=2))
    return 0 if (200 <= code < 300) else 1


if __name__ == "__main__":
    sys.exit(main())
