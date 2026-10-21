#!/usr/bin/env python3
"""Build the teams-record-lite Windows ZIP and its update manifest (Linux or Windows).

Usage:
    python lite/build_lite_zip.py [--base-url URL] [--notes TEXT]

Outputs (lite/dist/):
    teams-record-lite-v<VERSION>.zip
    teams-record-lite-latest.json   {"version","url","sha256","runtime","notes"}

--base-url: where the ZIP will be hosted. Default is the GitHub Release
download URL of tag v<VERSION>. For an internal HTTP server pass its folder
URL, e.g. http://host/teams-record-lite/
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LITE = ROOT / "lite"
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
DIST = LITE / "dist"
ZIP_NAME = f"teams-record-lite-v{VERSION}.zip"
MANIFEST_NAME = "teams-record-lite-latest.json"
RUNTIME_ID = "py3.11.9-embed+frida"
GITHUB_DOWNLOAD = "https://github.com/lisyoen/teams-record/releases/download/v{v}/{name}"

# package path -> repository source (single source of truth; nothing is copied into lite/)
ENTRIES = {
    "install.bat": "lite/install.bat",
    "uninstall.bat": "lite/uninstall.bat",
    "teams-record-lite.bat": "lite/teams-record-lite.bat",
    "README.md": "lite/README.md",
    "AGENT.md": "lite/AGENT.md",
    "setup/lite-install.ps1": "lite/setup/lite-install.ps1",
    "setup/lite-uninstall.ps1": "lite/setup/lite-uninstall.ps1",
    "app/trlite.py": "lite/app/trlite.py",
    "app/merge_archive.py": "viewer/merge_archive.py",
    "app/decrypt_export.js": "publish/work/decrypt_export.js",
    "app/sqlite3.js": "publish/work/sqlite3.js",
    "app/sqlite3-binding.js": "publish/work/sqlite3-binding.js",
    "app/trace.js": "publish/work/trace.js",
    "app/spawn_key.py": "publish/work/spawn_key.py",
}
GENERATED = ("VERSION", "app/VERSION")
FORBIDDEN = re.compile(
    r"(^|/)(node_modules|electron|secrets|data|logs?)(/|$)|\.secret$|\.db(-wal|-shm)?$|\.sqlite", re.I)


def expected_names() -> set:
    return set(ENTRIES) | set(GENERATED)


def check_source(name: str, data: bytes) -> None:
    if FORBIDDEN.search(name):
        raise RuntimeError(f"forbidden package path: {name}")
    if data.startswith(b"SQLite format 3\0"):
        raise RuntimeError(f"database content in package: {name}")
    if name.lower().endswith(".bat"):
        if b"\n" in data.replace(b"\r\n", b""):
            raise RuntimeError(f"{name} must use CRLF line endings")
        data.decode("ascii")  # Korean text belongs in the .ps1 files, never in .bat
    if name.lower().endswith(".ps1") and not data.startswith(b"\xef\xbb\xbf"):
        raise RuntimeError(f"{name} must be UTF-8 with BOM for Windows PowerShell 5.1")


def build(base_url: str | None = None, notes: str = "", dist: Path = DIST) -> tuple[Path, Path]:
    dist.mkdir(parents=True, exist_ok=True)
    zip_path = dist / ZIP_NAME
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, src in ENTRIES.items():
            data = (ROOT / src).read_bytes()
            check_source(name, data)
            zf.writestr(name, data)
        for name in GENERATED:
            zf.writestr(name, VERSION + "\r\n")
    with zipfile.ZipFile(zip_path) as zf:
        if set(zf.namelist()) != expected_names():
            raise RuntimeError("ZIP entries differ from the expected list")
    digest = hashlib.sha256(zip_path.read_bytes()).hexdigest()
    if base_url:
        url = base_url.rstrip("/") + "/" + ZIP_NAME
    else:
        url = GITHUB_DOWNLOAD.format(v=VERSION, name=ZIP_NAME)
    manifest = {"version": VERSION, "url": url, "sha256": digest, "runtime": RUNTIME_ID, "notes": notes}
    manifest_path = dist / MANIFEST_NAME
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return zip_path, manifest_path


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=None)
    ap.add_argument("--notes", default="")
    args = ap.parse_args()
    zip_path, manifest_path = build(args.base_url, args.notes)
    print(zip_path)
    print(manifest_path)
    print(f"{len(expected_names())} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
