#!/usr/bin/env python3
"""parental-os LAN agent stub (v1). Stdlib only."""

from __future__ import annotations

import argparse
import json
import os
import secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse


def load_or_create_token(path: Path) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        return path.read_text(encoding="utf-8").strip()
    token = secrets.token_urlsafe(32)
    path.write_text(token + "\n", encoding="utf-8")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return token


class AgentHandler(BaseHTTPRequestHandler):
    server_version = "parental-os-agent/0.1"

    def _json(self, code: int, body: dict) -> None:
        data = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _auth_ok(self) -> bool:
        auth = self.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            return False
        got = auth[len("Bearer ") :].strip()
        return secrets.compare_digest(got, self.server.token)  # type: ignore[attr-defined]

    def do_GET(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/health":
            self._json(200, {"status": "ok", "service": "parental-guard-agent"})
            return
        if path == "/v1/status":
            if not self._auth_ok():
                self._json(401, {"error": "unauthorized"})
                return
            self._json(
                200,
                {
                    "service": "parental-guard-agent",
                    "version": "0.1.0-stub",
                    "enforcement": "placeholder",
                    "group": "parental-users",
                },
            )
            return
        if path == "/v1/users":
            if not self._auth_ok():
                self._json(401, {"error": "unauthorized"})
                return
            self._json(501, {"error": "not_implemented", "op": "list_users"})
            return
        self._json(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        path = urlparse(self.path).path
        if path == "/v1/allowances":
            if not self._auth_ok():
                self._json(401, {"error": "unauthorized"})
                return
            self._json(501, {"error": "not_implemented", "op": "set_allowances"})
            return
        self._json(404, {"error": "not_found"})

    def log_message(self, fmt: str, *args) -> None:
        return


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(description="parental-os agent stub")
    p.add_argument("--bind", default=os.environ.get("PARENTAL_OS_AGENT_BIND", "127.0.0.1"))
    p.add_argument("--port", type=int, default=int(os.environ.get("PARENTAL_OS_AGENT_PORT", "7420")))
    p.add_argument(
        "--token-file",
        default=os.environ.get("PARENTAL_OS_TOKEN_FILE", "/etc/parental-os/agent.token"),
    )
    p.add_argument(
        "--state-dir",
        default=os.environ.get("PARENTAL_OS_STATE_DIR", "/var/lib/parental-os"),
    )
    args = p.parse_args(argv)

    token = load_or_create_token(Path(args.token_file))
    Path(args.state_dir).mkdir(parents=True, exist_ok=True)

    httpd = ThreadingHTTPServer((args.bind, args.port), AgentHandler)
    httpd.token = token  # type: ignore[attr-defined]
    print(f"parental-guard-agent listening on {args.bind}:{args.port}", flush=True)
    httpd.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
