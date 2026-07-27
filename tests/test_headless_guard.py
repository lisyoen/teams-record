from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "viewer" / "server.py"
START_VIEWER = ROOT / "viewer" / "start_viewer.bat"
TEAMS_VIEWER = ROOT / "viewer" / "teams-viewer.bat"
ELECTRON_MAIN = ROOT / "electron" / "main.js"


def test_stdout_guard_precedes_server_start():
    src = SERVER.read_text(encoding="utf-8")
    main_pos = src.index("if __name__ == '__main__':")
    guard_pos = src.index("sys.stdout is None", main_pos)
    main_call_pos = src.index("    main()", guard_pos)

    assert "sys.stderr is None" in src[main_pos:]
    assert "viewer.log" in src[main_pos:]
    assert main_pos < guard_pos
    assert guard_pos < main_call_pos
    assert "srv.serve_forever()" in src


def test_logon_backend_uses_pythonw_without_console():
    src = START_VIEWER.read_text(encoding="utf-8")
    assert 'start "" pythonw "%~dp0server.py"' in src
    assert "start /min python " not in src.lower()


def test_interactive_launcher_uses_electron_without_browser():
    src = TEAMS_VIEWER.read_text(encoding="utf-8").lower()
    assert "electron\\teams-viewer-electron.bat" in src
    assert "start chrome" not in src
    assert "start http" not in src

    main = ELECTRON_MAIN.read_text(encoding="utf-8")
    assert "path.resolve(__dirname, '..', 'viewer', 'server.py')" in main
    assert "spawn('pythonw.exe'" in main
    assert "server.on('error'" in main
    assert "START_TIMEOUT_MS = 30000" in main


def run():
    test_stdout_guard_precedes_server_start()
    test_logon_backend_uses_pythonw_without_console()
    test_interactive_launcher_uses_electron_without_browser()
    print("PASS headless guard")


if __name__ == "__main__":
    run()
