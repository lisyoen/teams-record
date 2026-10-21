import hashlib
import importlib
import io
import json
import sqlite3
import sys
import zipfile
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
LITE = REPO / "lite"
sys.path.insert(0, str(LITE))
sys.path.insert(0, str(LITE / "app"))


@pytest.fixture()
def trlite(tmp_path, monkeypatch):
    monkeypatch.setenv("TRLITE_ROOT", str(tmp_path))
    monkeypatch.setenv("USERPROFILE", str(tmp_path / "home"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    monkeypatch.delenv("KNOX_ROOT", raising=False)
    monkeypatch.setenv("TRLITE_KEYSTORE", str(tmp_path / "keys" / "keys.json"))
    import trlite as mod
    mod = importlib.reload(mod)
    return mod


def make_update_zip(version, extra=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("app/trlite.py", "# app\n")
        zf.writestr("app/VERSION", version + "\r\n")
        for k, v in (extra or {}).items():
            zf.writestr(k, v)
    return buf.getvalue()


# ------------------------------------------------------------------ package
def test_build_zip_entries_and_manifest(tmp_path):
    import build_lite_zip as b
    zip_path, manifest_path = b.build(dist=tmp_path)
    with zipfile.ZipFile(zip_path) as zf:
        names = set(zf.namelist())
        assert names == b.expected_names()
        assert "install.bat" in names and "app/trlite.py" in names and "AGENT.md" in names
        assert not any(n.startswith(("electron/", "viewer/")) or "node_modules" in n for n in names)
        assert zf.read("app/VERSION").decode().strip() == b.VERSION
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["version"] == b.VERSION
    assert manifest["sha256"] == hashlib.sha256(zip_path.read_bytes()).hexdigest()
    assert manifest["url"].endswith(f"/v{b.VERSION}/teams-record-lite-v{b.VERSION}.zip")
    assert manifest["runtime"] == b.RUNTIME_ID


def test_build_manifest_internal_base_url(tmp_path):
    import build_lite_zip as b
    _, manifest_path = b.build(base_url="http://intra.example/tr-lite/", dist=tmp_path)
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["url"] == f"http://intra.example/tr-lite/teams-record-lite-v{b.VERSION}.zip"


@pytest.mark.parametrize("rel", ["install.bat", "uninstall.bat", "teams-record-lite.bat"])
def test_bat_files_crlf_ascii(rel):
    data = (LITE / rel).read_bytes()
    assert b"\r\n" in data and b"\n" not in data.replace(b"\r\n", b"")
    data.decode("ascii")


@pytest.mark.parametrize("rel", ["setup/lite-install.ps1", "setup/lite-uninstall.ps1"])
def test_ps1_utf8_bom(rel):
    assert (LITE / rel).read_bytes().startswith(b"\xef\xbb\xbf")


def test_installer_contract():
    text = (LITE / "setup/lite-install.ps1").read_text(encoding="utf-8-sig")
    assert "python-$PythonVersion-embed-amd64.zip" in text
    assert "$PythonEmbedSha256" in text and "Get-FileHash" in text
    assert "Knox Teams 메신저가 잠시 종료되었다가 자동으로 다시 실행됩니다" in text
    assert "설치가 완료되었습니다" in text and "자동으로 적용됩니다" in text
    assert "DefaultWebProxy" in text
    assert "RunAs" not in text  # per-user install, no elevation
    assert "기존 설정 파일 보존" in text and "기존 DB 키 보존" in text


def test_launcher_applies_staged_update_and_rollback():
    text = (LITE / "teams-record-lite.bat").read_text(encoding="ascii")
    assert "app.new\\trlite.py" in text and "app.old" in text and "rollback.request" in text
    assert "runtime\\python\\python.exe" in text


def test_shared_scripts_accept_lite_overrides():
    js = (REPO / "publish/work/decrypt_export.js").read_text(encoding="utf-8")
    assert "process.env.TEAMS_RECORD_WORK" in js and "process.env.TEAMS_RECORD_SQLITE_JS" in js
    py = (REPO / "publish/work/spawn_key.py").read_text(encoding="utf-8")
    assert "TEAMS_RECORD_WORK" in py


# -------------------------------------------------------------------- CLI
def test_parse_merge_output(trlite):
    out = ("MERGE_OK tables=28 changed=2\n  SCHEMA_ADD TB_KtMessage    NewCol,Other\n"
           "  +1      TB_KtMessage       2014 -> 2015\n  +3      TB_RelateMessage   158 -> 161\n"
           "ARCHIVE_TOTAL TB_KtMessage=2015 TB_KmMessage=739 last_merge=2026-10-20 10:04:25\n")
    r = trlite.parse_merge_output(out)
    assert r["changed"] == {"TB_KtMessage": 1, "TB_RelateMessage": 3}
    assert r["totals"] == {"TB_KtMessage": 2015, "TB_KmMessage": 739}
    assert r["last_merge"] == "2026-10-20 10:04:25"
    assert r["schema_added"] == {"TB_KtMessage": ["NewCol", "Other"]}


def test_version_tuple(trlite):
    assert trlite.version_tuple("v1.2.10") > trlite.version_tuple("1.2.9")
    assert trlite.version_tuple("1.1") == (1, 1, 0)


def test_ensure_key_reuses_legacy_key(trlite):
    trlite.LEGACY_KEY.parent.mkdir(parents=True)
    trlite.LEGACY_KEY.write_text("x'abc'", encoding="utf-8")
    trlite.ensure_key()
    assert trlite.KEY_PATH.read_text(encoding="utf-8") == "x'abc'"


def test_missing_key_exit_code(trlite, monkeypatch, capsys):
    monkeypatch.setattr(trlite, "find_knox_root", lambda c: Path("."))
    rc = trlite.main(["refresh", "--no-update"])
    out = json.loads(capsys.readouterr().out)
    assert rc == trlite.EXIT_NO_KEY and out["ok"] is False and out["error_code"] == 3


def test_missing_knox_exit_code(trlite, monkeypatch, capsys):
    monkeypatch.setattr(trlite.shutil, "which", lambda name: None)
    monkeypatch.setattr(trlite, "load_config", lambda: dict(trlite.DEFAULT_CONFIG, knox_root=""))
    rc = trlite.main(["refresh", "--no-update"])
    out = json.loads(capsys.readouterr().out)
    assert rc == trlite.EXIT_NOT_INSTALLED and out["error_code"] == 2


def test_lock_timeout(trlite):
    lock = trlite.WORK / "refresh.lock"
    with trlite.file_lock(lock, 1):
        with pytest.raises(trlite.LiteError) as e:
            with trlite.file_lock(lock, 0.6):
                pass
    assert e.value.code == trlite.EXIT_TIMEOUT


def test_status_reads_archive_read_only(trlite, capsys):
    trlite.DATA.mkdir(parents=True)
    con = sqlite3.connect(trlite.ARCHIVE)
    con.execute("CREATE TABLE TB_KtMessage (MessageId TEXT PRIMARY KEY)")
    con.execute("CREATE TABLE TB_KmMessage (MessageId TEXT PRIMARY KEY)")
    con.execute("INSERT INTO TB_KtMessage VALUES ('a'),('b')")
    con.execute("CREATE TABLE _archive_meta (k TEXT PRIMARY KEY, v TEXT)")
    con.execute("INSERT INTO _archive_meta VALUES ('last_merge','2026-10-21 10:00:00')")
    con.commit(); con.close()
    assert trlite.main(["status"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["archive"]["totals"] == {"TB_KtMessage": 2, "TB_KmMessage": 0}
    assert out["archive"]["last_merge"] == "2026-10-21 10:00:00"


def test_stage_update_rejects_sha_mismatch(trlite):
    trlite.ROOT.mkdir(parents=True, exist_ok=True)
    with pytest.raises(trlite.LiteError) as e:
        trlite.stage_update({"version": "9.9.9", "sha256": "00"}, make_update_zip("9.9.9"))
    assert e.value.code == trlite.EXIT_UPDATE_FAILED
    assert not (trlite.ROOT / "app.new").exists()


def test_stage_update_ok_and_rejects_bad_paths(trlite):
    trlite.ROOT.mkdir(parents=True, exist_ok=True)
    payload = make_update_zip("9.9.9")
    staged = trlite.stage_update({"version": "9.9.9", "sha256": hashlib.sha256(payload).hexdigest()}, payload)
    assert (staged / "trlite.py").is_file() and (staged / "VERSION").read_text().strip() == "9.9.9"
    bad = make_update_zip("9.9.9", {"app/../evil.txt": "x"})
    with pytest.raises(trlite.LiteError):
        trlite.stage_update({"version": "9.9.9", "sha256": hashlib.sha256(bad).hexdigest()}, bad)


def test_stage_update_rejects_version_mismatch(trlite):
    trlite.ROOT.mkdir(parents=True, exist_ok=True)
    payload = make_update_zip("9.9.8")
    with pytest.raises(trlite.LiteError):
        trlite.stage_update({"version": "9.9.9", "sha256": hashlib.sha256(payload).hexdigest()}, payload)


def test_check_update_throttle_and_disable(trlite, monkeypatch):
    calls = []
    monkeypatch.setattr(trlite, "fetch_manifest", lambda url: calls.append(url) or {
        "version": "0.0.0", "url": "x", "sha256": "y"})
    r = trlite.check_update(force=False, check_only=False)
    assert r["checked"] and len(calls) == 1
    r = trlite.check_update(force=False, check_only=False)
    assert r.get("skipped") == "checked recently" and len(calls) == 1
    trlite.save_json(trlite.CONFIG_PATH, {"auto_update": False})
    trlite.update_state(last_update_check_epoch=0)
    r = trlite.check_update(force=False, check_only=False)
    assert r.get("skipped") == "auto_update disabled" and len(calls) == 1


def test_check_update_stages_newer_version(trlite, monkeypatch):
    payload = make_update_zip("99.0.0")
    monkeypatch.setattr(trlite, "fetch_manifest", lambda url: {
        "version": "99.0.0", "url": "http://h/z.zip", "sha256": hashlib.sha256(payload).hexdigest(),
        "runtime": "other-runtime"})
    monkeypatch.setattr(trlite, "http_get", lambda url, timeout=60: payload)
    trlite.update_state(runtime="py3.11.9-embed+frida")
    r = trlite.check_update(force=True, check_only=False)
    assert r["staged"] and r["runtime_update_required"]
    assert trlite.load_state()["staged_update"] == "99.0.0"


def test_check_only_does_not_download(trlite, monkeypatch):
    monkeypatch.setattr(trlite, "fetch_manifest", lambda url: {"version": "99.0.0", "url": "u", "sha256": "s"})
    monkeypatch.setattr(trlite, "http_get", lambda *a, **k: pytest.fail("download in check-only mode"))
    r = trlite.check_update(force=True, check_only=True)
    assert r["available"] and not r["staged"]


def test_fetch_manifest_resolves_relative_url(trlite, monkeypatch):
    monkeypatch.setattr(trlite, "http_get", lambda url, timeout=60: json.dumps(
        {"version": "1.0.0", "url": "pkg.zip", "sha256": "ab"}).encode())
    m = trlite.fetch_manifest("http://intra.example/tr/latest.json")
    assert m["url"] == "http://intra.example/tr/pkg.zip"


def test_fetch_manifest_rejects_incomplete(trlite, monkeypatch):
    monkeypatch.setattr(trlite, "http_get", lambda url, timeout=60: b'{"version": "1.0.0"}')
    with pytest.raises(trlite.LiteError) as e:
        trlite.fetch_manifest("http://intra.example/tr/latest.json")
    assert e.value.code == trlite.EXIT_UPDATE_FAILED


def test_refresh_update_failure_does_not_fail_refresh(trlite, monkeypatch, capsys):
    monkeypatch.setattr(trlite, "do_refresh", lambda t: {"ok": True, "error_code": 0})
    def boom(**kw):
        raise RuntimeError("offline")
    monkeypatch.setattr(trlite, "check_update", boom)
    assert trlite.main(["refresh"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert out["ok"] and out["update"]["error"] == "offline"


def test_rollback_requires_previous_version(trlite, capsys):
    assert trlite.main(["update", "--rollback"]) == trlite.EXIT_UPDATE_FAILED
    (trlite.ROOT / "app.old").mkdir(parents=True)
    (trlite.ROOT / "app.old" / "VERSION").write_text("1.0.0")
    capsys.readouterr()
    assert trlite.main(["update", "--rollback"]) == 0
    assert (trlite.ROOT / "rollback.request").is_file()


def test_archive_path_config_shares_viewer_archive(trlite, tmp_path, capsys):
    shared = tmp_path / "viewer" / "teams-archive.db"
    trlite.save_json(trlite.CONFIG_PATH, {"archive_path": str(shared)})
    assert trlite.archive_file() == shared
    trlite.main(["status"])
    out = json.loads(capsys.readouterr().out)
    assert out["archive"]["archive_path"] == str(shared)


def test_ensure_key_follows_newer_viewer_key(trlite):
    import os, time
    trlite.WORK.mkdir(parents=True)
    trlite.KEY_PATH.write_text("old", encoding="utf-8")
    os.utime(trlite.KEY_PATH, (time.time() - 100, time.time() - 100))
    trlite.ensure_key()  # no legacy key -> keep own key
    assert trlite.KEY_PATH.read_text(encoding="utf-8") == "old"
    trlite.LEGACY_KEY.parent.mkdir(parents=True)
    trlite.LEGACY_KEY.write_text("new", encoding="utf-8")
    trlite.ensure_key()
    assert trlite.KEY_PATH.read_text(encoding="utf-8") == "new"


def test_lite_installer_supports_repo_layout_and_shared_archive():
    text = (LITE / "setup/lite-install.ps1").read_text(encoding="utf-8-sig")
    assert "$RepoLayout" in text and "viewer\\merge_archive.py" in text
    assert "$ArchivePath" in text and "archive_path" in text
