import sqlite3
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MERGER = ROOT / "viewer" / "merge_archive.py"


def test_merge_adds_columns_from_newer_source_schema(tmp_path):
    fresh = tmp_path / "fresh.db"
    archive = tmp_path / "archive.db"

    with sqlite3.connect(fresh) as con:
        con.execute(
            "CREATE TABLE TB_Chatroom ("
            "ChatroomID TEXT PRIMARY KEY, Title TEXT, ChatTransLang TEXT)"
        )
        con.execute(
            "INSERT INTO TB_Chatroom VALUES ('room-1', 'title', 'ko')"
        )
        con.execute("CREATE TABLE TB_KtMessage (id TEXT PRIMARY KEY)")
        con.execute("CREATE TABLE TB_KmMessage (id TEXT PRIMARY KEY)")

    with sqlite3.connect(archive) as con:
        con.execute(
            "CREATE TABLE TB_Chatroom (ChatroomID TEXT PRIMARY KEY, Title TEXT)"
        )
        con.execute("INSERT INTO TB_Chatroom VALUES ('old-room', 'old')")
        con.execute("CREATE TABLE TB_KtMessage (id TEXT PRIMARY KEY)")
        con.execute("CREATE TABLE TB_KmMessage (id TEXT PRIMARY KEY)")

    result = subprocess.run(
        [sys.executable, str(MERGER), str(fresh), str(archive)],
        check=True,
        capture_output=True,
        text=True,
    )

    assert "SCHEMA_ADD TB_Chatroom" in result.stdout
    with sqlite3.connect(archive) as con:
        columns = [row[1] for row in con.execute("PRAGMA table_info(TB_Chatroom)")]
        rows = con.execute(
            "SELECT ChatroomID, Title, ChatTransLang "
            "FROM TB_Chatroom ORDER BY ChatroomID"
        ).fetchall()
    assert columns == ["ChatroomID", "Title", "ChatTransLang"]
    assert rows == [("old-room", "old", None), ("room-1", "title", "ko")]
