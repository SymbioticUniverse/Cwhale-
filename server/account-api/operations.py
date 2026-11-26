"""Account-scoped notifications, gifted model entitlements, and admin API."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Literal
from urllib.parse import urlsplit, urlunsplit

from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi import APIRouter, Header, HTTPException, Query
from pydantic import BaseModel, Field


router = APIRouter(tags=["notifications-and-gifted-models"])
_secret_provider = None
_db_path_provider = None
_user_resolver = None


def configure(secret_provider, db_path_provider, user_resolver) -> None:
    global _secret_provider, _db_path_provider, _user_resolver
    _secret_provider = secret_provider
    _db_path_provider = db_path_provider
    _user_resolver = user_resolver


def _now() -> int:
    return int(time.time())


@contextmanager
def _database() -> Iterator[sqlite3.Connection]:
    if _db_path_provider is None:
        raise RuntimeError("operations API is not configured")
    path = Path(_db_path_provider())
    path.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(path, timeout=15, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA busy_timeout=15000")
    try:
        connection.execute("BEGIN IMMEDIATE")
        yield connection
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


@contextmanager
def _read_database() -> Iterator[sqlite3.Connection]:
    if _db_path_provider is None:
        raise RuntimeError("operations API is not configured")
    connection = sqlite3.connect(Path(_db_path_provider()), timeout=15)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys=ON")
    try:
        yield connection
    finally:
        connection.close()


def initialize(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path, timeout=15) as connection:
        connection.execute("PRAGMA journal_mode=WAL")
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS notifications (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                body TEXT NOT NULL,
                category TEXT NOT NULL,
                audience TEXT NOT NULL,
                action TEXT NOT NULL DEFAULT 'none',
                action_value TEXT NOT NULL DEFAULT '',
                status TEXT NOT NULL,
                created_by TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                published_at INTEGER,
                expires_at INTEGER
            );
            CREATE INDEX IF NOT EXISTS notifications_visible
                ON notifications(status, published_at, expires_at);
            CREATE TABLE IF NOT EXISTS notification_recipients (
                notification_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                read_at INTEGER,
                PRIMARY KEY(notification_id,user_id),
                FOREIGN KEY(notification_id) REFERENCES notifications(id) ON DELETE CASCADE,
                FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS notification_recipients_user
                ON notification_recipients(user_id,notification_id);
            CREATE TABLE IF NOT EXISTS notification_reads (
                notification_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                read_at INTEGER NOT NULL,
                PRIMARY KEY(notification_id,user_id),
                FOREIGN KEY(notification_id) REFERENCES notifications(id) ON DELETE CASCADE,
                FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS gray_models (
                model_id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                upstream_model TEXT NOT NULL,
                context_window_tokens INTEGER NOT NULL DEFAULT 128000,
                supports_thinking_toggle INTEGER NOT NULL DEFAULT 0,
                supports_thinking_levels INTEGER NOT NULL DEFAULT 0,
                supports_images INTEGER NOT NULL DEFAULT 0,
                supports_files INTEGER NOT NULL DEFAULT 0,
                enabled INTEGER NOT NULL DEFAULT 1,
                config_cipher TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS gray_entitlements (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                model_id TEXT NOT NULL,
                quota_tokens INTEGER NOT NULL,
                used_tokens INTEGER NOT NULL DEFAULT 0,
                reserved_tokens INTEGER NOT NULL DEFAULT 0,
                created_by TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                expires_at INTEGER,
                revoked_at INTEGER,
                FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE,
                FOREIGN KEY(model_id) REFERENCES gray_models(model_id)
            );
            CREATE INDEX IF NOT EXISTS gray_entitlements_user
                ON gray_entitlements(user_id,revoked_at,expires_at);
            CREATE TABLE IF NOT EXISTS gray_token_ledger (
                id TEXT PRIMARY KEY,
                entitlement_id TEXT NOT NULL,
                user_id TEXT NOT NULL,
                request_id TEXT NOT NULL,
                kind TEXT NOT NULL,
                amount INTEGER NOT NULL,
                details TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                UNIQUE(entitlement_id,request_id,kind),
                FOREIGN KEY(entitlement_id) REFERENCES gray_entitlements(id) ON DELETE CASCADE,
                FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
            );
            CREATE TABLE IF NOT EXISTS admin_audit (
                id TEXT PRIMARY KEY,
                admin_user_id TEXT NOT NULL,
                action TEXT NOT NULL,
                object_id TEXT NOT NULL,
                details TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                FOREIGN KEY(admin_user_id) REFERENCES users(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS admin_audit_created ON admin_audit(created_at DESC);
            """
        )
        model_columns = {row[1] for row in connection.execute("PRAGMA table_info(gray_models)")}
        for name in ("supports_thinking_toggle", "supports_thinking_levels", "supports_images", "supports_files"):
            if name not in model_columns:
                connection.execute(f"ALTER TABLE gray_models ADD COLUMN {name} INTEGER NOT NULL DEFAULT 0")


def _admin(authorization: str | None) -> tuple[str, str]:
    if _user_resolver is None:
        raise HTTPException(503, "管理接口暂不可用。")
    user_id = _user_resolver(authorization)
    with _read_database() as connection:
        row = connection.execute("SELECT email FROM users WHERE id=?", (user_id,)).fetchone()
    if row is None:
        raise HTTPException(401, "登录状态已失效，请重新登录。")
    allowlist = {
        item.strip().lower()
        for item in os.environ.get("CWH_ADMIN_EMAILS", "").split(",")
        if item.strip()
    }
    if not allowlist or str(row["email"]).lower() not in allowlist:
        raise HTTPException(403, "当前账号没有工作台管理权限。")
    return user_id, str(row["email"])


def _authenticated_user(authorization: str | None) -> str:
    if _user_resolver is None:
        raise HTTPException(503, "账号服务暂不可用。")
    return _user_resolver(authorization)


def _config_cipher() -> AESGCM:
    if _secret_provider is None:
        raise RuntimeError("operations API is not configured")
    key = hmac.new(_secret_provider(), b"cwhale-gray-model-config-v1", hashlib.sha256).digest()
    return AESGCM(key)


def _encrypt_config(value: dict[str, Any]) -> str:
    nonce = secrets.token_bytes(12)
    raw = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    encrypted = _config_cipher().encrypt(nonce, raw, b"cwhale-gray-model-v1")
    return base64.urlsafe_b64encode(nonce + encrypted).decode("ascii")


def _decrypt_config(value: str) -> dict[str, Any]:
    raw = base64.urlsafe_b64decode(value.encode("ascii"))
    plain = _config_cipher().decrypt(raw[:12], raw[12:], b"cwhale-gray-model-v1")
    decoded = json.loads(plain.decode("utf-8"))
    if not isinstance(decoded, dict):
        raise ValueError("invalid model config")
    return decoded


def _audit(connection: sqlite3.Connection, admin_id: str, action: str, object_id: str, details: dict[str, Any]) -> None:
    connection.execute(
        "INSERT INTO admin_audit(id,admin_user_id,action,object_id,details,created_at) VALUES(?,?,?,?,?,?)",
        (str(uuid.uuid4()), admin_id, action, object_id, json.dumps(details, ensure_ascii=False), _now()),
    )


class NotificationBody(BaseModel):
    title: str = Field(min_length=1, max_length=120)
    body: str = Field(min_length=1, max_length=5000)
    category: Literal["activity", "update", "gray_test", "quota", "general"] = "general"
    audience: Literal["global", "targeted"]
    userIds: list[str] = Field(default_factory=list, max_length=5000)
    action: Literal["none", "models", "quota", "activity", "updates"] = "none"
    actionValue: str = Field(default="", max_length=256)
    expiresAt: int | None = None
    publish: bool = True


class ModelBody(BaseModel):
    modelId: str = Field(pattern=r"^[A-Za-z0-9_.:-]{1,96}$")
    displayName: str = Field(min_length=1, max_length=120)
    upstreamModel: str = Field(min_length=1, max_length=256)
    upstreamBaseUrl: str = Field(min_length=8, max_length=2048)
    apiKey: str | None = Field(default=None, min_length=1, max_length=4096)
    contextWindowTokens: int = Field(default=128000, ge=16000, le=2_000_000)
    supportsThinkingToggle: bool = False
    supportsThinkingLevels: bool = False
    supportsImages: bool = False
    supportsFiles: bool = False
    enabled: bool = True


class GrantBody(BaseModel):
    userId: str = Field(min_length=1, max_length=128)
    modelId: str = Field(min_length=1, max_length=96)
    quotaTokens: int = Field(ge=1, le=100_000_000)
    expiresAt: int | None = None


class ModelEnabledBody(BaseModel):
    enabled: bool


def reserve_entitlement(
    connection: sqlite3.Connection,
    user_id: str,
    entitlement_id: str,
    request_id: str,
    request_body: dict[str, Any],
) -> tuple[dict[str, Any], int]:
    now = _now()
    row = connection.execute(
        "SELECT e.*,m.display_name,m.upstream_model,m.context_window_tokens,m.enabled,m.config_cipher "
        "FROM gray_entitlements e JOIN gray_models m ON m.model_id=e.model_id "
        "WHERE e.id=? AND e.user_id=?",
        (entitlement_id, user_id),
    ).fetchone()
    if row is None or row["revoked_at"] is not None or not row["enabled"] or (row["expires_at"] is not None and row["expires_at"] <= now):
        raise HTTPException(403, "该灰度模型资格已失效，请重新选择模型。")
    available = int(row["quota_tokens"] - row["used_tokens"] - row["reserved_tokens"])
    if available <= 0:
        raise HTTPException(402, "该模型的赠与额度已用完。")
    request_body = json.loads(json.dumps(request_body))
    request_body["model"] = row["upstream_model"]
    message_payload = json.dumps(request_body.get("messages", []), ensure_ascii=False, separators=(",", ":"))
    estimated_input = max(1, (len(message_payload) * 3 + 1) // 2)
    if estimated_input >= available:
        raise HTTPException(402, "剩余额度不足以发送本次上下文。")
    max_output = request_body.get("max_tokens")
    if not isinstance(max_output, int) or max_output <= 0:
        max_output = min(2048, available - estimated_input)
    max_output = min(max_output, available - estimated_input)
    if max_output < 1:
        raise HTTPException(402, "赠与额度不足以生成回复。")
    request_body["max_tokens"] = max_output
    reservation = estimated_input + max_output
    config = _decrypt_config(row["config_cipher"])
    connection.execute(
        "UPDATE gray_entitlements SET reserved_tokens=reserved_tokens+? WHERE id=?",
        (reservation, entitlement_id),
    )
    connection.execute(
        "INSERT INTO gray_token_ledger(id,entitlement_id,user_id,request_id,kind,amount,details,created_at) VALUES(?,?,?,?,?,?,?,?)",
        (str(uuid.uuid4()), entitlement_id, user_id, request_id, "reserve", reservation, "预留输入估算与最大输出额度", now),
    )
    return ({"upstreamUrl": config["upstreamUrl"], "apiKey": config["apiKey"], "requestBody": request_body}, reservation)


def resolve_entitlement_route(user_id: str, entitlement_id: str) -> dict[str, Any]:
    with _read_database() as connection:
        row = connection.execute(
            "SELECT e.revoked_at,e.expires_at,m.enabled,m.upstream_model,m.config_cipher "
            "FROM gray_entitlements e JOIN gray_models m ON m.model_id=e.model_id WHERE e.id=? AND e.user_id=?",
            (entitlement_id, user_id),
        ).fetchone()
    if row is None or row["revoked_at"] is not None or not row["enabled"] or (row["expires_at"] is not None and row["expires_at"] <= _now()):
        raise HTTPException(403, "该灰度模型资格已失效，请重新选择模型。")
    config = _decrypt_config(row["config_cipher"])
    return {"upstreamUrl": config["upstreamUrl"], "upstreamModel": row["upstream_model"]}


def entitlement_active(user_id: str, entitlement_id: str) -> bool:
    with _read_database() as connection:
        row = connection.execute(
            "SELECT e.revoked_at,e.expires_at,m.enabled FROM gray_entitlements e JOIN gray_models m ON m.model_id=e.model_id WHERE e.id=? AND e.user_id=?",
            (entitlement_id, user_id),
        ).fetchone()
    return bool(row is not None and row["revoked_at"] is None and row["enabled"] and (row["expires_at"] is None or row["expires_at"] > _now()))


def settle_entitlement(
    connection: sqlite3.Connection,
    task_id: str,
    entitlement_id: str,
    user_id: str,
    reservation: int,
    actual_tokens: int | None,
    details: str,
) -> None:
    already = connection.execute(
        "SELECT 1 FROM gray_token_ledger WHERE entitlement_id=? AND request_id=? AND kind IN ('settle','release') LIMIT 1",
        (entitlement_id, task_id),
    ).fetchone()
    if already:
        return
    used = max(0, min(int(actual_tokens), 100_000_000)) if actual_tokens is not None else 0
    connection.execute(
        "UPDATE gray_entitlements SET reserved_tokens=MAX(0,reserved_tokens-?),used_tokens=used_tokens+? WHERE id=? AND user_id=?",
        (reservation, used, entitlement_id, user_id),
    )
    connection.execute(
        "INSERT INTO gray_token_ledger(id,entitlement_id,user_id,request_id,kind,amount,details,created_at) VALUES(?,?,?,?,?,?,?,?)",
        (str(uuid.uuid4()), entitlement_id, user_id, task_id, "settle" if used else "release", used if used else -reservation, details[:500], _now()),
    )


@router.get("/v1/notifications")
def list_notifications(
    authorization: str | None = Header(default=None),
    limit: int = Query(default=100, ge=1, le=200),
):
    user_id = None
    if authorization:
        user_id = _authenticated_user(authorization)
    now = _now()
    with _read_database() as connection:
        if user_id:
            rows = connection.execute(
                "SELECT n.*,CASE WHEN n.audience='targeted' THEN r.read_at ELSE rd.read_at END AS read_at "
                "FROM notifications n LEFT JOIN notification_recipients r ON r.notification_id=n.id AND r.user_id=? "
                "LEFT JOIN notification_reads rd ON rd.notification_id=n.id AND rd.user_id=? "
                "WHERE n.status='published' AND (n.expires_at IS NULL OR n.expires_at>?) "
                "AND (n.audience='global' OR r.user_id IS NOT NULL) ORDER BY n.published_at DESC LIMIT ?",
                (user_id, user_id, now, limit),
            ).fetchall()
        else:
            rows = connection.execute(
                "SELECT n.*,NULL AS read_at FROM notifications n WHERE n.status='published' AND n.audience='global' "
                "AND (n.expires_at IS NULL OR n.expires_at>?) ORDER BY n.published_at DESC LIMIT ?",
                (now, limit),
            ).fetchall()
    items = [dict(row) for row in rows]
    for item in items:
        item["isRead"] = item.get("read_at") is not None
        item.pop("read_at", None)
    return {"items": items, "unreadCount": sum(1 for item in items if not item["isRead"])}


@router.post("/v1/notifications/{notification_id}/read")
def mark_notification_read(notification_id: str, authorization: str | None = Header(default=None)):
    user_id = _authenticated_user(authorization)
    now = _now()
    with _database() as connection:
        row = connection.execute(
            "SELECT audience,status FROM notifications WHERE id=?", (notification_id,)
        ).fetchone()
        if row is None or row["status"] != "published":
            raise HTTPException(404, "找不到该通知。")
        if row["audience"] == "targeted":
            changed = connection.execute(
                "UPDATE notification_recipients SET read_at=COALESCE(read_at,?) WHERE notification_id=? AND user_id=?",
                (now, notification_id, user_id),
            ).rowcount
            if not changed:
                raise HTTPException(404, "找不到该通知。")
        else:
            connection.execute(
                "INSERT INTO notification_reads(notification_id,user_id,read_at) VALUES(?,?,?) ON CONFLICT(notification_id,user_id) DO NOTHING",
                (notification_id, user_id, now),
            )
    return {"success": True}


@router.get("/v1/me/gray-models")
def list_my_gray_models(authorization: str | None = Header(default=None)):
    user_id = _authenticated_user(authorization)
    now = _now()
    with _read_database() as connection:
        rows = connection.execute(
            "SELECT e.id AS entitlementId,e.model_id AS modelId,m.display_name AS displayName,"
            "m.context_window_tokens AS contextWindowTokens,e.quota_tokens AS quotaTokens,e.used_tokens AS usedTokens,"
            "e.reserved_tokens AS reservedTokens,e.expires_at AS expiresAt,"
            "m.supports_thinking_toggle AS supportsThinkingToggle,m.supports_thinking_levels AS supportsThinkingLevels,"
            "m.supports_images AS supportsImages,m.supports_files AS supportsFiles "
            "FROM gray_entitlements e JOIN gray_models m ON m.model_id=e.model_id "
            "WHERE e.user_id=? AND e.revoked_at IS NULL AND m.enabled=1 AND (e.expires_at IS NULL OR e.expires_at>?) "
            "ORDER BY e.created_at DESC",
            (user_id, now),
        ).fetchall()
    return {
        "items": [
            {
                **dict(row),
                "remainingTokens": max(0, row["quotaTokens"] - row["usedTokens"] - row["reservedTokens"]),
                "executionMode": "server",
            }
            for row in rows
        ]
    }


@router.get("/v1/admin/users")
def admin_users(q: str = Query(min_length=2, max_length=254), authorization: str | None = Header(default=None)):
    admin_id, _ = _admin(authorization)
    query = f"%{q.strip().lower()}%"
    with _read_database() as connection:
        rows = connection.execute(
            "SELECT id,email,email_verified,created_at FROM users WHERE lower(email) LIKE ? ORDER BY email LIMIT 100",
            (query,),
        ).fetchall()
    return {"items": [dict(row) for row in rows], "queriedBy": admin_id}


@router.get("/v1/admin/notifications")
def admin_list_notifications(authorization: str | None = Header(default=None)):
    _admin(authorization)
    with _read_database() as connection:
        rows = connection.execute(
            "SELECT n.*,COUNT(r.user_id) AS recipient_count FROM notifications n "
            "LEFT JOIN notification_recipients r ON r.notification_id=n.id "
            "GROUP BY n.id ORDER BY n.created_at DESC LIMIT 200"
        ).fetchall()
    return {"items": [dict(row) for row in rows]}


@router.post("/v1/admin/notifications")
def create_notification(body: NotificationBody, authorization: str | None = Header(default=None)):
    admin_id, _ = _admin(authorization)
    if body.category in {"gray_test", "quota"} and body.audience != "targeted":
        raise HTTPException(400, "灰度测试和个人额度通知必须指定目标账号。")
    if body.audience == "targeted" and not body.userIds:
        raise HTTPException(400, "定向通知至少需要一个目标账号。")
    if body.audience == "global" and body.userIds:
        raise HTTPException(400, "全域通知不能附带账号名单。")
    allowed_actions = {"none", "models", "quota", "activity", "updates"}
    if body.action not in allowed_actions:
        raise HTTPException(400, "通知跳转类型不受支持。")
    if body.action == "activity":
        action_url = urlsplit(body.actionValue.strip())
        if action_url.scheme != "https" or not action_url.hostname or action_url.username or action_url.password:
            raise HTTPException(400, "活动链接必须是无凭据的 HTTPS 地址。")
    notification_id = str(uuid.uuid4())
    now = _now()
    published_at = now if body.publish else None
    status = "published" if body.publish else "draft"
    with _database() as connection:
        target_ids = list(dict.fromkeys(body.userIds))
        if target_ids:
            placeholders = ",".join("?" for _ in target_ids)
            existing = connection.execute(
                f"SELECT id FROM users WHERE email_verified=1 AND id IN ({placeholders})", target_ids
            ).fetchall()
            if len(existing) != len(target_ids):
                raise HTTPException(400, "部分目标账号不存在或未完成邮箱验证。")
        connection.execute(
            "INSERT INTO notifications(id,title,body,category,audience,action,action_value,status,created_by,created_at,published_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            (notification_id, body.title.strip(), body.body.strip(), body.category, body.audience, body.action, body.actionValue.strip(), status, admin_id, now, published_at, body.expiresAt),
        )
        if body.audience == "targeted":
            connection.executemany(
                "INSERT INTO notification_recipients(notification_id,user_id) VALUES(?,?)",
                [(notification_id, user_id) for user_id in target_ids],
            )
        _audit(connection, admin_id, "notification.create", notification_id, {"audience": body.audience, "category": body.category, "targetCount": len(target_ids), "status": status})
    return {"id": notification_id, "status": status, "targetCount": len(body.userIds)}


@router.post("/v1/admin/notifications/{notification_id}/revoke")
def revoke_notification(notification_id: str, authorization: str | None = Header(default=None)):
    admin_id, _ = _admin(authorization)
    with _database() as connection:
        changed = connection.execute(
            "UPDATE notifications SET status='revoked' WHERE id=? AND status IN ('published','draft')",
            (notification_id,),
        ).rowcount
        if not changed:
            raise HTTPException(404, "找不到可撤回的通知。")
        _audit(connection, admin_id, "notification.revoke", notification_id, {})
    return {"success": True}


@router.get("/v1/admin/models")
def admin_models(authorization: str | None = Header(default=None)):
    _admin(authorization)
    with _read_database() as connection:
        rows = connection.execute(
            "SELECT model_id AS modelId,display_name AS displayName,upstream_model AS upstreamModel,context_window_tokens AS contextWindowTokens,supports_thinking_toggle AS supportsThinkingToggle,supports_thinking_levels AS supportsThinkingLevels,supports_images AS supportsImages,supports_files AS supportsFiles,enabled,config_cipher,created_at AS createdAt,updated_at AS updatedAt FROM gray_models ORDER BY display_name"
        ).fetchall()
    items = []
    for row in rows:
        item = dict(row)
        try:
            upstream_url = urlsplit(_decrypt_config(item.pop("config_cipher"))["upstreamUrl"])
            path = upstream_url.path.rstrip("/")
            if path.endswith("/chat/completions"):
                path = path[:-len("/chat/completions")]
            item["upstreamBaseUrl"] = urlunsplit(("https", upstream_url.netloc, path, "", ""))
        except Exception:
            item.pop("config_cipher", None)
            item["upstreamBaseUrl"] = ""
        items.append(item)
    return {"items": items}


@router.put("/v1/admin/models")
def save_model(body: ModelBody, authorization: str | None = Header(default=None)):
    admin_id, _ = _admin(authorization)
    parsed = urlsplit(body.upstreamBaseUrl.strip())
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise HTTPException(400, "模型服务地址必须是无凭据、无查询参数的 HTTPS 地址。")
    path = parsed.path.rstrip("/")
    if not path.endswith("/chat/completions"):
        path += "/chat/completions"
    upstream_url = urlunsplit(("https", parsed.netloc, path, "", ""))
    with _database() as connection:
        previous = connection.execute("SELECT config_cipher FROM gray_models WHERE model_id=?", (body.modelId,)).fetchone()
        api_key = body.apiKey.strip() if body.apiKey else ""
        if not api_key and previous is not None:
            try:
                api_key = _decrypt_config(previous["config_cipher"])["apiKey"]
            except Exception:
                raise HTTPException(500, "现有模型凭据无法读取，请重新填写密钥。") from None
        if not api_key:
            raise HTTPException(400, "新模型必须配置服务端 API Key。")
        cipher = _encrypt_config({"upstreamUrl": upstream_url, "apiKey": api_key})
        now = _now()
        connection.execute(
            "INSERT INTO gray_models(model_id,display_name,upstream_model,context_window_tokens,supports_thinking_toggle,supports_thinking_levels,supports_images,supports_files,enabled,config_cipher,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?) "
            "ON CONFLICT(model_id) DO UPDATE SET display_name=excluded.display_name,upstream_model=excluded.upstream_model,context_window_tokens=excluded.context_window_tokens,supports_thinking_toggle=excluded.supports_thinking_toggle,supports_thinking_levels=excluded.supports_thinking_levels,supports_images=excluded.supports_images,supports_files=excluded.supports_files,enabled=excluded.enabled,config_cipher=excluded.config_cipher,updated_at=excluded.updated_at",
            (body.modelId, body.displayName.strip(), body.upstreamModel.strip(), body.contextWindowTokens, int(body.supportsThinkingToggle), int(body.supportsThinkingLevels and body.supportsThinkingToggle), int(body.supportsImages), int(body.supportsFiles), int(body.enabled), cipher, now, now),
        )
        _audit(connection, admin_id, "model.save", body.modelId, {"enabled": body.enabled, "keyRotated": bool(body.apiKey)})
    return {"modelId": body.modelId, "saved": True}


@router.patch("/v1/admin/models/{model_id}")
def set_model_enabled(
    model_id: str,
    body: ModelEnabledBody,
    authorization: str | None = Header(default=None),
):
    admin_id, _ = _admin(authorization)
    with _database() as connection:
        changed = connection.execute(
            "UPDATE gray_models SET enabled=?,updated_at=? WHERE model_id=?",
            (int(body.enabled), _now(), model_id),
        ).rowcount
        if not changed:
            raise HTTPException(404, "找不到该灰度模型。")
        _audit(connection, admin_id, "model.toggle", model_id, {"enabled": body.enabled})
    return {"modelId": model_id, "enabled": body.enabled}


@router.get("/v1/admin/entitlements")
def admin_entitlements(authorization: str | None = Header(default=None)):
    _admin(authorization)
    with _read_database() as connection:
        rows = connection.execute(
            "SELECT e.*,u.email,m.display_name FROM gray_entitlements e JOIN users u ON u.id=e.user_id JOIN gray_models m ON m.model_id=e.model_id ORDER BY e.created_at DESC LIMIT 500"
        ).fetchall()
    return {"items": [dict(row) for row in rows]}


@router.post("/v1/admin/entitlements")
def grant_entitlement(body: GrantBody, authorization: str | None = Header(default=None)):
    admin_id, _ = _admin(authorization)
    entitlement_id = str(uuid.uuid4())
    now = _now()
    with _database() as connection:
        user = connection.execute("SELECT id FROM users WHERE id=? AND email_verified=1", (body.userId,)).fetchone()
        model = connection.execute("SELECT model_id FROM gray_models WHERE model_id=? AND enabled=1", (body.modelId,)).fetchone()
        if user is None:
            raise HTTPException(404, "目标账号不存在或尚未验证邮箱。")
        if model is None:
            raise HTTPException(404, "灰度模型不存在或已停用。")
        connection.execute(
            "INSERT INTO gray_entitlements(id,user_id,model_id,quota_tokens,created_by,created_at,expires_at) VALUES(?,?,?,?,?,?,?)",
            (entitlement_id, body.userId, body.modelId, body.quotaTokens, admin_id, now, body.expiresAt),
        )
        connection.execute(
            "INSERT INTO gray_token_ledger(id,entitlement_id,user_id,request_id,kind,amount,details,created_at) VALUES(?,?,?,?,?,?,?,?)",
            (str(uuid.uuid4()), entitlement_id, body.userId, entitlement_id, "grant", body.quotaTokens, "管理员赠与", now),
        )
        _audit(connection, admin_id, "entitlement.grant", entitlement_id, {"userId": body.userId, "modelId": body.modelId, "quotaTokens": body.quotaTokens, "expiresAt": body.expiresAt})
        notice_id = str(uuid.uuid4())
        connection.execute(
            "INSERT INTO notifications(id,title,body,category,audience,action,action_value,status,created_by,created_at,published_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (notice_id, "已获得灰度模型", "你已获得一个灰度模型和专属额度，可在模型选择中查看。", "quota", "targeted", "models", "", "published", admin_id, now, now),
        )
        connection.execute("INSERT INTO notification_recipients(notification_id,user_id) VALUES(?,?)", (notice_id, body.userId))
    return {"entitlementId": entitlement_id, "notificationId": notice_id}


@router.post("/v1/admin/entitlements/{entitlement_id}/revoke")
def revoke_entitlement(entitlement_id: str, authorization: str | None = Header(default=None)):
    admin_id, _ = _admin(authorization)
    now = _now()
    with _database() as connection:
        row = connection.execute("SELECT * FROM gray_entitlements WHERE id=?", (entitlement_id,)).fetchone()
        if row is None:
            raise HTTPException(404, "找不到该模型资格。")
        if row["revoked_at"] is not None:
            return {"success": True, "alreadyRevoked": True}
        connection.execute("UPDATE gray_entitlements SET revoked_at=?,reserved_tokens=0 WHERE id=?", (now, entitlement_id))
        connection.execute(
            "INSERT INTO gray_token_ledger(id,entitlement_id,user_id,request_id,kind,amount,details,created_at) VALUES(?,?,?,?,?,?,?,?)",
            (str(uuid.uuid4()), entitlement_id, row["user_id"], f"revoke:{entitlement_id}", "revoke", 0, "管理员撤销资格；未用额度不再可用", now),
        )
        _audit(connection, admin_id, "entitlement.revoke", entitlement_id, {"userId": row["user_id"], "modelId": row["model_id"]})
        notice_id = str(uuid.uuid4())
        connection.execute(
            "INSERT INTO notifications(id,title,body,category,audience,action,action_value,status,created_by,created_at,published_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (notice_id, "灰度模型资格已结束", "该灰度模型资格已结束；已有聊天记录仍保留。", "gray_test", "targeted", "models", "", "published", admin_id, now, now),
        )
        connection.execute("INSERT INTO notification_recipients(notification_id,user_id) VALUES(?,?)", (notice_id, row["user_id"]))
    return {"success": True, "notificationId": notice_id}


@router.get("/v1/admin/audit")
def admin_audit(authorization: str | None = Header(default=None)):
    _admin(authorization)
    with _read_database() as connection:
        rows = connection.execute(
            "SELECT a.id,a.action,a.object_id,a.details,a.created_at,u.email AS admin_email FROM admin_audit a JOIN users u ON u.id=a.admin_user_id ORDER BY a.created_at DESC LIMIT 300"
        ).fetchall()
    return {"items": [dict(row) for row in rows]}
