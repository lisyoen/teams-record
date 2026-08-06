import importlib.util
import tarfile
from pathlib import Path


SERVER_PATH = Path(__file__).parents[1] / 'viewer' / 'server.py'
SPEC = importlib.util.spec_from_file_location('teams_record_server_version_test', SERVER_PATH)
SERVER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVER)


def test_semver_comparison():
    assert SERVER.ver_gt('1.0.1', '1.0.0') is True
    assert SERVER.ver_gt('1.0.0', '1.0.0') is False
    assert SERVER.ver_gt('1.2.0', '1.10.0') is False
    assert SERVER.ver_gt('2.bad.0', '1.9.9') is True


def test_local_version_prefers_server_directory(tmp_path):
    viewer = tmp_path / 'viewer'
    viewer.mkdir()
    server_file = viewer / 'server.py'
    server_file.write_text('', encoding='utf-8')
    (tmp_path / 'VERSION').write_text('1.0.0\n', encoding='utf-8')
    assert SERVER.load_local_version(str(server_file)) == '1.0.0'
    (viewer / 'VERSION').write_text('1.1.0\n', encoding='utf-8')
    assert SERVER.load_local_version(str(server_file)) == '1.1.0'


def test_local_version_falls_back_when_missing(tmp_path):
    assert SERVER.load_local_version(str(tmp_path / 'viewer' / 'server.py')) == '0.0.0'


def test_tar_member_filter_rejects_traversal_and_links():
    assert SERVER.tar_member_is_safe(tarfile.TarInfo('teams-record-main/viewer/server.py'))
    assert not SERVER.tar_member_is_safe(tarfile.TarInfo('../outside'))
    assert not SERVER.tar_member_is_safe(tarfile.TarInfo('/absolute/path'))
    assert not SERVER.tar_member_is_safe(tarfile.TarInfo('C:/absolute/path'))
    link = tarfile.TarInfo('teams-record-main/viewer/link')
    link.type = tarfile.SYMTYPE
    link.linkname = '../../outside'
    assert not SERVER.tar_member_is_safe(link)
