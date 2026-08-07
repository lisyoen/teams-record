#!/usr/bin/env python3
"""Upload one tenant archive without exposing its bearer token in argv."""

import argparse
import json
import re
import ssl
import sys
import urllib.request
from pathlib import Path
from urllib.parse import urlparse


USERNAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--server", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--database", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--proxy", default="")
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()

    if not USERNAME_RE.fullmatch(args.username):
        raise SystemExit("invalid username")
    parsed = urlparse(args.server)
    if parsed.scheme != "https" or not parsed.netloc:
        raise SystemExit("server must be an https URL")

    database = Path(args.database)
    token_file = Path(args.token_file)
    if not database.is_file():
        raise SystemExit(f"database not found: {database}")
    token = token_file.read_text(encoding="utf-8").strip()
    if not token:
        raise SystemExit("upload token file is empty")

    body = database.read_bytes()
    request = urllib.request.Request(
        args.server.rstrip("/") + "/api/upload",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/vnd.sqlite3",
            "X-Teams-Record-User": args.username,
            "Content-Length": str(len(body)),
        },
    )
    handlers = [urllib.request.HTTPSHandler(context=ssl.create_default_context())]
    if args.proxy:
        handlers.append(urllib.request.ProxyHandler({"http": args.proxy, "https": args.proxy}))
    opener = urllib.request.build_opener(*handlers)
    with opener.open(request, timeout=args.timeout) as response:
        payload = json.loads(response.read().decode("utf-8"))
    token = ""
    if not payload.get("ok"):
        raise SystemExit("server did not acknowledge the upload")
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"upload failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
