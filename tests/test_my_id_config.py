import importlib.util
from pathlib import Path


SERVER_PATH = Path(__file__).parents[1] / 'viewer' / 'server.py'
SPEC = importlib.util.spec_from_file_location('teams_record_server_my_id_test', SERVER_PATH)
SERVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVER)


def test_my_id_prefers_environment(monkeypatch, tmp_path):
    (tmp_path / 'my_id.txt').write_text('from-file\n', encoding='utf-8')
    monkeypatch.setenv('TEAMS_RECORD_MY_ID', 'from-env')
    assert SERVER.load_my_id(str(tmp_path)) == 'from-env'


def test_my_id_falls_back_to_local_file(monkeypatch, tmp_path):
    monkeypatch.delenv('TEAMS_RECORD_MY_ID', raising=False)
    (tmp_path / 'my_id.txt').write_text('from-file\n', encoding='utf-8')
    assert SERVER.load_my_id(str(tmp_path)) == 'from-file'


def test_missing_my_id_disables_own_message_detection(monkeypatch, tmp_path):
    monkeypatch.delenv('TEAMS_RECORD_MY_ID', raising=False)
    assert SERVER.load_my_id(str(tmp_path)) is None

    monkeypatch.setattr(SERVER, 'MY_ID', None)
    message = SERVER.norm(
        {'MessageId': '1', 'SentTime': 100, 'Sender': 'sender', 'Content': 'text'},
        'km',
        ends={'reader': 200},
        others=['reader'],
    )
    assert 'rd' not in message
    assert 'rt' not in message
