from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import smtplib
import sqlite3
import ssl
import time
import uuid
from contextlib import contextmanager, asynccontextmanager
from email.message import EmailMessage
from email.utils import formataddr
from pathlib import Path
from typing import Iterator

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
from fastapi import BackgroundTasks, FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from uvicorn.middleware.proxy_headers import ProxyHeadersMiddleware


LOG = logging.getLogger("cwhale.account_api")
PASSWORDS = PasswordHasher()
EMAIL_RE = re.compile(r"^[^\s@]+@[^\s@]+\.[^\s@]+$")
CODE_TTL_SECONDS = 600
RESEND_WAIT_SECONDS = 60
MAX_CODE_ATTEMPTS = 5
REFRESH_TTL_SECONDS = 60 * 60 * 24 * 30
ACCESS_TTL_SECONDS = 900
DUMMY_PASSWORD_HASH = PASSWORDS.hash("not-a-real-password-" + secrets.token_urlsafe(16))


class AuthError(Exception):
    def __init__(
        self,
        status: int,
        code: str,
        message: str,
        challenge_id: str | None = None,
    ) -> None:
        self.status = status
        self.code = code
        self.message = message
        self.challenge_id = challenge_id


class RegisterBody(BaseModel):
    email: str = Field(max_length=254)
    password: str = Field(min_length=8, max_length=128)


class LoginBody(BaseModel):
    email: str = Field(max_length=254)
    password: str = Field(max_length=128)


class ChallengeBody(BaseModel):
    challengeId: str = Field(min_length=16, max_length=128)
    code: str = Field(pattern=r"^\d{6}$")


class ResendBody(BaseModel):
    challengeId: str = Field(min_length=16, max_length=128)


class ResetBody(ChallengeBody):
    newPassword: str = Field(min_length=8, max_length=128)


class EmailBody(BaseModel):
    email: str = Field(max_length=254)


class RefreshBody(BaseModel):
    refreshToken: str = Field(min_length=32, max_length=256)


def _secret() -> bytes:
    value = os.environ.get("CWH_AUTH_SECRET", "")
    if len(value.encode("utf-8")) < 32:
        raise RuntimeError("CWH_AUTH_SECRET must contain at least 32 bytes")
    return value.encode("utf-8")


def _db_path() -> Path:
    return Path(os.environ.get("CWH_AUTH_DB", "/var/lib/cwhale-account/accounts.sqlite3"))


def _now() -> int:
    return int(time.time())


def _email(value: str) -> str:
    normalized = value.strip().lower()
    if len(normalized) > 254 or not EMAIL_RE.fullmatch(normalized):
        raise AuthError(400, "INVALID_EMAIL", "请输入有效的邮箱地址。")
    return normalized


@contextmanager
def _database() -> Iterator[sqlite3.Connection]:
    path = _db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path, timeout=15, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys = ON")
    connection.execute("PRAGMA busy_timeout = 15000")
    try:
        connection.execute("BEGIN IMMEDIATE")
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


def _initialize_database() -> None:
    path = _db_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path, timeout=15) as connection:
        connection.execute("PRAGMA journal_mode = WAL")
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id TEXT PRIMARY KEY,
                email TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                email_verified INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS challenges (
                id TEXT PRIMARY KEY,
                user_id TEXT,
                email TEXT NOT NULL,
                purpose TEXT NOT NULL,
                code_hash TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                sent_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                attempts INTEGER NOT NULL DEFAULT 0,
                consumed_at INTEGER,
                FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS challenges_email_purpose
                ON challenges(email, purpose, created_at DESC);
            CREATE TABLE IF NOT EXISTS refresh_tokens (
                token_hash TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                family_id TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER NOT NULL,
                revoked_at INTEGER,
                replaced_by_hash TEXT,
                FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS refresh_tokens_family ON refresh_tokens(family_id);
            CREATE TABLE IF NOT EXISTS rate_limits (
                key_hash TEXT PRIMARY KEY,
                window_started_at INTEGER NOT NULL,
                attempts INTEGER NOT NULL
            );
            """
        )
        now = int(time.time())
        connection.execute("DELETE FROM challenges WHERE expires_at < ?", (now - CODE_TTL_SECONDS * 3,))
        connection.execute("DELETE FROM rate_limits WHERE window_started_at < ?", (now - 30 * 86400,))
        connection.execute("DELETE FROM refresh_tokens WHERE expires_at < ?", (now - 60 * 86400,))


def _error_response(error: AuthError) -> JSONResponse:
    body: dict[str, object] = {"code": error.code, "message": error.message}
    if error.challenge_id:
        body["challengeId"] = error.challenge_id
    return JSONResponse(body, status_code=error.status, headers={"Cache-Control": "no-store"})


@asynccontextmanager
async def _lifespan(_: FastAPI):
    _secret()
    _initialize_database()
    yield


app = FastAPI(
    title="Cwhale Account API",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=_lifespan,
)
app.add_middleware(ProxyHeadersMiddleware, trusted_hosts="127.0.0.1")


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Referrer-Policy"] = "no-referrer"
    return response


@app.exception_handler(AuthError)
async def handle_auth_error(_: Request, error: AuthError):
    return _error_response(error)


@app.exception_handler(RequestValidationError)
async def handle_validation_error(_: Request, __: RequestValidationError):
    return JSONResponse(
        {"code": "INVALID_REQUEST", "message": "请求信息格式不正确，请检查输入后重试。"},
        status_code=400,
        headers={"Cache-Control": "no-store"},
    )


def _client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _rate_key(category: str, subject: str) -> str:
    return hmac.new(_secret(), f"rate:{category}:{subject}".encode(), hashlib.sha256).hexdigest()


def _limit(category: str, subject: str, maximum: int, window_seconds: int) -> None:
    key = _rate_key(category, subject)
    now = _now()
    retry_after = 0
    with _database() as connection:
        row = connection.execute(
            "SELECT window_started_at, attempts FROM rate_limits WHERE key_hash = ?",
            (key,),
        ).fetchone()
        if row is None or now - row["window_started_at"] >= window_seconds:
            connection.execute(
                "INSERT INTO rate_limits(key_hash, window_started_at, attempts) VALUES (?, ?, 1) "
                "ON CONFLICT(key_hash) DO UPDATE SET window_started_at=excluded.window_started_at, attempts=1",
                (key, now),
            )
        elif row["attempts"] >= maximum:
            retry_after = max(1, window_seconds - (now - row["window_started_at"]))
        else:
            connection.execute(
                "UPDATE rate_limits SET attempts = attempts + 1 WHERE key_hash = ?",
                (key,),
            )
    if retry_after:
        raise AuthError(429, "RATE_LIMITED", f"操作过于频繁，请 {retry_after} 秒后再试。")


def _code_hash(challenge_id: str, code: str) -> str:
    material = f"email-code:{challenge_id}:{code}".encode("utf-8")
    return hmac.new(_secret(), material, hashlib.sha256).hexdigest()


def _create_challenge(
    connection: sqlite3.Connection,
    email: str,
    purpose: str,
    user_id: str | None,
) -> tuple[str, str]:
    challenge_id = secrets.token_urlsafe(24)
    code = f"{secrets.randbelow(1_000_000):06d}"
    now = _now()
    connection.execute(
        "INSERT INTO challenges(id,user_id,email,purpose,code_hash,created_at,sent_at,expires_at) "
        "VALUES(?,?,?,?,?,?,?,?)",
        (
            challenge_id,
            user_id,
            email,
            purpose,
            _code_hash(challenge_id, code),
            now,
            now,
            now + CODE_TTL_SECONDS,
        ),
    )
    return challenge_id, code


def _smtp_settings() -> tuple[str, int, str, str, str, str]:
    host = os.environ.get("CWH_SMTP_HOST", "").strip()
    user = os.environ.get("CWH_SMTP_USER", "").strip()
    password = os.environ.get("CWH_SMTP_PASSWORD", "")
    sender = os.environ.get("CWH_SMTP_FROM", "").strip()
    sender_name = os.environ.get("CWH_SMTP_FROM_NAME", "Cwhale").strip() or "Cwhale"
    try:
        port = int(os.environ.get("CWH_SMTP_PORT", "587"))
    except ValueError:
        port = 0
    if not host or not sender or port < 1 or (user and not password):
        raise AuthError(503, "EMAIL_NOT_CONFIGURED", "邮箱验证码服务尚未配置，请稍后再试。")
    return host, port, user, password, sender, sender_name


def _send_email(email: str, code: str, purpose: str) -> None:
    host, port, user, password, sender, sender_name = _smtp_settings()
    label = "注册验证" if purpose == "register" else "密码重置"
    message = EmailMessage()
    message["Subject"] = f"Cwhale {label}验证码"
    message["From"] = formataddr((sender_name, sender))
    message["To"] = email
    message.set_content(
        f"你的 Cwhale{label}验证码是：{code}\n\n"
        f"验证码 10 分钟内有效。若这不是你的操作，请忽略此邮件。\n"
        "请勿将验证码告诉任何人。"
    )
    context = ssl.create_default_context()
    if port == 465:
        with smtplib.SMTP_SSL(host, port, timeout=15, context=context) as client:
            if user:
                client.login(user, password)
            client.send_message(message)
    else:
        with smtplib.SMTP(host, port, timeout=15) as client:
            client.ehlo()
            client.starttls(context=context)
            client.ehlo()
            if user:
                client.login(user, password)
            client.send_message(message)


async def _send_email_async(email: str, code: str, purpose: str) -> None:
    try:
        await asyncio.to_thread(_send_email, email, code, purpose)
    except AuthError:
        raise
    except Exception as error:
        LOG.warning("Email delivery failed; details withheld (%s)", type(error).__name__)
        raise AuthError(503, "EMAIL_UNAVAILABLE", "验证码邮件暂时发送失败，请稍后重试。") from None


def _send_reset_email_background(email: str, code: str) -> None:
    try:
        _send_email(email, code, "reset")
    except Exception as error:
        LOG.warning("Password reset email delivery failed; details withheld (%s)", type(error).__name__)


def _session_response(connection: sqlite3.Connection, user: sqlite3.Row, family_id: str | None = None) -> dict[str, object]:
    now = _now()
    refresh_token = secrets.token_urlsafe(48)
    refresh_hash = hmac.new(_secret(), f"refresh:{refresh_token}".encode(), hashlib.sha256).hexdigest()
    active_family = family_id or secrets.token_urlsafe(24)
    connection.execute(
        "INSERT INTO refresh_tokens(token_hash,user_id,family_id,created_at,expires_at) VALUES(?,?,?,?,?)",
        (refresh_hash, user["id"], active_family, now, now + REFRESH_TTL_SECONDS),
    )
    header = _b64url(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = _b64url(
        json.dumps(
            {"sub": user["id"], "email": user["email"], "iat": now, "exp": now + ACCESS_TTL_SECONDS},
            separators=(",", ":"),
        ).encode()
    )
    signing_input = f"{header}.{payload}".encode()
    signature = _b64url(hmac.new(_secret(), signing_input, hashlib.sha256).digest())
    return {
        "accessToken": f"{header}.{payload}.{signature}",
        "refreshToken": refresh_token,
        "expiresIn": ACCESS_TTL_SECONDS,
        "user": {
            "id": user["id"],
            "email": user["email"],
            "emailVerified": bool(user["email_verified"]),
        },
    }


def _b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _refresh_hash(token: str) -> str:
    return hmac.new(_secret(), f"refresh:{token}".encode(), hashlib.sha256).hexdigest()


def _verify_code_row(
    connection: sqlite3.Connection,
    challenge_id: str,
    code: str,
    expected_purpose: str,
) -> sqlite3.Row | None:
    row = connection.execute("SELECT * FROM challenges WHERE id = ?", (challenge_id,)).fetchone()
    if (
        row is None
        or row["purpose"] != expected_purpose
        or row["consumed_at"] is not None
        or row["expires_at"] < _now()
        or row["attempts"] >= MAX_CODE_ATTEMPTS
    ):
        return None
    expected_hash = _code_hash(challenge_id, code)
    if not hmac.compare_digest(expected_hash, row["code_hash"]):
        connection.execute("UPDATE challenges SET attempts=attempts+1 WHERE id=?", (challenge_id,))
        return None
    return row


def _challenge_json(challenge_id: str) -> dict[str, object]:
    return {
        "challengeId": challenge_id,
        "retryAfterSeconds": RESEND_WAIT_SECONDS,
        "expiresInSeconds": CODE_TTL_SECONDS,
    }


@app.get("/healthz")
def healthz():
    with _database() as connection:
        connection.execute("SELECT 1").fetchone()
    return {"status": "ok"}


@app.post("/v1/auth/register")
async def register(body: RegisterBody, request: Request):
    email = _email(body.email)
    _smtp_settings()
    _limit("register-ip", _client_ip(request), 10, 3600)
    _limit("register-email", email, 5, 3600)
    password_hash = PASSWORDS.hash(body.password)
    now = _now()
    with _database() as connection:
        user = connection.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
        if user and user["email_verified"]:
            raise AuthError(409, "EMAIL_ALREADY_EXISTS", "该邮箱已注册，请直接登录或找回密码。")
        if user:
            user_id = user["id"]
            connection.execute(
                "UPDATE users SET password_hash=?,updated_at=? WHERE id=?",
                (password_hash, now, user_id),
            )
        else:
            user_id = str(uuid.uuid4())
            connection.execute(
                "INSERT INTO users(id,email,password_hash,email_verified,created_at,updated_at) VALUES(?,?,?,0,?,?)",
                (user_id, email, password_hash, now, now),
            )
        connection.execute(
            "UPDATE challenges SET consumed_at=? WHERE email=? AND purpose='register' AND consumed_at IS NULL",
            (now, email),
        )
        challenge_id, code = _create_challenge(connection, email, "register", user_id)
    await _send_email_async(email, code, "register")
    return _challenge_json(challenge_id)


@app.post("/v1/auth/email/verify")
def verify_email(body: ChallengeBody):
    with _database() as connection:
        challenge = _verify_code_row(connection, body.challengeId, body.code, "register")
        user = None if challenge is None else connection.execute(
            "SELECT * FROM users WHERE id=?", (challenge["user_id"],)
        ).fetchone()
        if challenge is not None and user is not None:
            now = _now()
            connection.execute("UPDATE users SET email_verified=1,updated_at=? WHERE id=?", (now, user["id"]))
            connection.execute(
                "UPDATE challenges SET consumed_at=? WHERE email=? AND purpose='register' AND consumed_at IS NULL",
                (now, user["email"]),
            )
            user = connection.execute("SELECT * FROM users WHERE id=?", (user["id"],)).fetchone()
            session = _session_response(connection, user)
        else:
            session = None
    if session is None:
        raise AuthError(400, "INVALID_CODE", "验证码不正确或已过期。")
    return session


@app.post("/v1/auth/email/resend")
async def resend_email(body: ResendBody, request: Request):
    challenge_id = body.challengeId
    _smtp_settings()
    _limit("resend-ip", _client_ip(request), 15, 3600)
    now = _now()
    with _database() as connection:
        row = connection.execute("SELECT * FROM challenges WHERE id=?", (challenge_id,)).fetchone()
        if row is None or row["purpose"] != "register" or row["consumed_at"] is not None:
            raise AuthError(400, "INVALID_CHALLENGE", "验证码请求已失效，请重新注册。")
        wait = RESEND_WAIT_SECONDS - (now - row["sent_at"])
        if wait > 0:
            raise AuthError(429, "RATE_LIMITED", f"请 {wait} 秒后重新发送验证码。")
        code = f"{secrets.randbelow(1_000_000):06d}"
        connection.execute(
            "UPDATE challenges SET code_hash=?,sent_at=?,expires_at=?,attempts=0 WHERE id=?",
            (_code_hash(challenge_id, code), now, now + CODE_TTL_SECONDS, challenge_id),
        )
        email = row["email"]
    await _send_email_async(email, code, "register")
    return {"retryAfterSeconds": RESEND_WAIT_SECONDS, "expiresInSeconds": CODE_TTL_SECONDS}


@app.post("/v1/auth/login")
async def login(body: LoginBody, request: Request):
    email = _email(body.email)
    _limit("login-ip", _client_ip(request), 40, 900)
    _limit("login-email", email, 15, 900)
    with _database() as connection:
        user = connection.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
    hash_to_check = user["password_hash"] if user else DUMMY_PASSWORD_HASH
    try:
        password_ok = PASSWORDS.verify(hash_to_check, body.password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        password_ok = False
    if user is None or not password_ok:
        raise AuthError(401, "INVALID_CREDENTIALS", "邮箱或密码不正确。")
    if not user["email_verified"]:
        _smtp_settings()
        with _database() as connection:
            connection.execute(
                "UPDATE challenges SET consumed_at=? WHERE email=? AND purpose='register' AND consumed_at IS NULL",
                (_now(), email),
            )
            challenge_id, code = _create_challenge(connection, email, "register", user["id"])
        await _send_email_async(email, code, "register")
        raise AuthError(403, "EMAIL_NOT_VERIFIED", "邮箱尚未验证，请输入邮件中的验证码。", challenge_id)
    with _database() as connection:
        current_user = connection.execute("SELECT * FROM users WHERE id=?", (user["id"],)).fetchone()
        return _session_response(connection, current_user)


@app.post("/v1/auth/password-reset/request")
async def request_password_reset(body: EmailBody, request: Request, background_tasks: BackgroundTasks):
    email = _email(body.email)
    _limit("reset-ip", _client_ip(request), 10, 3600)
    _limit("reset-email", email, 5, 3600)
    with _database() as connection:
        user = connection.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()
        user_id = user["id"] if user and user["email_verified"] else None
        connection.execute(
            "UPDATE challenges SET consumed_at=? WHERE email=? AND purpose='reset' AND consumed_at IS NULL",
            (_now(), email),
        )
        challenge_id, code = _create_challenge(connection, email, "reset", user_id)
    if user_id is not None:
        background_tasks.add_task(_send_reset_email_background, email, code)
    return _challenge_json(challenge_id)


@app.post("/v1/auth/password-reset/resend")
async def resend_password_reset(body: dict, request: Request, background_tasks: BackgroundTasks):
    challenge_id = str(body.get("challengeId", ""))[:128]
    _limit("reset-resend-ip", _client_ip(request), 10, 3600)
    now = _now()
    with _database() as connection:
        row = connection.execute("SELECT * FROM challenges WHERE id=?", (challenge_id,)).fetchone()
        if row is None or row["purpose"] != "reset" or row["consumed_at"] is not None:
            raise AuthError(400, "INVALID_CHALLENGE", "验证码请求已失效，请重新提交。")
        wait = RESEND_WAIT_SECONDS - (now - row["sent_at"])
        if wait > 0:
            raise AuthError(429, "RATE_LIMITED", f"请 {wait} 秒后重新发送验证码。")
        code = f"{secrets.randbelow(1_000_000):06d}"
        connection.execute(
            "UPDATE challenges SET code_hash=?,sent_at=?,expires_at=?,attempts=0 WHERE id=?",
            (_code_hash(challenge_id, code), now, now + CODE_TTL_SECONDS, challenge_id),
        )
        email = row["email"]
        should_send = row["user_id"] is not None
    if should_send:
        background_tasks.add_task(_send_reset_email_background, email, code)
    return {"retryAfterSeconds": RESEND_WAIT_SECONDS, "expiresInSeconds": CODE_TTL_SECONDS}


@app.post("/v1/auth/password-reset/confirm")
def confirm_password_reset(body: ResetBody):
    password_hash = PASSWORDS.hash(body.newPassword)
    with _database() as connection:
        challenge = _verify_code_row(connection, body.challengeId, body.code, "reset")
        user_id = challenge["user_id"] if challenge is not None else None
        if user_id is not None:
            now = _now()
            connection.execute("UPDATE users SET password_hash=?,updated_at=? WHERE id=?", (password_hash, now, user_id))
            connection.execute("UPDATE refresh_tokens SET revoked_at=? WHERE user_id=? AND revoked_at IS NULL", (now, user_id))
            connection.execute(
                "UPDATE challenges SET consumed_at=? WHERE email=(SELECT email FROM users WHERE id=?) AND purpose='reset' AND consumed_at IS NULL",
                (now, user_id),
            )
    if user_id is None:
        raise AuthError(400, "INVALID_CODE", "验证码不正确或已过期。")
    return {"success": True}


@app.post("/v1/auth/token/refresh")
def refresh(body: RefreshBody):
    token_hash = _refresh_hash(body.refreshToken)
    now = _now()
    error = None
    session = None
    with _database() as connection:
        row = connection.execute("SELECT * FROM refresh_tokens WHERE token_hash=?", (token_hash,)).fetchone()
        if row is None:
            error = AuthError(401, "UNAUTHORIZED", "登录状态已失效，请重新登录。")
        elif row["revoked_at"] is not None:
            connection.execute(
                "UPDATE refresh_tokens SET revoked_at=? WHERE family_id=? AND revoked_at IS NULL",
                (now, row["family_id"]),
            )
            error = AuthError(401, "TOKEN_REVOKED", "登录状态已失效，请重新登录。")
        elif row["expires_at"] <= now:
            connection.execute("UPDATE refresh_tokens SET revoked_at=? WHERE token_hash=?", (now, token_hash))
            error = AuthError(401, "UNAUTHORIZED", "登录状态已过期，请重新登录。")
        else:
            user = connection.execute("SELECT * FROM users WHERE id=?", (row["user_id"],)).fetchone()
            if user is None or not user["email_verified"]:
                error = AuthError(401, "UNAUTHORIZED", "登录状态已失效，请重新登录。")
            else:
                session = _session_response(connection, user, row["family_id"])
                replacement_hash = _refresh_hash(str(session["refreshToken"]))
                connection.execute(
                    "UPDATE refresh_tokens SET revoked_at=?,replaced_by_hash=? WHERE token_hash=?",
                    (now, replacement_hash, token_hash),
                )
    if error is not None:
        raise error
    assert session is not None
    return session


@app.post("/v1/auth/logout")
def logout(body: RefreshBody):
    with _database() as connection:
        connection.execute(
            "UPDATE refresh_tokens SET revoked_at=? WHERE token_hash=? AND revoked_at IS NULL",
            (_now(), _refresh_hash(body.refreshToken)),
        )
    return {"success": True}
