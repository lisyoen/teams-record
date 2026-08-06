import ast
from pathlib import Path


SERVER_PATH = Path(__file__).parents[1] / 'viewer' / 'server.py'


def page_source():
    tree = ast.parse(SERVER_PATH.read_text(encoding='utf-8'))
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == 'PAGE' for target in node.targets
        ):
            return ast.literal_eval(node.value)
    raise AssertionError('PAGE string not found')


def test_version_poll_contract():
    page = page_source()
    assert 'setInterval(checkUpdate,60000)' in page
    assert "document.addEventListener('visibilitychange'" in page
    assert "fetch('/api/version',{cache:'no-store'})" in page
    assert '#verbadge.newver{' in page
