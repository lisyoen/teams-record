from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER = ROOT / "viewer" / "server.py"
START_VIEWER = ROOT / "viewer" / "start_viewer.bat"
TEAMS_VIEWER = ROOT / "viewer" / "teams-viewer.bat"


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


def test_batch_files_use_pythonw_without_minimized_console():
    for path in (START_VIEWER, TEAMS_VIEWER):
        src = path.read_text(encoding="utf-8")
        assert 'start "" pythonw "%~dp0server.py"' in src, path
        assert "start /min python " not in src.lower(), path
        assert 'start "teams-viewer" /min python' not in src, path


def run():
    test_stdout_guard_precedes_server_start()
    test_batch_files_use_pythonw_without_minimized_console()
    print("PASS headless guard")


if __name__ == "__main__":
    run()
