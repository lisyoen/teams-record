#!/usr/bin/env python3
"""Authenticated multi-tenant remote viewer for teams-record.

The existing viewer remains local-only.  This service imports its read-only
query/UI code once per tenant and adds authentication, tenant isolation and an
atomic HTTPS upload endpoint.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import html
import importlib.util
import json
import os
import re
import secrets
import sqlite3
import tempfile
import threading
import time
from dataclasses import dataclass
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


ROOT = Path(__file__).resolve().parents[1]
VIEWER_SERVER = ROOT / "viewer" / "server.py"
USERNAME_RE = re.compile(r"^[a-zA-Z0-9_.-]{1,64}$")
PBKDF2_ITERATIONS = 600_000
MAX_UPLOAD_DEFAULT = 256 * 1024 * 1024
SESSION_SECONDS = 12 * 60 * 60
LOGIN_TOKEN_SECONDS = 10 * 60
FAILED_WINDOW_SECONDS = 15 * 60
LOCKOUT_SECONDS = 15 * 60
MAX_FAILED_LOGINS = 5
REQUIRED_TABLES = {"TB_KtMessage", "TB_KmMessage", "TB_Channel", "TB_Chatroom"}


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def _unb64(value: str) -> bytes:
    return base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))


def password_hash(password: str, iterations: int = PBKDF2_ITERATIONS) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iterations)
    return f"pbkdf2_sha256${iterations}${_b64(salt)}${_b64(digest)}"


def verify_password(password: str, encoded: str) -> bool:
    try:
        algorithm, rounds, salt, expected = encoded.split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        iterations = int(rounds)
        if iterations < 200_000 or iterations > 5_000_000:
            return False
        actual = hashlib.pbkdf2_hmac(
            "sha256", password.encode("utf-8"), _unb64(salt), iterations
        )
        return hmac.compare_digest(actual, _unb64(expected))
    except (TypeError, ValueError):
        return False


def token_hash(token: str) -> str:
    return "sha256$" + hashlib.sha256(token.encode("utf-8")).hexdigest()


def verify_token(token: str, encoded: str) -> bool:
    if not encoded.startswith("sha256$"):
        return False
    return hmac.compare_digest(token_hash(token), encoded)


def _safe_username(value: str) -> str:
    if not USERNAME_RE.fullmatch(value or ""):
        raise ValueError("invalid username")
    return value


@dataclass(frozen=True)
class Tenant:
    username: str
    password_hash: str
    upload_token_hash: str
    data_dir: Path
    my_id: str | None

    @property
    def database(self) -> Path:
        return self.data_dir / "teams-archive.db"

    @property
    def thumbs(self) -> Path:
        return self.data_dir / "thumbs"


@dataclass(frozen=True)
class Settings:
    host: str
    port: int
    secure_cookie: bool
    max_upload_bytes: int
    state_dir: Path
    tenants: dict[str, Tenant]

    @classmethod
    def load(cls, config_path: Path) -> "Settings":
        mode = config_path.stat().st_mode & 0o777
        if mode & 0o077:
            raise ValueError(f"config must not be group/world accessible: {oct(mode)}")
        raw = json.loads(config_path.read_text(encoding="utf-8"))
        state_dir = Path(raw["stateDir"]).expanduser().resolve()
        data_root = Path(raw["dataRoot"]).expanduser().resolve()
        tenants: dict[str, Tenant] = {}
        for item in raw.get("users", []):
            username = _safe_username(str(item["username"]))
            user_dir = (data_root / username).resolve()
            if data_root != user_dir.parent:
                raise ValueError("tenant data path escaped dataRoot")
            tenants[username] = Tenant(
                username=username,
                password_hash=str(item["passwordHash"]),
                upload_token_hash=str(item["uploadTokenHash"]),
                data_dir=user_dir,
                my_id=(str(item.get("myId") or "").strip() or None),
            )
        if not tenants:
            raise ValueError("at least one user is required")
        for tenant in tenants.values():
            tenant.data_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            tenant.thumbs.mkdir(parents=True, exist_ok=True, mode=0o700)
        state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
        return cls(
            host=str(raw.get("host", "127.0.0.1")),
            port=int(raw.get("port", 9240)),
            secure_cookie=bool(raw.get("secureCookie", True)),
            max_upload_bytes=int(raw.get("maxUploadBytes", MAX_UPLOAD_DEFAULT)),
            state_dir=state_dir,
            tenants=tenants,
        )


class SessionStore:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.Lock()
        with self._connect() as db:
            db.execute(
                "CREATE TABLE IF NOT EXISTS sessions ("
                "token_hash TEXT PRIMARY KEY, username TEXT NOT NULL, csrf TEXT NOT NULL, "
                "created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL)"
            )
            db.execute("CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires_at)")
        os.chmod(path, 0o600)

    def _connect(self):
        db = sqlite3.connect(self.path, timeout=5)
        db.row_factory = sqlite3.Row
        return db

    def create(self, username: str) -> tuple[str, str]:
        raw = secrets.token_urlsafe(32)
        csrf = secrets.token_urlsafe(24)
        now = int(time.time())
        with self.lock, self._connect() as db:
            db.execute("DELETE FROM sessions WHERE expires_at < ?", (now,))
            db.execute(
                "INSERT INTO sessions VALUES (?,?,?,?,?)",
                (token_hash(raw), username, csrf, now, now + SESSION_SECONDS),
            )
        return raw, csrf

    def get(self, raw: str | None):
        if not raw:
            return None
        now = int(time.time())
        with self.lock, self._connect() as db:
            row = db.execute(
                "SELECT username,csrf,expires_at FROM sessions WHERE token_hash=?",
                (token_hash(raw),),
            ).fetchone()
            if not row or row["expires_at"] < now:
                if row:
                    db.execute("DELETE FROM sessions WHERE token_hash=?", (token_hash(raw),))
                return None
            return dict(row)

    def delete(self, raw: str | None):
        if not raw:
            return
        with self.lock, self._connect() as db:
            db.execute("DELETE FROM sessions WHERE token_hash=?", (token_hash(raw),))


class LoginLimiter:
    def __init__(self):
        self.lock = threading.Lock()
        self.failures: dict[tuple[str, str], list[float]] = {}
        self.locked_until: dict[tuple[str, str], float] = {}

    def locked(self, key: tuple[str, str]) -> bool:
        with self.lock:
            return self.locked_until.get(key, 0) > time.time()

    def fail(self, key: tuple[str, str]):
        now = time.time()
        with self.lock:
            values = [x for x in self.failures.get(key, []) if now - x < FAILED_WINDOW_SECONDS]
            values.append(now)
            self.failures[key] = values
            if len(values) >= MAX_FAILED_LOGINS:
                self.locked_until[key] = now + LOCKOUT_SECONDS

    def success(self, key: tuple[str, str]):
        with self.lock:
            self.failures.pop(key, None)
            self.locked_until.pop(key, None)


class ViewerModules:
    def __init__(self):
        self.lock = threading.Lock()
        self.modules = {}

    def get(self, tenant: Tenant):
        with self.lock:
            module = self.modules.get(tenant.username)
            if module is None:
                name = "teams_record_remote_" + hashlib.sha256(
                    tenant.username.encode("utf-8")
                ).hexdigest()[:12]
                spec = importlib.util.spec_from_file_location(name, VIEWER_SERVER)
                module = importlib.util.module_from_spec(spec)
                assert spec and spec.loader
                spec.loader.exec_module(module)
                self.modules[tenant.username] = module
            module.DB = str(tenant.database)
            module.MY_ID = tenant.my_id
            module.THUMBS_DIR = str(tenant.thumbs)
            module._NAME_CACHE = None
            return module


class App:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.sessions = SessionStore(settings.state_dir / "sessions.db")
        self.login_limiter = LoginLimiter()
        self.viewer_modules = ViewerModules()
        self.login_tokens: dict[str, tuple[float, str]] = {}
        self.login_tokens_lock = threading.Lock()

    def new_login_token(self, remote_ip: str) -> str:
        raw = secrets.token_urlsafe(24)
        now = time.time()
        digest = token_hash(raw)
        with self.login_tokens_lock:
            self.login_tokens = {
                key: value for key, value in self.login_tokens.items() if value[0] > now
            }
            self.login_tokens[digest] = (now + LOGIN_TOKEN_SECONDS, remote_ip)
        return raw

    def consume_login_token(self, raw: str, remote_ip: str) -> bool:
        digest = token_hash(raw or "")
        with self.login_tokens_lock:
            value = self.login_tokens.pop(digest, None)
        return bool(value and value[0] >= time.time() and value[1] == remote_ip)


def _remote_page(module, csrf: str, username: str) -> str:
    page = module.PAGE
    remote_css = "<style>.refbtn,.rstat,.versionbar{display:none!important}.remote-user{margin-left:auto;font-size:12px;color:#667}.remote-user form{display:inline}</style>"
    user = html.escape(username)
    logout = (
        f'<div class="remote-user">{user} '
        f'<form method="post" action="/logout"><input type="hidden" name="csrf" value="{html.escape(csrf)}">'
        '<button type="submit">로그아웃</button></form></div>'
    )
    page = page.replace("</head>", remote_css + "</head>")
    page = page.replace("</header>", logout + "</header>", 1)
    page = page.replace("(async()=>{checkUpdate();B=", "(async()=>{B=")
    return page


LOGIN_PAGE = """<!doctype html><html lang="ko"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Teams Record 로그인</title><style>
body{margin:0;background:#f3f5fa;font-family:'Malgun Gothic','Segoe UI',sans-serif;color:#25283b}main{width:min(380px,calc(100% - 40px));margin:12vh auto;background:white;padding:30px;border-radius:14px;box-shadow:0 12px 40px #28305024}h1{font-size:21px;margin:0 0 24px;color:#4b4fa0}label{display:block;font-size:13px;margin:14px 0 6px}input{width:100%;box-sizing:border-box;padding:11px;border:1px solid #cbd1df;border-radius:8px;font-size:15px}button{width:100%;margin-top:22px;padding:12px;border:0;border-radius:8px;background:#5b5fc7;color:white;font-weight:700}.error{background:#fff0f0;color:#b32d2d;padding:9px;border-radius:7px;font-size:13px}</style></head><body><main><h1>Teams Record</h1>__ERROR__<form method="post" action="/login"><input type="hidden" name="csrf" value="__CSRF__"><label>아이디</label><input name="username" autocomplete="username" required><label>비밀번호</label><input type="password" name="password" autocomplete="current-password" required><button type="submit">로그인</button></form></main></body></html>"""


class RemoteHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    server: RemoteHTTPServer

    @property
    def app(self) -> App:
        return self.server.app

    def log_message(self, fmt, *args):
        print("%s - %s" % (self.address_string(), fmt % args), flush=True)

    def _headers(self, content_type: str, length: int, status=200, cookies=()):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'",
        )
        for cookie in cookies:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def _send(self, body, content_type="text/plain; charset=utf-8", status=200, cookies=()):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self._headers(content_type, len(body), status=status, cookies=cookies)
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, value, status=200):
        self._send(
            json.dumps(value, ensure_ascii=False).encode("utf-8"),
            "application/json; charset=utf-8",
            status,
        )

    def _redirect(self, location: str, cookies=()):
        self.send_response(HTTPStatus.SEE_OTHER)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        for cookie in cookies:
            self.send_header("Set-Cookie", cookie)
        self.end_headers()

    def _cookie_value(self, name: str):
        cookie = SimpleCookie()
        try:
            cookie.load(self.headers.get("Cookie", ""))
        except Exception:
            return None
        return cookie[name].value if name in cookie else None

    def _session(self):
        return self.app.sessions.get(self._cookie_value("tr_session"))

    def _client_ip(self):
        forwarded = self.headers.get("CF-Connecting-IP", "").strip()
        return forwarded or self.client_address[0]

    def _read_form(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise ValueError("invalid content length")
        if length < 0 or length > 64 * 1024:
            raise ValueError("form too large")
        return parse_qs(self.rfile.read(length).decode("utf-8", "strict"))

    def _session_cookie(self, token: str, max_age=SESSION_SECONDS):
        secure = "; Secure" if self.app.settings.secure_cookie else ""
        return (
            f"tr_session={token}; Path=/; Max-Age={max_age}; HttpOnly; SameSite=Strict{secure}"
        )

    def _require_session(self):
        session = self._session()
        if not session or session["username"] not in self.app.settings.tenants:
            if self.path.startswith("/api/") or self.path.startswith("/thumb/"):
                self._json({"error": "authentication required"}, 401)
            else:
                self._redirect("/login")
            return None
        return session

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/healthz":
            return self._json({"ok": True})
        if parsed.path == "/login":
            if self._session():
                return self._redirect("/")
            csrf = self.app.new_login_token(self._client_ip())
            page = LOGIN_PAGE.replace("__CSRF__", html.escape(csrf)).replace("__ERROR__", "")
            return self._send(page, "text/html; charset=utf-8")
        session = self._require_session()
        if not session:
            return
        tenant = self.app.settings.tenants[session["username"]]
        if not tenant.database.is_file():
            return self._json({"error": "tenant database has not been uploaded"}, 503)
        module = self.app.viewer_modules.get(tenant)
        try:
            if parsed.path == "/":
                return self._send(
                    _remote_page(module, session["csrf"], tenant.username),
                    "text/html; charset=utf-8",
                )
            if parsed.path == "/api/bootstrap":
                return self._json(module.api_bootstrap())
            if parsed.path == "/api/messages":
                query = parse_qs(parsed.query)
                kind = (query.get("kind") or ["kt"])[0]
                cid = (query.get("id") or [""])[0]
                if kind not in ("kt", "km"):
                    return self._json({"error": "invalid kind"}, 400)
                return self._json(module.api_messages(kind, cid))
            if parsed.path == "/api/search":
                term = (parse_qs(parsed.query).get("q") or [""])[0].strip()
                return self._json(module.api_search(term))
            if parsed.path == "/api/version":
                return self._json({"local": module.LOCAL_VERSION, "latest": None, "update": False})
            if parsed.path == "/api/status":
                stat = tenant.database.stat()
                return self._json({"updatedAt": int(stat.st_mtime), "bytes": stat.st_size})
            if parsed.path == "/favicon.ico":
                return self._send(base64.b64decode(module.FAVICON_ICO_B64), "image/x-icon")
            if parsed.path == "/favicon.svg":
                return self._send(module.FAVICON_SVG, "image/svg+xml")
            if parsed.path.startswith("/thumb/"):
                data, content_type = module.read_thumb(parsed.path[len("/thumb/") :])
                if data is None:
                    return self._json({"error": "not found"}, 404)
                return self._send(data, content_type)
            return self._json({"error": "not found"}, 404)
        except sqlite3.Error as exc:
            return self._json({"error": "database unavailable", "detail": str(exc)[:120]}, 503)

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path == "/login":
            return self._login()
        if parsed.path == "/api/upload":
            return self._upload()
        if parsed.path == "/logout":
            return self._logout()
        if parsed.path in ("/api/refresh", "/api/update"):
            return self._json({"error": "disabled on remote viewer"}, 403)
        return self._json({"error": "not found"}, 404)

    def _login(self):
        try:
            form = self._read_form()
        except (UnicodeError, ValueError):
            return self._json({"error": "invalid form"}, 400)
        username = (form.get("username") or [""])[0].strip()
        password = (form.get("password") or [""])[0]
        csrf = (form.get("csrf") or [""])[0]
        ip = self._client_ip()
        key = (ip, username)
        valid_csrf = self.app.consume_login_token(csrf, ip)
        tenant = self.app.settings.tenants.get(username)
        if self.app.login_limiter.locked(key):
            return self._login_error("잠시 후 다시 시도해 주세요", 429)
        valid = valid_csrf and tenant is not None and verify_password(password, tenant.password_hash)
        if not valid:
            self.app.login_limiter.fail(key)
            time.sleep(0.15)
            return self._login_error("아이디 또는 비밀번호가 올바르지 않습니다", 401)
        self.app.login_limiter.success(key)
        token, _ = self.app.sessions.create(username)
        return self._redirect("/", cookies=(self._session_cookie(token),))

    def _login_error(self, message: str, status: int):
        csrf = self.app.new_login_token(self._client_ip())
        error = '<p class="error">' + html.escape(message) + "</p>"
        page = LOGIN_PAGE.replace("__CSRF__", html.escape(csrf)).replace("__ERROR__", error)
        return self._send(page, "text/html; charset=utf-8", status)

    def _logout(self):
        session = self._session()
        if not session:
            return self._redirect("/login", cookies=(self._session_cookie("", 0),))
        try:
            csrf = (self._read_form().get("csrf") or [""])[0]
        except (UnicodeError, ValueError):
            return self._json({"error": "invalid form"}, 400)
        if not hmac.compare_digest(csrf, session["csrf"]):
            return self._json({"error": "invalid csrf"}, 403)
        self.app.sessions.delete(self._cookie_value("tr_session"))
        return self._redirect("/login", cookies=(self._session_cookie("", 0),))

    def _upload(self):
        username = self.headers.get("X-Teams-Record-User", "").strip()
        tenant = self.app.settings.tenants.get(username)
        authorization = self.headers.get("Authorization", "")
        token = authorization[7:] if authorization.startswith("Bearer ") else ""
        if not tenant or not verify_token(token, tenant.upload_token_hash):
            return self._json({"error": "invalid upload credentials"}, 401)
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type not in ("application/vnd.sqlite3", "application/octet-stream"):
            return self._json({"error": "unsupported content type"}, 415)
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._json({"error": "invalid content length"}, 400)
        if length <= 0 or length > self.app.settings.max_upload_bytes:
            return self._json({"error": "invalid upload size"}, 413)
        temporary = None
        try:
            fd, temporary = tempfile.mkstemp(prefix="upload-", suffix=".db", dir=tenant.data_dir)
            with os.fdopen(fd, "wb") as output:
                remaining = length
                while remaining:
                    chunk = self.rfile.read(min(1024 * 1024, remaining))
                    if not chunk:
                        raise ValueError("short upload")
                    output.write(chunk)
                    remaining -= len(chunk)
                output.flush()
                os.fsync(output.fileno())
            os.chmod(temporary, 0o600)
            _validate_database(Path(temporary))
            os.replace(temporary, tenant.database)
            temporary = None
            _fsync_dir(tenant.data_dir)
            stat = tenant.database.stat()
            return self._json({"ok": True, "bytes": stat.st_size, "updatedAt": int(stat.st_mtime)})
        except (OSError, sqlite3.Error, ValueError) as exc:
            return self._json({"error": "upload rejected", "detail": str(exc)[:160]}, 400)
        finally:
            if temporary:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass


def _validate_database(path: Path):
    with path.open("rb") as source:
        if source.read(16) != b"SQLite format 3\x00":
            raise ValueError("not a SQLite database")
    uri = "file:" + str(path) + "?mode=ro&immutable=1"
    with sqlite3.connect(uri, uri=True, timeout=10) as db:
        result = db.execute("PRAGMA quick_check").fetchone()
        if not result or result[0] != "ok":
            raise ValueError("SQLite quick_check failed")
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        missing = REQUIRED_TABLES - tables
        if missing:
            raise ValueError("required tables missing: " + ",".join(sorted(missing)))


def _fsync_dir(path: Path):
    try:
        descriptor = os.open(path, os.O_RDONLY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    except OSError:
        pass


def serve(config: Path):
    settings = Settings.load(config)
    server = RemoteHTTPServer((settings.host, settings.port), Handler)
    server.app = App(settings)
    print(f"teams-record remote viewer: http://{settings.host}:{settings.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    serve_parser = sub.add_parser("serve")
    serve_parser.add_argument("--config", required=True, type=Path)
    hash_password_parser = sub.add_parser("hash-password")
    hash_password_parser.add_argument("--stdin", action="store_true", required=True)
    hash_token_parser = sub.add_parser("hash-token")
    hash_token_parser.add_argument("--stdin", action="store_true", required=True)
    args = parser.parse_args()
    if args.command == "serve":
        serve(args.config)
    elif args.command == "hash-password":
        print(password_hash(os.sys.stdin.read().rstrip("\r\n")))
    elif args.command == "hash-token":
        print(token_hash(os.sys.stdin.read().rstrip("\r\n")))


if __name__ == "__main__":
    main()
