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

    class Done:
        returncode, stdout, stderr = 0, b"", b"warn: something"

    def fake_run(cmd, **kw):
        (trlite.WORK / "key_spawn.log").write_text("spawned pid 42\n[pragma] PRAGMA cipher='x'\n[win] 0 windows\n", encoding="utf-8")
        return Done()

    monkeypatch.setattr(trlite.subprocess, "run", fake_run)
    with pytest.raises(trlite.LiteError) as err:
        trlite.do_capture_key(30)
    assert err.value.code == trlite.EXIT_NO_KEY
    assert "spawned pid 42" in err.value.detail and "warn: something" in err.value.detail
    logs = trlite.recent_logs("capture-key", 1)
    assert len(logs["logs"]) == 1 and "result: no PRAGMA key seen" in logs["logs"][0]["text"]


def test_diagnostic_logs_mask_db_keys(trlite):
    assert trlite.mask_keys("PRAGMA key = 'x''abcdef'") .count("abcdef") == 0
    path = trlite.write_diag("capture-key", ["[KEY] PRAGMA key='secretvalue1'"])
    assert "secretvalue1" not in path.read_text(encoding="utf-8")
    assert "****" in trlite.recent_logs("capture-key", 5)["logs"][-1]["text"]
