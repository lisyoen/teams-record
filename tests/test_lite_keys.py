"""1.3.1: captured DB keys are kept in a store outside the install folder; refresh retries and falls back to them."""
import importlib
import json
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "lite" / "app"))


@pytest.fixture()
def trlite(tmp_path, monkeypatch):
    monkeypatch.setenv("TRLITE_ROOT", str(tmp_path / "install"))
    monkeypatch.setenv("TRLITE_KEYSTORE", str(tmp_path / "keys" / "keys.json"))
    monkeypatch.setenv("USERPROFILE", str(tmp_path / "home"))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    import trlite as mod
    return importlib.reload(mod)


def _fake_refresh_env(trlite, monkeypatch, tmp_path, good_key, fail_first=0):
    knox = tmp_path / "knox"; knox.mkdir()
    live = tmp_path / "live.db"; live.write_bytes(b"x")
    monkeypatch.setattr(trlite, "find_knox_root", lambda c: knox)
    monkeypatch.setattr(trlite, "find_live_db", lambda: live)
    calls = {"decrypt": [], "fails": fail_first}

    def run_step(cmd, env, remaining, name):
        if name == "decrypt":
            key = trlite.KEY_PATH.read_text(encoding="utf-8")
            calls["decrypt"].append(key)
            if key == good_key and calls["fails"] <= 0:
                (Path(env["TEAMS_DB_DIR"]) / "teams-decrypted.db").write_bytes(b"db")
                return "EXPORT_OK"
            calls["fails"] -= 1
            return "ATTACH_ERR SQLITE_NOTADB: file is not a database"
        return "MERGE_OK"
    monkeypatch.setattr(trlite, "run_step", run_step)
    monkeypatch.setattr(trlite, "parse_merge_output", lambda out: {"changed": {}, "totals": {}, "last_merge": "", "schema_added": {}})
    monkeypatch.setattr(trlite.time, "sleep", lambda s: None)
    return calls


def test_store_survives_reinstall_and_restores_key(trlite):
    trlite.remember_key("x'aaa'", "capture"); trlite.remember_key("x'bbb'", "capture"); trlite.remember_key("x'aaa'", "refresh")
    assert trlite.known_keys() == ["x'aaa'", "x'bbb'"]
    assert "x'aaa'" not in trlite.KEYSTORE.read_text()                    # stored protected (plain only off Windows)  or encoded
    trlite.ensure_key()                                                    # install folder has no key → restored from store
    assert trlite.KEY_PATH.read_text(encoding="utf-8") == "x'aaa'"


def test_transient_decrypt_failure_retries_same_key(trlite, monkeypatch, tmp_path):
    trlite.WORK.mkdir(parents=True); trlite.KEY_PATH.write_text("x'good'", encoding="utf-8")
    calls = _fake_refresh_env(trlite, monkeypatch, tmp_path, "x'good'", fail_first=1)
    out = trlite.do_refresh(300)
    assert out["ok"] and calls["decrypt"] == ["x'good'", "x'good'"]


def test_falls_back_to_previous_key(trlite, monkeypatch, tmp_path):
    trlite.remember_key("x'old-good'", "capture")
    trlite.WORK.mkdir(parents=True); trlite.KEY_PATH.write_text("x'stale'", encoding="utf-8")
    calls = _fake_refresh_env(trlite, monkeypatch, tmp_path, "x'old-good'")
    assert trlite.do_refresh(300)["ok"]
    assert calls["decrypt"][-1] == "x'old-good'" and trlite.KEY_PATH.read_text(encoding="utf-8") == "x'old-good'"
    assert trlite.known_keys()[0] == "x'old-good'"


def test_all_keys_fail_keeps_original_and_says_so(trlite, monkeypatch, tmp_path):
    trlite.remember_key("x'other'", "capture")
    trlite.WORK.mkdir(parents=True); trlite.KEY_PATH.write_text("x'cur'", encoding="utf-8")
    _fake_refresh_env(trlite, monkeypatch, tmp_path, "x'none'")
    with pytest.raises(trlite.LiteError) as e:
        trlite.do_refresh(300)
    assert e.value.code == trlite.EXIT_REFRESH_FAILED and "2개" in e.value.message
    assert trlite.KEY_PATH.read_text(encoding="utf-8") == "x'cur'"


def test_capture_key_failure_writes_masked_diagnostic_log(trlite, monkeypatch, tmp_path):
    """1.3.2: a failed capture keeps a diagnostic log (spawn output, Knox processes) and returns it in detail."""
    knox = tmp_path / "knox"; knox.mkdir(); (knox / "KnoxTeams.exe").write_text("")
    monkeypatch.setattr(trlite, "find_knox_root", lambda config: knox)
    monkeypatch.setattr(trlite, "kill_knox", lambda: True)
    monkeypatch.setattr(trlite, "start_knox", lambda k: None)
    monkeypatch.setattr(trlite.time, "sleep", lambda s: None)

    seen = {}

    class FakeProc:
        pid = 1
        def __init__(self, cmd, **kw):
            seen.update(kw)
            kw["stdout"].write(b"warn: something")
            (trlite.WORK / "key_spawn.log").write_text("spawned pid 42\n[pragma] PRAGMA cipher='x'\n[win] 0 windows\n", encoding="utf-8")
        def wait(self, timeout=None): return 0

    monkeypatch.setattr(trlite.subprocess, "Popen", FakeProc)
    monkeypatch.setattr(trlite, "knox_running", lambda: True)
    with pytest.raises(trlite.LiteError) as err:
        trlite.do_capture_key(30)
    assert err.value.code == trlite.EXIT_NO_KEY
    assert "spawned pid 42" in err.value.detail and "warn: something" in err.value.detail
    logs = trlite.recent_logs("capture-key", 1)
    assert len(logs["logs"]) == 1 and "result: no PRAGMA key seen" in logs["logs"][0]["text"]
    # 1.3.3: no pipes for spawn_key (Knox Teams inherits them and the wait never ends)
    assert seen["stdout"] is not trlite.subprocess.PIPE and seen["stderr"] is trlite.subprocess.STDOUT
    assert seen["env"]["TEAMS_RECORD_KEY_MODE"] == "attach" and int(seen["env"]["TEAMS_RECORD_KEY_WAIT"]) <= 120


def test_diagnostic_logs_mask_db_keys(trlite):
    assert trlite.mask_keys("PRAGMA key = 'x''abcdef'") .count("abcdef") == 0
    path = trlite.write_diag("capture-key", ["[KEY] PRAGMA key='secretvalue1'"])
    assert "secretvalue1" not in path.read_text(encoding="utf-8")
    assert "****" in trlite.recent_logs("capture-key", 5)["logs"][-1]["text"]



def test_capture_mode_alternates_after_failure(trlite):
    assert trlite.capture_mode() == "attach"
    trlite.update_state(last_capture_mode="attach", last_capture_ok=False)
    assert trlite.capture_mode() == "spawn"
    trlite.update_state(last_capture_mode="spawn", last_capture_ok=False)
    assert trlite.capture_mode() == "attach"
    trlite.update_state(last_capture_mode="spawn", last_capture_ok=True)
    assert trlite.capture_mode() == "spawn"


def test_captured_key_is_shared_with_viewer(trlite):
    trlite.LEGACY_KEY.parent.mkdir(parents=True, exist_ok=True)
    trlite.LEGACY_KEY.write_text("x'old'", encoding="utf-8")
    trlite.share_key_with_viewer("x'new'")
    assert trlite.LEGACY_KEY.read_text(encoding="utf-8") == "x'new'"


def test_status_reports_needs_key(trlite):
    trlite.update_state(last_refresh_needs_key=True)
    assert trlite.do_status()["needs_key"] is True
    trlite.WORK.mkdir(parents=True, exist_ok=True); trlite.KEY_PATH.write_text("x'k'", encoding="utf-8")
    trlite.update_state(last_refresh_needs_key=False)
    assert trlite.do_status()["needs_key"] is False


def test_running_log_survives_and_watchdog_logs(trlite, monkeypatch):
    """1.3.4: lines reach logs/capture-key-running.log immediately; the final log replaces it."""
    d = trlite.RunningDiag("capture-key", ["=== start ==="])
    d.append("kill_knox -> True")
    text = (trlite.LOGS / "capture-key-running.log").read_text(encoding="utf-8")
    assert "kill_knox -> True" in text and "=== start ===" in text
    d += ["PRAGMA key = 'x''secret'"]
    assert "secret" not in (trlite.LOGS / "capture-key-running.log").read_text(encoding="utf-8")
    assert trlite.recent_logs("capture-key", 1)["logs"][-1]["file"] == "capture-key-running.log"
    d.done(); assert not (trlite.LOGS / "capture-key-running.log").exists()


def test_logs_update_log_tail(trlite):
    trlite.append_log("update.log", "staged 1.3.4 (current 1.2.0)")
    out = trlite.recent_logs("update", 1)
    assert out["logs"][0]["file"] == "update.log" and "staged 1.3.4" in out["logs"][0]["text"]


def test_intranet_hosts_skip_proxy(trlite):
    assert trlite.is_direct_host("172.21.114.72") and trlite.is_direct_host("10.0.0.5") and trlite.is_direct_host("spark2")
    assert not trlite.is_direct_host("github.com") and not trlite.is_direct_host("skipper.craftbay.io")
