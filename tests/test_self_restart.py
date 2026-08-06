import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT / 'viewer' / 'server.py'
SPEC = importlib.util.spec_from_file_location('viewer_server_restart_test', SERVER_PATH)
SERVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVER)


def test_create_http_server_retries_then_returns(monkeypatch):
    calls = []
    sleeps = []
    sentinel = object()

    def factory(address, handler):
        calls.append((address, handler))
        if len(calls) < 3:
            raise OSError('still releasing port')
        return sentinel

    monkeypatch.setattr(SERVER.time, 'sleep', sleeps.append)
    result = SERVER.create_http_server(('127.0.0.1', 8799), object(),
                                       attempts=4, delay=0.3, server_factory=factory)

    assert result is sentinel
    assert len(calls) == 3
    assert sleeps == [0.3, 0.3]


def test_update_response_and_frontend_restart_contract():
    source = SERVER_PATH.read_text(encoding='utf-8')
    assert "'restarting': True" in source
    assert "self.wfile.flush()" in source
    assert "v.local===expected" in source
