#!/usr/bin/env python3
"""teams-record-lite CLI.

Refreshes a cumulative plaintext archive of the local Knox Teams message DB
without the viewer. Designed to be called by external agents: stdout is one
UTF-8 JSON document, progress goes to stderr, no prompts or popups.

Layout (install root, default %LOCALAPPDATA%\\teams-record-lite):
    app\\       program files (this script, merge_archive.py, decrypt_export.js, ...)
    runtime\\   embeddable Python + frida
    work\\      dbkey.secret, transient snapshots
    data\\      teams-archive.db
    logs\\      refresh.log, update.log
    config.json, state.json
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("TRLITE_ROOT") or APP_DIR.parent)
WORK = ROOT / "work"
DATA = ROOT / "data"
LOGS = ROOT / "logs"
CONFIG_PATH = ROOT / "config.json"
STATE_PATH = ROOT / "state.json"
ARCHIVE = DATA / "teams-archive.db"
KEY_PATH = WORK / "dbkey.secret"
LEGACY_KEY = Path(os.path.expanduser("~")) / "teams-record-work" / "dbkey.secret"
# 1.3.1: every captured key is kept outside the install folder (survives updates and reinstalls),
# protected with Windows DPAPI for the current user. Refresh tries these before asking for a new capture.
KEYSTORE = Path(os.environ.get("TRLITE_KEYSTORE") or Path(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~")) / "teams-record-keys" / "keys.json")
KEYSTORE_MAX = 10

DEFAULT_UPDATE_URL = (
    "https://github.com/lisyoen/teams-record/releases/latest/download/"
    "teams-record-lite-latest.json"
)
DEFAULT_CONFIG = {
    "update_url": DEFAULT_UPDATE_URL,
    "auto_update": True,
    "update_interval_hours": 24,
    "knox_root": "",
    "archive_path": "",
}

EXIT_OK, EXIT_OTHER, EXIT_NOT_INSTALLED, EXIT_NO_KEY = 0, 1, 2, 3
EXIT_REFRESH_FAILED, EXIT_TIMEOUT, EXIT_UPDATE_FAILED = 4, 5, 6


class LiteError(Exception):
    def __init__(self, code: int, message: str, detail: str = ""):
        super().__init__(message)
        self.code = code
        self.message = message
        self.detail = detail


# ----------------------------------------------------------------- utilities
def now_iso() -> str:
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def append_log(name: str, msg: str) -> None:
    try:
        LOGS.mkdir(parents=True, exist_ok=True)
        with open(LOGS / name, "a", encoding="utf-8") as f:
            f.write(f"{now_iso()} {msg}\n")
    except OSError:
        pass


def read_version(base: Path = APP_DIR) -> str:
    try:
        return (base / "VERSION").read_text(encoding="utf-8").strip()
    except OSError:
        return "0.0.0"


def version_tuple(value: str) -> tuple:
    parts = []
    for p in re.split(r"[.\-+]", str(value).strip().lstrip("vV")):
        parts.append(int(p) if p.isdigit() else 0)
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def load_json(path: Path, default: dict) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
        if isinstance(data, dict):
            merged = dict(default)
            merged.update(data)
            return merged
    except (OSError, ValueError):
        pass
    return dict(default)


def save_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(tmp, path)


def load_config() -> dict:
    return load_json(CONFIG_PATH, DEFAULT_CONFIG)


def load_state() -> dict:
    return load_json(STATE_PATH, {})


def update_state(**kwargs) -> None:
    state = load_state()
    state.update(kwargs)
    save_json(STATE_PATH, state)


@contextlib.contextmanager
def file_lock(path: Path, timeout: float):
    """Exclusive inter-process lock; waits up to timeout seconds."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fh = open(path, "a+b")
    deadline = time.monotonic() + timeout
    try:
        while True:
            try:
                if os.name == "nt":
                    import msvcrt
                    fh.seek(0)
                    msvcrt.locking(fh.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise LiteError(EXIT_TIMEOUT, "다른 갱신 작업이 끝나지 않아 대기 시간을 초과했습니다.")
                time.sleep(0.5)
        yield
    finally:
        try:
            if os.name == "nt":
                import msvcrt
                fh.seek(0)
                msvcrt.locking(fh.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        fh.close()


# --------------------------------------------------------------- Knox Teams
def find_knox_root(config: dict) -> Path:
    candidates = [os.environ.get("KNOX_ROOT", ""), config.get("knox_root", ""), r"C:\mySingle\KnoxTeams"]
    for c in candidates:
        if c and (Path(c) / "KnoxTeams.exe").is_file():
            return Path(c)
    found = shutil.which("KnoxTeams.exe")
    if found:
        return Path(found).parent
    raise LiteError(EXIT_NOT_INSTALLED, "Knox Teams 설치 위치를 찾지 못했습니다. config.json 의 knox_root 를 지정해 주세요.")


def find_live_db() -> Path:
    prd = Path(os.environ.get("APPDATA", "")) / "KnoxTeams" / "prd"
    if not prd.is_dir():
        raise LiteError(EXIT_REFRESH_FAILED, f"Knox Teams 데이터 폴더가 없습니다: {prd}")
    dbs = [p for p in prd.glob("*.db") if p.is_file()]
    if not dbs:
        raise LiteError(EXIT_REFRESH_FAILED, f"Knox Teams 메시지 DB 를 찾지 못했습니다: {prd}")
    dbs.sort(key=lambda p: (0 if re.fullmatch(r"[0-9a-fA-F]{64}", p.stem) else 1, -p.stat().st_size))
    return dbs[0]


def archive_file() -> Path:
    """Archive DB; config archive_path lets the CLI share the Teams Viewer archive."""
    custom = str(load_config().get("archive_path") or "").strip()
    return Path(custom) if custom else ARCHIVE


def runtime_python() -> str:
    exe = ROOT / "runtime" / "python" / "python.exe"
    return str(exe) if exe.is_file() else sys.executable


# ------------------------------------------------------------------ key store
def _dpapi(data: bytes, protect: bool) -> bytes:
    if os.name != "nt":
        return data
    import ctypes
    from ctypes import wintypes

    class BLOB(ctypes.Structure):
        _fields_ = [("cbData", wintypes.DWORD), ("pbData", ctypes.POINTER(ctypes.c_char))]
    buf = ctypes.create_string_buffer(data, len(data))
    src, dst = BLOB(len(data), ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))), BLOB()
    fn = ctypes.windll.crypt32.CryptProtectData if protect else ctypes.windll.crypt32.CryptUnprotectData
    ok = fn(ctypes.byref(src), None, None, None, None, 0x1, ctypes.byref(dst))   # CRYPTPROTECT_UI_FORBIDDEN
    if not ok:
        raise OSError("DPAPI failed")
    try:
        return ctypes.string_at(dst.pbData, dst.cbData)
    finally:
        ctypes.windll.kernel32.LocalFree(dst.pbData)


def _load_keystore() -> list[dict]:
    try:
        return [x for x in json.loads(KEYSTORE.read_text(encoding="utf-8")).get("keys", []) if isinstance(x, dict) and x.get("data")]
    except (OSError, ValueError):
        return []


def _known_entries() -> list[tuple[str, dict]]:
    import base64
    out, seen = [], set()
    for item in _load_keystore():
        try:
            key = _dpapi(base64.b64decode(item["data"]), protect=False).decode("utf-8").strip()
        except (OSError, ValueError, UnicodeDecodeError):
            continue
        if key and key not in seen:
            seen.add(key); out.append((key, item))
    return out


def known_keys() -> list[str]:
    """Captured keys, newest first."""
    return [k for k, _ in _known_entries()]


def remember_key(key: str, source: str) -> None:
    """Put key first in the store (dedup, newest first, at most KEYSTORE_MAX)."""
    import base64
    key = key.strip()
    if not key:
        return
    stamp = now_iso()
    entries = [{"key": key, "saved_at": stamp, "source": source}]
    for k, item in _known_entries():
        if k != key and len(entries) < KEYSTORE_MAX:
            entries.append({"key": k, "saved_at": item.get("saved_at", stamp), "source": item.get("source", "")})
    out = [{"data": base64.b64encode(_dpapi(e["key"].encode("utf-8"), protect=True)).decode(),
            "saved_at": e["saved_at"], "source": e["source"]} for e in entries]
    KEYSTORE.parent.mkdir(parents=True, exist_ok=True)
    tmp = KEYSTORE.with_suffix(".tmp")
    tmp.write_text(json.dumps({"version": 1, "keys": out}, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(KEYSTORE)


def current_key() -> str:
    try:
        return KEY_PATH.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def ensure_key() -> None:
    have = KEY_PATH.is_file() and KEY_PATH.read_text(encoding="utf-8").strip()
    if LEGACY_KEY.is_file() and (not have or LEGACY_KEY.stat().st_mtime > KEY_PATH.stat().st_mtime):
        # the Teams Viewer installation recaptured its key; follow it
        WORK.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(LEGACY_KEY, KEY_PATH)
        log("existing dbkey.secret reused")
        return
    if have:
        with contextlib.suppress(OSError):
            if KEY_PATH.read_text(encoding="utf-8").strip() not in known_keys():
                remember_key(KEY_PATH.read_text(encoding="utf-8"), "existing")
        return
    stored = known_keys()
    if stored:
        WORK.mkdir(parents=True, exist_ok=True)
        KEY_PATH.write_text(stored[0], encoding="utf-8")
        log("restored dbkey.secret from key store")
        return
    raise LiteError(EXIT_NO_KEY, "DB 키(dbkey.secret)가 없습니다. 'teams-record-lite capture-key' 를 실행해 주세요.")


# ------------------------------------------------------------------ refresh
MERGE_TOTAL = re.compile(r"ARCHIVE_TOTAL TB_KtMessage=(\d+) TB_KmMessage=(\d+) last_merge=(.+)")
MERGE_CHANGE = re.compile(r"^\s*\+(-?\d+)\s+(\S+)\s+(\d+) -> (\d+)")


def parse_merge_output(text: str) -> dict:
    result = {"changed": {}, "totals": {}, "last_merge": None, "schema_added": {}}
    for line in text.splitlines():
        m = MERGE_TOTAL.search(line)
        if m:
            result["totals"] = {"TB_KtMessage": int(m.group(1)), "TB_KmMessage": int(m.group(2))}
            result["last_merge"] = m.group(3).strip()
            continue
        m = MERGE_CHANGE.match(line)
        if m:
            result["changed"][m.group(2)] = int(m.group(1))
            continue
        if line.strip().startswith("SCHEMA_ADD"):
            parts = line.split()
            if len(parts) >= 3:
                result["schema_added"][parts[1]] = parts[2].split(",")
    return result


def run_step(cmd: list, env: dict, timeout: float, label: str) -> str:
    try:
        proc = subprocess.run(cmd, env=env, capture_output=True, timeout=max(timeout, 1),
                              cwd=str(WORK), creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    except subprocess.TimeoutExpired:
        raise LiteError(EXIT_TIMEOUT, f"{label} 단계가 시간 안에 끝나지 않았습니다.")
    out = (proc.stdout or b"").decode("utf-8", "replace") + (proc.stderr or b"").decode("utf-8", "replace")
    append_log("refresh.log", f"[{label}] rc={proc.returncode}\n{out.strip()}")
    if proc.returncode != 0:
        raise LiteError(EXIT_REFRESH_FAILED, f"{label} 단계가 실패했습니다(exit {proc.returncode}).", out[-2000:])
    return out


def do_refresh(timeout: float) -> dict:
    config = load_config()
    start = time.monotonic()
    with file_lock(WORK / "refresh.lock", timeout):
        knox = find_knox_root(config)
        ensure_key()
        live = find_live_db()
        archive = archive_file()
        WORK.mkdir(parents=True, exist_ok=True)
        archive.parent.mkdir(parents=True, exist_ok=True)
        out_dir = WORK / "out"
        try:
            env = dict(os.environ)
            env.update({
                "ELECTRON_RUN_AS_NODE": "1",
                "TEAMS_DB_DIR": str(out_dir),
                "TEAMS_RECORD_WORK": str(WORK),
                "TEAMS_RECORD_SQLITE_JS": str(APP_DIR / "sqlite3.js"),
                "KNOX_ROOT": str(knox),
            })
            # 1.3.1: a failed decrypt is usually a snapshot taken while Knox Teams was writing, not a new key.
            # Retry with a fresh snapshot, then try every key captured before, before asking for a capture.
            original = current_key()
            candidates = [original, original] + [k for k in known_keys() if k != original]
            if LEGACY_KEY.is_file():
                with contextlib.suppress(OSError):
                    legacy = LEGACY_KEY.read_text(encoding="utf-8").strip()
                    if legacy and legacy not in candidates:
                        candidates.append(legacy)
            decrypted = out_dir / "teams-decrypted.db"
            out, used = "", None
            for attempt, key in enumerate(candidates, 1):
                if not key:
                    continue
                remaining = timeout - (time.monotonic() - start)
                if remaining < 15:
                    break
                if key != current_key():
                    KEY_PATH.write_text(key, encoding="utf-8")
                log(f"[1/3] snapshot live DB (attempt {attempt}/{len(candidates)})")
                for suffix in ("", "-wal", "-shm"):
                    src = Path(str(live) + suffix)
                    dst = WORK / ("snap.db" + suffix)
                    if src.is_file():
                        shutil.copyfile(src, dst)
                    elif dst.exists():
                        dst.unlink()
                shutil.rmtree(out_dir, ignore_errors=True)
                out_dir.mkdir(parents=True, exist_ok=True)
                log("[2/3] decrypt snapshot")
                out = run_step([str(knox / "KnoxTeams.exe"), str(APP_DIR / "decrypt_export.js")], env, remaining, "decrypt")
                if "EXPORT_OK" in out and decrypted.is_file():
                    used = key
                    break
                log("decrypt failed: " + out.strip().splitlines()[0][:200] if out.strip() else "decrypt failed")
                if attempt == 1:
                    time.sleep(2)
            if used is None:
                if original:
                    KEY_PATH.write_text(original, encoding="utf-8")
                tried = len({k for k in candidates if k})
                hint = (f"저장된 DB 키 {tried}개로 모두 복호화하지 못했습니다. Knox Teams 의 DB 키가 바뀐 것으로 보입니다. "
                        "'teams-record-lite capture-key' 로 다시 캡처해 주세요.")
                raise LiteError(EXIT_REFRESH_FAILED, "복호화에 실패했습니다. " + hint, out[-2000:])
            if used != original:
                log("switched to a previously captured key")
            remember_key(used, "refresh")

            log("[3/3] merge into archive")
            remaining = timeout - (time.monotonic() - start)
            env2 = dict(os.environ, PYTHONUTF8="1")
            out = run_step([runtime_python(), str(APP_DIR / "merge_archive.py"), str(decrypted), str(archive)],
                           env2, remaining, "merge")
            if "MERGE_OK" not in out:
                raise LiteError(EXIT_REFRESH_FAILED, "아카이브 병합 결과를 확인하지 못했습니다.", out[-2000:])
            merged = parse_merge_output(out)
        finally:
            for name in ("snap.db", "snap.db-wal", "snap.db-shm"):
                with contextlib.suppress(OSError):
                    (WORK / name).unlink()
            shutil.rmtree(out_dir, ignore_errors=True)

    at = now_iso()
    update_state(last_refresh=at, last_refresh_ok=True)
    return {
        "ok": True,
        "at": at,
        "changed": merged["changed"],
        "totals": merged["totals"],
        "last_merge": merged["last_merge"],
        "schema_added": merged["schema_added"],
        "archive_path": str(archive),
        "error_code": EXIT_OK,
        "message": "대화 내용을 갱신했습니다.",
    }


# ------------------------------------------------------------------- status
def archive_summary() -> dict:
    archive = archive_file()
    info = {"archive_path": str(archive), "exists": archive.is_file()}
    if not archive.is_file():
        return info
    info["size_bytes"] = archive.stat().st_size
    uri = "file:" + urllib.request.pathname2url(str(archive)) + "?mode=ro"
    try:
        con = sqlite3.connect(uri, uri=True)
        try:
            tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            totals = {}
            for t in ("TB_KtMessage", "TB_KmMessage"):
                if t in tables:
                    totals[t] = con.execute(f'SELECT count(*) FROM "{t}"').fetchone()[0]
            info["totals"] = totals
            if "_archive_meta" in tables:
                row = con.execute("SELECT v FROM _archive_meta WHERE k='last_merge'").fetchone()
                info["last_merge"] = row[0] if row else None
        finally:
            con.close()
    except sqlite3.Error as e:
        info["error"] = str(e)
    return info


def do_status() -> dict:
    state = load_state()
    config = load_config()
    try:
        knox = str(find_knox_root(config))
    except LiteError:
        knox = None
    return {
        "ok": True,
        "version": read_version(),
        "install_root": str(ROOT),
        "knox_root": knox,
        "key_present": KEY_PATH.is_file(),
        "archive": archive_summary(),
        "last_refresh": state.get("last_refresh"),
        "last_update_check": state.get("last_update_check"),
        "staged_update": state.get("staged_update"),
        "auto_update": bool(config.get("auto_update", True)),
        "update_url": config.get("update_url"),
        "error_code": EXIT_OK,
        "message": "정상",
    }


# ------------------------------------------------------------------- update
def http_get(url: str, timeout: float = 60) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "teams-record-lite"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # honours system/env proxies
        return resp.read()


def fetch_manifest(url: str) -> dict:
    data = json.loads(http_get(url).decode("utf-8-sig"))
    if not isinstance(data, dict) or not data.get("version") or not data.get("url") or not data.get("sha256"):
        raise LiteError(EXIT_UPDATE_FAILED, "업데이트 매니페스트 형식이 올바르지 않습니다.")
    data["url"] = urllib.parse.urljoin(url, data["url"])
    return data


def stage_update(manifest: dict, payload: bytes) -> Path:
    digest = hashlib.sha256(payload).hexdigest()
    if digest.lower() != str(manifest["sha256"]).lower():
        raise LiteError(EXIT_UPDATE_FAILED, "내려받은 업데이트 파일의 SHA256 이 일치하지 않습니다.")
    staged = ROOT / "app.new"
    shutil.rmtree(staged, ignore_errors=True)
    with tempfile.TemporaryDirectory(dir=str(ROOT)) as tmp:
        zpath = Path(tmp) / "update.zip"
        zpath.write_bytes(payload)
        with zipfile.ZipFile(zpath) as zf:
            names = [n for n in zf.namelist() if n.startswith("app/") and not n.endswith("/")]
            if "app/trlite.py" not in names:
                raise LiteError(EXIT_UPDATE_FAILED, "업데이트 패키지에 app/trlite.py 가 없습니다.")
            for n in names:
                rel = Path(n).relative_to("app")
                if ".." in rel.parts or rel.is_absolute():
                    raise LiteError(EXIT_UPDATE_FAILED, f"잘못된 패키지 경로: {n}")
                dest = Path(tmp) / "app.new" / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(zf.read(n))
        if read_version(Path(tmp) / "app.new") != manifest["version"]:
            raise LiteError(EXIT_UPDATE_FAILED, "업데이트 패키지 버전이 매니페스트와 다릅니다.")
        shutil.move(str(Path(tmp) / "app.new"), str(staged))
    return staged


def check_update(force: bool, check_only: bool) -> dict:
    config = load_config()
    state = load_state()
    current = read_version()
    result = {"checked": False, "current": current, "latest": None, "staged": False,
              "runtime_update_required": False}
    if not force:
        if not config.get("auto_update", True):
            result["skipped"] = "auto_update disabled"
            return result
        last = state.get("last_update_check_epoch", 0) or 0
        interval = float(config.get("update_interval_hours", 24)) * 3600
        if time.time() - float(last) < interval:
            result["skipped"] = "checked recently"
            return result
    url = config.get("update_url") or DEFAULT_UPDATE_URL
    update_state(last_update_check=now_iso(), last_update_check_epoch=time.time())
    manifest = fetch_manifest(url)
    result.update(checked=True, latest=manifest["version"], notes=manifest.get("notes", ""))
    installed_runtime = state.get("runtime") or ""
    if manifest.get("runtime") and installed_runtime and manifest["runtime"] != installed_runtime:
        result["runtime_update_required"] = True
    if version_tuple(manifest["version"]) <= version_tuple(current):
        append_log("update.log", f"up to date current={current} latest={manifest['version']}")
        return result
    if check_only:
        result["available"] = True
        return result
    payload = http_get(manifest["url"], timeout=300)
    stage_update(manifest, payload)
    update_state(staged_update=manifest["version"])
    append_log("update.log", f"staged {manifest['version']} (current {current})")
    result["staged"] = True
    return result


def rollback() -> dict:
    old = ROOT / "app.old"
    if not old.is_dir():
        raise LiteError(EXIT_UPDATE_FAILED, "되돌릴 이전 버전(app.old)이 없습니다.")
    marker = ROOT / "rollback.request"
    marker.write_text(now_iso(), encoding="utf-8")
    append_log("update.log", "rollback requested")
    return {"ok": True, "error_code": EXIT_OK, "message": "다음 실행 시 이전 버전으로 되돌립니다.",
            "previous_version": read_version(old)}


# -------------------------------------------------------------- capture key
KEY_RE = re.compile(r"PRAGMA\s+key\s*=\s*'([^']+)'", re.I)


def kill_knox() -> bool:
    if os.name != "nt":
        return False
    proc = subprocess.run(["taskkill", "/IM", "KnoxTeams.exe", "/F"], capture_output=True,
                          creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    return proc.returncode == 0


def start_knox(knox: Path) -> None:
    """1.3.1: start Knox Teams through Explorer, the same way as a double-click, so it runs in the normal
    desktop context (visible window, usual auto sign-in) instead of under a background agent's process tree."""
    if os.name != "nt":
        return
    exe = str(knox / "KnoxTeams.exe")
    try:
        subprocess.Popen(["explorer.exe", exe], close_fds=True)
        return
    except OSError as exc:
        log(f"explorer start failed ({exc}); starting directly")
    flags = getattr(subprocess, "DETACHED_PROCESS", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    subprocess.Popen([exe], cwd=str(knox), creationflags=flags, close_fds=True)


def do_capture_key(timeout: float) -> dict:
    config = load_config()
    knox = find_knox_root(config)
    WORK.mkdir(parents=True, exist_ok=True)
    log_path = WORK / "key_spawn.log"
    killed = False
    try:
        log("stopping Knox Teams for key capture")
        killed = kill_knox()
        time.sleep(2)
        env = dict(os.environ, TEAMS_RECORD_WORK=str(WORK), KNOX_ROOT=str(knox), PYTHONUTF8="1")
        try:
            subprocess.run([runtime_python(), str(APP_DIR / "spawn_key.py")], env=env, cwd=str(WORK),
                           timeout=max(timeout, 30), capture_output=True,
                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
        except subprocess.TimeoutExpired:
            raise LiteError(EXIT_TIMEOUT, "키 캡처가 시간 안에 끝나지 않았습니다.")
        text = log_path.read_text(encoding="utf-8", errors="ignore") if log_path.exists() else ""
        found = KEY_RE.findall(text)
        if not found:
            raise LiteError(EXIT_NO_KEY, "DB 키를 캡처하지 못했습니다. Knox Teams 로그인 상태를 확인해 주세요.",
                            text[-1500:])
        KEY_PATH.write_text(found[-1], encoding="utf-8")
        remember_key(found[-1], "capture")
    finally:
        # the spawned instance is attached to frida; restart a clean one either way
        kill_knox()
        time.sleep(1)
        start_knox(knox)
        with contextlib.suppress(OSError):
            log_path.unlink()
    return {"ok": True, "at": now_iso(), "key_path": str(KEY_PATH), "knox_restarted": os.name == "nt",
            "knox_was_running": killed, "error_code": EXIT_OK, "message": "DB 키를 캡처했습니다."}


# --------------------------------------------------------------------- main
def emit(payload: dict) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    sys.stdout.flush()


def error_payload(err: LiteError) -> dict:
    return {"ok": False, "at": now_iso(), "error_code": err.code, "message": err.message,
            "detail": err.detail or None}


def main(argv=None) -> int:
    with contextlib.suppress(Exception):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(prog="teams-record-lite", description="Knox Teams archive refresh CLI")
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("refresh", help="refresh the archive DB")
    p.add_argument("--timeout", type=float, default=180)
    p.add_argument("--no-update", action="store_true", help="skip the periodic update check")
    sub.add_parser("status", help="show installation and archive status")
    sub.add_parser("version", help="print version")
    p = sub.add_parser("update", help="check for and stage a new version")
    p.add_argument("--check", action="store_true", help="only check, do not download")
    p.add_argument("--rollback", action="store_true", help="restore the previous version on next run")
    p = sub.add_parser("capture-key", help="restart Knox Teams and capture the DB key")
    p.add_argument("--timeout", type=float, default=180)
    args = parser.parse_args(argv)

    with contextlib.suppress(Exception):
        staged = load_state().get("staged_update")
        if staged and version_tuple(staged) <= version_tuple(read_version()):
            update_state(staged_update=None, last_applied_update=staged)

    try:
        if args.command == "version":
            emit({"ok": True, "version": read_version(), "error_code": EXIT_OK, "message": "정상"})
            return EXIT_OK
        if args.command == "status":
            emit(do_status())
            return EXIT_OK
        if args.command == "update":
            if args.rollback:
                emit(rollback())
                return EXIT_OK
            res = check_update(force=True, check_only=args.check)
            msg = ("새 버전을 내려받았습니다. 다음 실행부터 적용됩니다." if res.get("staged")
                   else "새 버전이 있습니다." if res.get("available") else "최신 버전입니다.")
            emit({"ok": True, "update": res, "error_code": EXIT_OK, "message": msg})
            return EXIT_OK
        if args.command == "capture-key":
            emit(do_capture_key(args.timeout))
            return EXIT_OK
        if args.command == "refresh":
            try:
                result = do_refresh(args.timeout)
            except LiteError as err:
                update_state(last_refresh_ok=False)
                append_log("refresh.log", f"FAILED code={err.code} {err.message}")
                raise
            if not args.no_update:
                try:
                    result["update"] = check_update(force=False, check_only=False)
                except Exception as e:  # update problems never fail a refresh
                    append_log("update.log", f"auto update failed: {e}")
                    result["update"] = {"error": str(e)}
            emit(result)
            return EXIT_OK
    except LiteError as err:
        if args.command == "update":
            append_log("update.log", f"FAILED {err.message}")
        emit(error_payload(err))
        return err.code
    except Exception as e:  # pragma: no cover - last resort
        code = EXIT_UPDATE_FAILED if args.command == "update" else EXIT_OTHER
        emit({"ok": False, "at": now_iso(), "error_code": code, "message": f"예상하지 못한 오류: {e}"})
        return code
    return EXIT_OTHER


if __name__ == "__main__":
    raise SystemExit(main())
