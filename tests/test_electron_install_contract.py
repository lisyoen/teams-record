from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SETUP = (ROOT / "publish" / "setup.ps1").read_text(encoding="utf-8")
INSTALL = (ROOT / "publish" / "install.ps1").read_text(encoding="utf-8")
UNINSTALL = (ROOT / "publish" / "uninstall.ps1").read_text(encoding="utf-8")
PACK = (ROOT / "publish" / "make-install-zip.ps1").read_text(encoding="utf-8")


def test_one_click_installs_and_shortcuts_electron():
    assert "Install-NodeLts" in SETUP
    assert "npm.cmd ci --include=dev --no-audit --no-fund" in SETUP
    assert "package-lock.json" in SETUP
    assert "$shortcut.TargetPath = $ElectronExe" in SETUP
    assert "$shortcut.Arguments = \"`\"$ElectronDir`\"\"" in SETUP
    assert "Install-Frida" in INSTALL
    assert "Database key capture" in INSTALL


def test_uninstall_requires_explicit_data_opt_in():
    assert "[switch]$DeleteData" in UNINSTALL
    opt_in = UNINSTALL.index("if ($DeleteData)")
    data_delete = UNINSTALL.index("Remove-Item -LiteralPath $WorkDir -Recurse -Force")
    preserve = UNINSTALL.index("[PRESERVED]")
    assert opt_in < data_delete < preserve
    assert "teams-archive.db" in UNINSTALL
    assert "dbkey.secret" in UNINSTALL
    assert "work/backup data" in UNINSTALL


def test_install_zip_is_whitelisted_and_rejects_sensitive_entries():
    assert "$electronFiles" in PACK
    assert "node_modules" in PACK
    assert "dbkey\\.secret" in PACK
    assert "secrets|keys|thumbs" in PACK
    assert "\\.(key|sqlcipher-key)" in PACK
    assert "\\.env" in PACK
    assert "(token|cookie|session)" in PACK
    assert "Test-SqliteHeader" in PACK
    assert "git -C $RepoRoot ls-files" in PACK
    assert "Copy-WhiteListedFile" in PACK
