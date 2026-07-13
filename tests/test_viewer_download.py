from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
src = (ROOT / "viewer" / "server.py").read_text(encoding="utf-8")

assert 'id="btnDlMd"' in src
assert "buildMd" in src
assert "text/markdown" in src
