import ast
import importlib.util
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INSTALL = (ROOT / "publish/install.ps1").read_text(encoding="utf-8")
SETUP = (ROOT / "publish/setup.ps1").read_text(encoding="utf-8")
BUILDER_PATH = ROOT / "publish/make_install_zip.py"

spec = importlib.util.spec_from_file_location("installer_builder", BUILDER_PATH)
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

def test_root_installer_exists_and_uses_crlf():
    data = (ROOT / "install.bat").read_bytes()
    assert data.startswith(b"@echo off\r\n")
    assert b"\n" not in data.replace(b"\r\n", b"")
    assert b"publish\\install-select.ps1" in data
    assert b"if not \"%INSTALL_EXIT%\"==\"0\"" in data
    assert "Teams Record 설치 완료" in INSTALL
    assert "Teams Record 설치 실패" in INSTALL

def test_whitelist_contains_runtime_and_excludes_forbidden_paths(tmp_path, monkeypatch):
    required = {"install.bat", "VERSION", "viewer/update-check.bat", "electron/assets/icon.ico"}
    assert required <= set(builder.WHITELIST)
    assert not any(builder.FORBIDDEN.search(name) for name in builder.WHITELIST)

def test_install_root_detection_priority_contract():
    body = INSTALL[INSTALL.index("function Resolve-InstallRoot"):INSTALL.index("function Stop-ViewerProcesses")]
    ordered = ["if ($InstallRoot)", "$MarkerPath", "Get-TaskInstallRoot", "Get-ShortcutInstallRoot", "Get-DefaultInstallRoot"]
    positions = [body.index(token) for token in ordered]
    assert positions == sorted(positions)

def test_knox_is_always_restarted_from_finally():
    finally_body = INSTALL[INSTALL.index("} finally {"):]
    assert "Start-KnoxTeams" in finally_body
    assert INSTALL.index("Stop-KnoxTeams") < INSTALL.index("} finally {")

def test_existing_data_preservation_contract():
    assert "existing teams-archive.db preserved" in SETUP
    assert "-not (Test-Path -LiteralPath $destination)" in SETUP
    install_files = SETUP[SETUP.index("function Install-Files"):SETUP.index("function Notice-Key")]
    for name in ("teams-archive.db", "teams-decrypted.db", "dbkey.secret", "my_id.txt"):
        assert name not in install_files

def test_builder_is_valid_python_and_whitelist_unique():
    ast.parse(BUILDER_PATH.read_text(encoding="utf-8"))
    assert len(builder.WHITELIST) == len(set(builder.WHITELIST))

def test_dependency_install_does_not_hardcode_proxy_or_trusted_hosts():
    capture = (ROOT / "publish/capture-key.bat").read_text(encoding="utf-8")
    assert "--proxy" not in INSTALL + SETUP + capture
    assert "--trusted-host" not in INSTALL + SETUP + capture


def test_installer_asks_viewer_or_cli_only():
    select = (ROOT / "publish/install-select.ps1").read_bytes()
    assert select.startswith(b"\xef\xbb\xbf")
    text = select.decode("utf-8-sig")
    assert "Teams Viewer(대화 열람 화면)도 함께 설치할까요?" in text
    assert "YesNoCancel" in text
    assert "lite\\setup\\lite-install.ps1" in text and "install.ps1" in text
    assert "-ArchivePath" in text  # viewer + CLI share one archive
    names = set(builder.WHITELIST)
    for required in ("publish/install-select.ps1", "lite/app/trlite.py", "lite/setup/lite-install.ps1",
                     "lite/teams-record-lite.bat", "lite/uninstall.bat", "lite/README.md", "lite/AGENT.md",
                     "lite/setup/lite-uninstall.ps1"):
        assert required in names
