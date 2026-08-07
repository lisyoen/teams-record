import http.client
import importlib.util
import json
import re
import sqlite3
import sys
import tempfile
import threading
import urllib.parse
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SERVER_PATH = ROOT / "remote_web" / "server.py"
SPEC = importlib.util.spec_from_file_location("teams_record_remote_test", SERVER_PATH)
REMOTE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = REMOTE
SPEC.loader.exec_module(REMOTE)


def make_db(path, marker):
    db = sqlite3.connect(path)
    db.executescript(
        """
        CREATE TABLE TB_Workspace (WorkspaceID TEXT, Title TEXT, WorkspaceColor TEXT, DisplayIndex INTEGER);
        CREATE TABLE TB_Channel (ChannelID TEXT, WorkspaceID TEXT, Title TEXT, IsDefault INTEGER, LastMsgTime INTEGER);
        CREATE TABLE TB_Chatroom (ChatroomID TEXT, Title TEXT, ParticipantInfos TEXT, LastMsgBody TEXT, LastMsgTime INTEGER);
        CREATE TABLE TB_KtContact (UserID TEXT, LocalName TEXT, Department TEXT, CompanyName TEXT, Position TEXT);
        CREATE TABLE TB_KmContact (UserID TEXT, LocalName TEXT, Department TEXT, CompanyName TEXT, Position TEXT);
        CREATE TABLE TB_KtMessage (MessageId TEXT, ChannelID TEXT, Content TEXT, MessageType INTEGER, SentTime INTEGER, Sender TEXT, Recalled INTEGER, Deleted INTEGER, ReactionInfo TEXT);
        CREATE TABLE TB_KmMessage (MessageId TEXT, ChatroomId TEXT, Content TEXT, MessageType INTEGER, SentTime INTEGER, Sender TEXT, Recalled INTEGER, DeleteRequesterId TEXT, ReactionInfo TEXT, FileName TEXT);
        """
    )
    db.execute("INSERT INTO TB_Workspace VALUES (?,?,?,?)", ("ws", marker, "#fff", 1))
    db.execute("INSERT INTO TB_Channel VALUES (?,?,?,?,?)", ("channel", "ws", marker, 1, 1000))
    db.execute("INSERT INTO TB_Chatroom VALUES (?,?,?,?,?)", ("room", marker, "[]", marker, 1000))
    db.execute("INSERT INTO TB_KtMessage VALUES (?,?,?,?,?,?,?,?,?)", ("m1", "channel", marker, 0, 1000, "user", 0, 0, ""))
    db.commit()
    db.close()


class RunningServer:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        data_root = root / "data"
        state = root / "state"
        state.mkdir()
        users = {}
        self.passwords = {"alice": "alice-pass", "bob": "bob-pass"}
        self.tokens = {"alice": "alice-upload-token", "bob": "bob-upload-token"}
        for username in ("alice", "bob"):
            data_dir = data_root / username
            data_dir.mkdir(parents=True)
            (data_dir / "thumbs").mkdir()
            make_db(data_dir / "teams-archive.db", username + "-original")
            users[username] = REMOTE.Tenant(
                username=username,
                password_hash=REMOTE.password_hash(self.passwords[username], iterations=200_000),
                upload_token_hash=REMOTE.token_hash(self.tokens[username]),
                data_dir=data_dir,
                my_id=None,
            )
        settings = REMOTE.Settings(
            host="127.0.0.1",
            port=0,
            secure_cookie=False,
            max_upload_bytes=5 * 1024 * 1024,
            state_dir=state,
            tenants=users,
        )
        self.server = REMOTE.RemoteHTTPServer(("127.0.0.1", 0), REMOTE.Handler)
        self.server.app = REMOTE.App(settings)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.port = self.server.server_address[1]

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.tmp.cleanup()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        data = response.read()
        result = (response.status, dict(response.getheaders()), data)
        connection.close()
        return result

    def login(self, username):
        status, _, body = self.request("GET", "/login")
        assert status == 200
        csrf = re.search(rb'name="csrf" value="([^"]+)"', body).group(1).decode()
        form = urllib.parse.urlencode(
            {"username": username, "password": self.passwords[username], "csrf": csrf}
        )
        status, headers, _ = self.request(
            "POST",
            "/login",
            form,
            {"Content-Type": "application/x-www-form-urlencoded", "Content-Length": str(len(form))},
        )
        assert status == 303
        return headers["Set-Cookie"].split(";", 1)[0]


def test_unauthenticated_api_is_rejected():
    server = RunningServer()
    try:
        status, _, body = server.request("GET", "/api/bootstrap")
        assert status == 401
        assert json.loads(body)["error"] == "authentication required"
    finally:
        server.close()


def test_login_and_tenant_data_are_isolated():
    server = RunningServer()
    try:
        alice_cookie = server.login("alice")
        bob_cookie = server.login("bob")
        status, _, alice = server.request("GET", "/api/bootstrap", headers={"Cookie": alice_cookie})
        assert status == 200
        status, _, bob = server.request("GET", "/api/bootstrap", headers={"Cookie": bob_cookie})
        assert status == 200
        assert json.loads(alice)["ws"][0]["t"] == "alice-original"
        assert json.loads(bob)["ws"][0]["t"] == "bob-original"
        assert b"bob-original" not in alice
        assert b"alice-original" not in bob
    finally:
        server.close()


def test_upload_is_authenticated_atomic_and_tenant_scoped():
    server = RunningServer()
    upload_file = Path(server.tmp.name) / "replacement.db"
    bad_file = Path(server.tmp.name) / "bad.db"
    try:
        make_db(upload_file, "alice-new")
        payload = upload_file.read_bytes()
        headers = {
            "X-Teams-Record-User": "alice",
            "Authorization": "Bearer " + server.tokens["alice"],
            "Content-Type": "application/vnd.sqlite3",
            "Content-Length": str(len(payload)),
        }
        status, _, body = server.request("POST", "/api/upload", payload, headers)
        assert status == 200, body
        assert json.loads(body)["ok"] is True

        alice_cookie = server.login("alice")
        bob_cookie = server.login("bob")
        _, _, alice = server.request("GET", "/api/bootstrap", headers={"Cookie": alice_cookie})
        _, _, bob = server.request("GET", "/api/bootstrap", headers={"Cookie": bob_cookie})
        assert json.loads(alice)["ws"][0]["t"] == "alice-new"
        assert json.loads(bob)["ws"][0]["t"] == "bob-original"

        bad_file.write_bytes(b"not sqlite")
        bad = bad_file.read_bytes()
        bad_headers = dict(headers, **{"Content-Length": str(len(bad))})
        status, _, _ = server.request("POST", "/api/upload", bad, bad_headers)
        assert status == 400
        _, _, alice_after = server.request("GET", "/api/bootstrap", headers={"Cookie": alice_cookie})
        assert json.loads(alice_after)["ws"][0]["t"] == "alice-new"

        wrong_headers = dict(headers, Authorization="Bearer wrong")
        status, _, _ = server.request("POST", "/api/upload", payload, wrong_headers)
        assert status == 401
    finally:
        server.close()


def test_remote_mutating_viewer_routes_are_disabled():
    server = RunningServer()
    try:
        cookie = server.login("alice")
        for path in ("/api/refresh", "/api/update"):
            status, _, body = server.request("POST", path, headers={"Cookie": cookie})
            assert status == 403
            assert b"disabled" in body
    finally:
        server.close()
