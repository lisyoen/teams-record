import importlib.util
import json
import sqlite3
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT / "viewer" / "server.py"


def load_server():
    spec = importlib.util.spec_from_file_location("viewer_server", SERVER_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def make_db(path):
    con = sqlite3.connect(path)
    con.executescript(
        """
        CREATE TABLE TB_Channel (
            ChannelID TEXT PRIMARY KEY,
            Title TEXT
        );
        CREATE TABLE TB_Chatroom (
            ChatroomID TEXT PRIMARY KEY,
            Title TEXT,
            ParticipantInfos TEXT,
            LastMsgBody TEXT,
            LastMsgTime INTEGER
        );
        CREATE TABLE TB_KmContact (
            UserID TEXT PRIMARY KEY,
            LocalName TEXT,
            Department TEXT,
            CompanyName TEXT,
            Position TEXT
        );
        CREATE TABLE TB_KtContact (
            UserID TEXT PRIMARY KEY,
            LocalName TEXT,
            Department TEXT,
            CompanyName TEXT,
            Position TEXT
        );
        CREATE TABLE TB_KtMessage (
            MessageId TEXT PRIMARY KEY,
            ChannelID TEXT,
            Content TEXT,
            MessageType INTEGER,
            SentTime INTEGER,
            Sender TEXT,
            Recalled INTEGER,
            Deleted INTEGER,
            ReactionInfo TEXT
        );
        CREATE TABLE TB_KmMessage (
            MessageId TEXT PRIMARY KEY,
            ChatroomId TEXT,
            Content TEXT,
            MessageType INTEGER,
            SentTime INTEGER,
            Sender TEXT,
            Recalled INTEGER,
            DeleteRequesterId TEXT,
            ReactionInfo TEXT,
            FileName TEXT
        );
        """
    )
    con.execute("INSERT INTO TB_Channel VALUES (?,?)", ("chan-1", "일반"))
    con.execute(
        "INSERT INTO TB_Chatroom VALUES (?,?,?,?,?)",
        ("room-1", "", json.dumps([["111111111111", {}], ["222222222222", {}]]), "", 2000),
    )
    con.execute("INSERT INTO TB_KmContact VALUES (?,?,?,?,?)", ("111111111111", "홍길동", "", "", ""))
    con.execute("INSERT INTO TB_KmContact VALUES (?,?,?,?,?)", ("222222222222", "김철수", "", "", ""))
    con.execute("INSERT INTO TB_KtContact VALUES (?,?,?,?,?)", ("111111111111", "홍길동", "", "", ""))
    con.execute(
        "INSERT INTO TB_KtMessage VALUES (?,?,?,?,?,?,?,?,?)",
        ("kt-1", "chan-1", "오늘 검색토큰 회의합니다", 0, 3000, "111111111111", 0, 0, ""),
    )
    con.execute(
        "INSERT INTO TB_KmMessage VALUES (?,?,?,?,?,?,?,?,?,?)",
        ("km-1", "room-1", json.dumps({"text": "검색토큰 자료 공유"}), 0, 4000, "222222222222", 0, "", "", ""),
    )
    con.execute(
        "INSERT INTO TB_KmMessage VALUES (?,?,?,?,?,?,?,?,?,?)",
        ("km-false", "room-1", json.dumps({"검색토큰": "key only", "text": "표시 본문"}), 0, 5000, "222222222222", 0, "", "", ""),
    )
    con.execute(
        "INSERT INTO TB_KmMessage VALUES (?,?,?,?,?,?,?,?,?,?)",
        ("km-media", "room-1", json.dumps({"media": {"filename": "검색토큰.pdf"}}), 13, 6000, "222222222222", 0, "", "", "검색토큰.pdf"),
    )
    con.commit()
    con.close()


def with_sample_db(server):
    tmp = tempfile.NamedTemporaryFile(suffix=".db", delete=False)
    tmp.close()
    make_db(tmp.name)
    server.DB = tmp.name
    server._NAME_CACHE = None
    return Path(tmp.name)


def assert_result_schema(item):
    required = {"kind", "id", "title", "s", "sname", "t", "mid", "snippet"}
    missing = required - set(item)
    assert not missing, missing
    assert item["kind"] in {"kt", "km"}


def run():
    server = load_server()
    db_path = Path(getattr(server, "DB", ""))
    sample_path = None
    if not db_path.exists():
        sample_path = with_sample_db(server)

    term = "검색토큰" if sample_path else "회의"
    res = server.api_search(term)
    if not res["results"] and sample_path is None:
        sample_path = with_sample_db(server)
        term = "검색토큰"
        res = server.api_search(term)

    assert res["q"] == term
    assert res["count"] >= 1
    kinds = {r["kind"] for r in res["results"]}
    assert kinds & {"kt", "km"}
    for item in res["results"]:
        assert_result_schema(item)
        assert term.casefold() in item["snippet"].casefold()

    false_positive_ids = {r["mid"] for r in res["results"]}
    assert "km-false" not in false_positive_ids
    assert "km-media" not in false_positive_ids

    for item in res["results"]:
        table = "TB_KtMessage" if item["kind"] == "kt" else "TB_KmMessage"
        con = sqlite3.connect(server.DB)
        try:
            row = con.execute(f"SELECT Content FROM {table} WHERE MessageId=?", (item["mid"],)).fetchone()
        finally:
            con.close()
        assert row is not None
        assert term.casefold() in server.clean(row[0]).casefold()

    none = server.api_search("NO_SUCH_SEARCH_TOKEN_20260713")
    assert none["count"] == 0
    assert none["results"] == []
    print("PASS search api")


if __name__ == "__main__":
    run()
