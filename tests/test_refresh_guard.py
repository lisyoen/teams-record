from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "viewer" / "server.py"
REFRESH_BAT = ROOT / "viewer" / "refresh_archive.bat"


def _assert_contains(name, text, needles):
    missing = [needle for needle in needles if needle not in text]
    assert not missing, "%s missing: %s" % (name, ", ".join(missing))


def test_server_refresh_runs_without_console_and_closed_stdin():
    text = SERVER.read_text(encoding="utf-8")
    _assert_contains(
        "server.py",
        text,
        [
            "CREATE_NO_WINDOW",
            "stdin=subprocess.DEVNULL",
            "creationflags=CREATE_NO_WINDOW",
        ],
    )


def test_server_refresh_rejects_stale_decrypt_output():
    text = SERVER.read_text(encoding="utf-8")
    _assert_contains(
        "server.py",
        text,
        [
            "def _refresh_output_path():",
            "os.path.join(user_profile, 'teams-record-work', 'out', 'teams-decrypted.db')",
            "before_mtime = _mtime_or_zero(refresh_output)",
            "after_mtime = _mtime_or_zero(refresh_output)",
            "after_mtime > before_mtime",
            "복호화 산출물 미갱신",
        ],
    )


def test_refresh_bat_removes_stale_output_and_checks_decrypt_exit_code():
    text = REFRESH_BAT.read_text(encoding="utf-8")
    _assert_contains(
        "refresh_archive.bat",
        text,
        [
            'set "TEAMS_DB_DIR=%WORK%\\out"',
            'del /q "%WORK%\\out\\teams-decrypted.db*" 2>nul',
            'python "%~dp0merge_archive.py" "%WORK%\\out\\teams-decrypted.db" "%DBDIR%\\teams-archive.db"',
            'copy /y "%WORK%\\out\\teams-decrypted.db" "%DBDIR%\\teams-decrypted.db" >nul 2>nul',
            "if errorlevel 1",
            "decrypt produced no output",
        ],
    )


if __name__ == "__main__":
    tests = [
        test_server_refresh_runs_without_console_and_closed_stdin,
        test_server_refresh_rejects_stale_decrypt_output,
        test_refresh_bat_removes_stale_output_and_checks_decrypt_exit_code,
    ]
    failed = 0
    for test in tests:
        try:
            test()
            print("PASS", test.__name__)
        except AssertionError as exc:
            failed += 1
            print("FAIL", test.__name__, "-", exc)
    raise SystemExit(1 if failed else 0)
