from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALL_PATH = ROOT / "publish" / "install.ps1"
SETUP_PATH = ROOT / "publish" / "setup.ps1"
INSTALL = INSTALL_PATH.read_text(encoding="utf-8-sig")
SETUP = SETUP_PATH.read_text(encoding="utf-8-sig")


def test_path_refresh_and_absolute_executable_fallbacks():
    assert "GetEnvironmentVariable('Path', 'Machine')" in SETUP
    assert "GetEnvironmentVariable('Path', 'User')" in SETUP
    assert "function Resolve-Executable" in SETUP
    assert "Programs\\Python\\Python311\\python.exe" in SETUP
    assert "ProgramFiles 'nodejs'" in SETUP
    assert "$script:PythonExe" in INSTALL
    assert "function Resolve-PythonExecutable" in INSTALL


def test_system_proxy_is_forwarded_to_download_pip_and_npm():
    assert "[System.Net.WebRequest]::DefaultWebProxy" in SETUP
    assert "[System.Net.CredentialCache]::DefaultCredentials" in SETUP
    assert "ProxyUseDefaultCredentials" in SETUP
    for name in ("HTTP_PROXY", "HTTPS_PROXY", "NPM_CONFIG_PROXY", "NPM_CONFIG_HTTPS_PROXY"):
        assert f"$env:{name}" in SETUP
    assert "$env:PIP_PROXY" in INSTALL
    assert "-m pip install frida" in INSTALL


def test_start_completion_failure_popups_and_cancel_before_mutation():
    assert "[System.Windows.Forms.MessageBox]::Show" in INSTALL
    assert "MessageBoxButtons]::OKCancel" in INSTALL
    assert "DialogResult]::OK" in INSTALL
    cancel = INSTALL.index("if ($answer -ne")
    elevation = INSTALL.index("if (-not (Test-Admin))")
    logging = INSTALL.index("New-Item -ItemType Directory -Path $LogDir")
    assert cancel < elevation < logging
    assert "Teams Record 설치가 완료되었습니다." in INSTALL
    assert "설치 버전: $packageVersion" in INSTALL
    assert "실패 단계: $script:FailedStage" in INSTALL
    assert "로그 경로: $LogPath" in INSTALL
    assert "Knox Teams: $script:KnoxRestartResult" in INSTALL


def test_korean_powershell_files_use_utf8_bom_and_bat_has_no_korean():
    for path in (INSTALL_PATH, SETUP_PATH):
        assert path.read_bytes().startswith(b"\xef\xbb\xbf"), path
    for path in (ROOT / "install.bat", ROOT / "publish" / "install.bat"):
        path.read_bytes().decode("ascii")


def test_refresh_plaintext_marker_is_codepage_safe_ascii():
    decrypt = (ROOT / "publish" / "work" / "decrypt_export.js").read_text(
        encoding="utf-8"
    )
    assert "PLAINTEXT_OPEN_OK(opened-without-key)" in decrypt
    assert "PLAINTEXT_OPEN_OK(키없이열림)" not in decrypt
