#!/usr/bin/env python3
"""Build the public, source-only Windows installer ZIP on Linux or Windows."""
from __future__ import annotations

import re
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
DIST = ROOT / "publish" / "dist"
ZIP_PATH = DIST / f"teams-record-v{VERSION}-install.zip"

WHITELIST = (
    "install.bat", "README.md", "VERSION",
    "publish/README.md", "publish/install.bat", "publish/install.ps1",
    "publish/setup.bat", "publish/setup.ps1", "publish/capture-key.bat",
    "publish/uninstall.bat", "publish/uninstall.ps1",
    "publish/work/decrypt_export.js", "publish/work/sqlite3.js",
    "publish/work/sqlite3-binding.js", "publish/work/trace.js",
    "publish/work/spawn_key.py", "publish/work/hook_napi.py",
    "viewer/server.py", "viewer/merge_archive.py", "viewer/refresh_archive.bat",
    "viewer/start_viewer.bat", "viewer/teams-viewer.bat", "viewer/update-check.bat",
    "electron/main.js", "electron/package.json", "electron/package-lock.json",
    "electron/teams-viewer-electron.bat", "electron/assets/icon.ico",
)
FORBIDDEN = re.compile(
    r"(^|/)(node_modules|secrets|keys|thumbs|logs?|data|dumps|attachments|pictures|prd|original-data|company-data)(/|$)"
    r"|(^|/)dbkey\.secret$|\.secret$|\.db(?:-wal|-shm)?$|\.sqlite|\.(key|sqlcipher-key|b64|store)$"
    r"|(^|/)\.env(?:\.|$)|(token|cookie|session)", re.I,
)
CREDENTIAL = re.compile(
    rb"authorization\s*[:=]\s*bearer\s+[A-Za-z0-9._-]{16,}|-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    re.I,
)

def validate(name: str, data: bytes) -> None:
    normalized = name.replace("\\", "/")
    if FORBIDDEN.search(normalized):
        raise RuntimeError(f"forbidden package path: {name}")
    if data.startswith(b"SQLite format 3\0") or CREDENTIAL.search(data):
        raise RuntimeError(f"forbidden package content: {name}")

def main() -> int:
    tracked = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files", "-z"], check=True, capture_output=True
    ).stdout.decode().split("\0")
    for name in filter(None, tracked):
        path = ROOT / name
        if path.is_file():
            validate(name, path.read_bytes())
    for name in WHITELIST:
        if not (ROOT / name).is_file():
            raise FileNotFoundError(f"required package file missing: {name}")
    DIST.mkdir(parents=True, exist_ok=True)
    if ZIP_PATH.exists():
        ZIP_PATH.unlink()
    with zipfile.ZipFile(ZIP_PATH, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in WHITELIST:
            data = (ROOT / name).read_bytes()
            validate(name, data)
            archive.writestr(name, data)
    with zipfile.ZipFile(ZIP_PATH) as archive:
        actual = tuple(info.filename for info in archive.infolist())
        if set(actual) != set(WHITELIST):
            raise RuntimeError("ZIP entries differ from the whitelist")
        for info in archive.infolist():
            validate(info.filename, archive.read(info))
    print(ZIP_PATH)
    print(f"{len(WHITELIST)} whitelisted files")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
