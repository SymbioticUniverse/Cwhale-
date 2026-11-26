"""Durable, account-scoped model generation tasks for server-managed mode.

The queue stores encrypted request payloads and response events in the existing
account SQLite database. Provider requests are made by this server process;
mobile disconnects do not cancel them. The API never exposes a task unless the
authenticated account and all conversation/message binding IDs match.
"""

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
import sqlite3
import ipaddress
import socket
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator
from urllib.parse import urlsplit, urlunsplit

import httpx
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi import APIRouter, Header, HTTPException, Query, Request
from pydantic import BaseModel, Field

import operations


LOG = logging.getLogger("cwhale.generation_queue")
router = APIRouter(prefix="/v1/generation", tags=["generation"])
_secret_provider = None
_db_path_provider = None
_active_tasks: set[asyncio.Task] = set()
_worker_task: asyncio.Task | None = None
_MAX_ACTIVE = max(1, min(32, int(os.environ.get("CWH_SERVER_MAX_ACTIVE_TASKS", "10"))))
_MAX_QUEUED = max(1, min(1000, int(os.environ.get("CWH_SERVER_MAX_QUEUED_TASKS", "100"))))
_MAX_ACTIVE_PER_USER = max(1, min(8, int(os.environ.get("CWH_SERVER_MAX_ACTIVE_PER_USER", "2"))))
_MAX_RETAINED_TASKS_PER_USER = _MAX_QUEUED + _MAX_ACTIVE_PER_USER
_MAX_RETAINED_TASKS_GLOBAL = 5000
_MAX_REQUEST_BYTES = max(1024 * 1024, min(64 * 1024 * 1024, int(os.environ.get("CWH_SERVER_MAX_REQUEST_BYTES", str(16 * 1024 * 1024)))))
_TASK_TTL_SECONDS = 7 * 24 * 60 * 60
_ID_RE = re.compile(r"^[A-Za-z0-9_-]{8,128}$")


class GenerationTaskBody(BaseModel):
    taskId: str = Field(min_length=8, max_length=128)
    conversationId: str = Field(min_length=8, max_length=128)
    userMessageId: str = Field(min_length=8, max_length=128)
    assistantMessageId: str = Field(min_length=8, max_length=128)
    profileId: str = Field(min_length=1, max_length=128)
    upstreamBaseUrl: str | None = Field(default=None, min_length=8, max_length=2048)
    apiKey: str | None = Field(default=None, min_length=1, max_length=4096)
    entitlementId: str | None = Field(default=None, min_length=16, max_length=128)
    requestBody: dict[str, Any]


def configure(secret_provider, db_path_provider) -> None:
    global _secret_provider, _db_path_provider
    _secret_provider = secret_provider
    _db_path_provider = db_path_provider


def _now() -> int:
    return int(time.time())


def _db_path() -> Path:
    if _db_path_provider is None:
        raise RuntimeError("generation queue is not configured")
    return Path(_db_path_provider())


@contextmanager
def _database() -> Iterator[sqlite3.Connection]:
    path = _db_path()
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
    path = _db_path()
    connection = sqlite3.connect(path, timeout=15, isolation_level=None)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute("PRAGMA busy_timeout=15000")
    try:
        yield connection
    finally:
        connection.close()


def initialize(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(path, timeout=15) as connection:
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys=ON")
        connection.execute("PRAGMA journal_mode=WAL")
        connection.executescript(
            """
            CREATE TABLE IF NOT EXISTS generation_tasks (
                task_id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                conversation_id TEXT NOT NULL,
                user_message_id TEXT NOT NULL,
                assistant_message_id TEXT NOT NULL,
                profile_id TEXT NOT NULL,
                entitlement_id TEXT,
                reservation_tokens INTEGER NOT NULL DEFAULT 0,
                status TEXT NOT NULL,
                payload_cipher TEXT,
                result_cipher TEXT,
                output_cipher TEXT,
                error_message TEXT,
                last_seq INTEGER NOT NULL DEFAULT 0,
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS generation_tasks_queue
                ON generation_tasks(status, created_at);
            CREATE INDEX IF NOT EXISTS generation_tasks_user
                ON generation_tasks(user_id, status, created_at);
            CREATE INDEX IF NOT EXISTS generation_tasks_retention
                ON generation_tasks(updated_at);
            CREATE TABLE IF NOT EXISTS generation_task_events (
                task_id TEXT NOT NULL,
                seq INTEGER NOT NULL,
                kind TEXT NOT NULL,
                data_cipher TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                PRIMARY KEY(task_id, seq),
                FOREIGN KEY(task_id) REFERENCES generation_tasks(task_id) ON DELETE CASCADE
            );
            """
        )
        columns = {row[1] for row in connection.execute("PRAGMA table_info(generation_tasks)")}
        if "entitlement_id" not in columns:
            connection.execute("ALTER TABLE generation_tasks ADD COLUMN entitlement_id TEXT")
        if "reservation_tokens" not in columns:
            connection.execute("ALTER TABLE generation_tasks ADD COLUMN reservation_tokens INTEGER NOT NULL DEFAULT 0")
        now = _now()
        # A process restart cannot safely replay a provider request that may
        # already have been billed. Preserve partial output and fail it closed.
        running = connection.execute(
            "SELECT task_id,user_id,entitlement_id,reservation_tokens "
            "FROM generation_tasks WHERE status='running'"
        ).fetchall()
        for row in running:
            task_id = row["task_id"]
            if row["entitlement_id"]:
                operations.settle_entitlement(
                    connection, task_id, row["entitlement_id"], row["user_id"],
                    row["reservation_tokens"], None, "服务重启，释放未结算的预留额度",
                )
            connection.execute(
                "UPDATE generation_tasks SET status='failed',payload_cipher=NULL,"
                "error_message=?,updated_at=? WHERE task_id=?",
                ("服务器进程重启，任务已停止以避免重复请求；已接收的部分回复仍可查看。", now, task_id),
            )
            _append_event(connection, task_id, "error", {
                "message": "服务器进程重启，任务已停止以避免重复请求；已接收的部分回复仍可查看。"
            }, update_output=False)
        _delete_expired_tasks(connection, now)
        # Repair reservations left by older workers that removed a task
        # without settling its quota.
        connection.execute(
            "UPDATE gray_entitlements SET reserved_tokens=COALESCE(("
            "SELECT SUM(t.reservation_tokens) FROM generation_tasks t "
            "WHERE t.entitlement_id=gray_entitlements.id "
            "AND t.status='queued' AND gray_entitlements.revoked_at IS NULL"
            "), 0)"
        )


def _cipher() -> AESGCM:
    if _secret_provider is None:
        raise RuntimeError("generation queue is not configured")
    key = hmac.new(_secret_provider(), b"cwhale-generation-task-v1", hashlib.sha256).digest()
    return AESGCM(key)


def _encrypt(value: Any) -> str:
    nonce = secrets.token_bytes(12)
    plain = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    encrypted = _cipher().encrypt(nonce, plain, b"cwhale-generation-v1")
    return base64.urlsafe_b64encode(nonce + encrypted).decode("ascii")


def _decrypt(value: str) -> Any:
    raw = base64.urlsafe_b64decode(value.encode("ascii"))
    plain = _cipher().decrypt(raw[:12], raw[12:], b"cwhale-generation-v1")
    return json.loads(plain.decode("utf-8"))


def _decode_token(token: str) -> dict[str, Any]:
    parts = token.split(".")
    if len(parts) != 3:
        raise HTTPException(401, "登录状态已失效，请重新登录。")
    try:
        header = json.loads(base64.urlsafe_b64decode(parts[0] + "=" * (-len(parts[0]) % 4)))
        payload = json.loads(base64.urlsafe_b64decode(parts[1] + "=" * (-len(parts[1]) % 4)))
        signature = base64.urlsafe_b64decode(parts[2] + "=" * (-len(parts[2]) % 4))
    except (ValueError, json.JSONDecodeError):
        raise HTTPException(401, "登录状态已失效，请重新登录。") from None
    if not isinstance(header, dict) or not isinstance(payload, dict):
        raise HTTPException(401, "登录状态已失效，请重新登录。")
    expected = hmac.new(
        _secret_provider(), f"{parts[0]}.{parts[1]}".encode("ascii"), hashlib.sha256
    ).digest()
    if (
        header.get("alg") != "HS256"
        or not hmac.compare_digest(signature, expected)
        or int(payload.get("exp", 0)) <= _now()
        or not isinstance(payload.get("sub"), str)
    ):
        raise HTTPException(401, "登录状态已失效，请重新登录。")
    with _read_database() as connection:
        user = connection.execute(
            "SELECT id FROM users WHERE id=? AND email_verified=1", (payload["sub"],)
        ).fetchone()
    if user is None:
        raise HTTPException(401, "账号不可用，请重新登录。")
    return payload


def _current_user(authorization: str | None) -> str:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(401, "请先登录 Cwhale 账号。")
    return str(_decode_token(authorization[7:])["sub"])


def _trim_terminal_tasks(
    connection: sqlite3.Connection,
    *,
    user_id: str | None,
    maximum_before_insert: int,
) -> int:
    if user_id is None:
        total = int(connection.execute(
            "SELECT COUNT(*) FROM generation_tasks"
        ).fetchone()[0])
        query = (
            "SELECT task_id FROM generation_tasks "
            "WHERE status IN ('completed','failed') ORDER BY updated_at,created_at LIMIT ?"
        )
        parameters: tuple[Any, ...] = (max(0, total - maximum_before_insert),)
    else:
        total = int(connection.execute(
            "SELECT COUNT(*) FROM generation_tasks WHERE user_id=?", (user_id,)
        ).fetchone()[0])
        query = (
            "SELECT task_id FROM generation_tasks WHERE user_id=? "
            "AND status IN ('completed','failed') ORDER BY updated_at,created_at LIMIT ?"
        )
        parameters = (user_id, max(0, total - maximum_before_insert))
    for row in connection.execute(query, parameters).fetchall():
        connection.execute(
            "DELETE FROM generation_tasks WHERE task_id=?", (row["task_id"],)
        )
    if user_id is None:
        return int(connection.execute(
            "SELECT COUNT(*) FROM generation_tasks"
        ).fetchone()[0])
    return int(connection.execute(
        "SELECT COUNT(*) FROM generation_tasks WHERE user_id=?", (user_id,)
    ).fetchone()[0])


def _append_event(
    connection: sqlite3.Connection,
    task_id: str,
    kind: str,
    data: dict[str, Any],
    *,
    update_output: bool = True,
) -> int:
    task = connection.execute(
        "SELECT last_seq,output_cipher FROM generation_tasks WHERE task_id=?", (task_id,)
    ).fetchone()
    if task is None:
        raise RuntimeError("task not found")
    seq = int(task["last_seq"]) + 1
    output_cipher = task["output_cipher"]
    if update_output and kind == "delta":
        output = ""
        if output_cipher:
            try:
                output = str(_decrypt(output_cipher))
            except Exception:
                output = ""
        output += str(data.get("text", ""))
        output_cipher = _encrypt(output)
    connection.execute(
        "INSERT INTO generation_task_events(task_id,seq,kind,data_cipher,created_at) VALUES(?,?,?,?,?)",
        (task_id, seq, kind, _encrypt(data), _now()),
    )
    connection.execute(
        "UPDATE generation_tasks SET last_seq=?,output_cipher=?,updated_at=? WHERE task_id=?",
        (seq, output_cipher, _now(), task_id),
    )
    return seq


def _clean_upstream_url(value: str) -> str:
    parsed = urlsplit(value.strip())
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise HTTPException(400, "服务器代管仅支持 HTTPS 模型地址。")
    if parsed.query or parsed.fragment:
        raise HTTPException(400, "模型地址不能包含查询参数或片段。")
    if parsed.hostname.lower() == "ai-gateway.kilo.ai":
        raise HTTPException(400, "Cwhale 免费模型固定使用本机直连。")
    path = parsed.path.rstrip("/")
    if not path.endswith("/chat/completions"):
        path += "/chat/completions"
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


@router.post("/tasks", status_code=202)
async def create_task(body: GenerationTaskBody, request: Request, authorization: str | None = Header(default=None)):
    if int(request.headers.get("content-length", "0") or 0) > _MAX_REQUEST_BYTES:
        raise HTTPException(413, "本轮上下文过大，请先压缩上下文后重试。")
    user_id = _current_user(authorization)
    ids = (body.taskId, body.conversationId, body.userMessageId, body.assistantMessageId)
    if any(not _ID_RE.fullmatch(value) for value in ids):
        raise HTTPException(400, "任务或会话标识格式不正确。")
    if body.entitlementId:
        if body.apiKey or body.upstreamBaseUrl:
            raise HTTPException(400, "赠与模型请求不能包含客户端 API 地址或密钥。")
        route = operations.resolve_entitlement_route(user_id, body.entitlementId)
        upstream_url = _clean_upstream_url(route["upstreamUrl"])
    else:
        if not body.upstreamBaseUrl or not body.apiKey:
            raise HTTPException(400, "请提供当前会话 API 配置，或使用已授予的灰度模型。")
        upstream_url = _clean_upstream_url(body.upstreamBaseUrl)
    hostname = urlsplit(upstream_url).hostname
    try:
        addresses = await asyncio.get_running_loop().getaddrinfo(hostname, None, type=socket.SOCK_STREAM)
    except OSError:
        raise HTTPException(400, "无法解析模型服务地址，请检查 API 配置。") from None
    if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
        raise HTTPException(400, "模型服务地址解析到非公网 IP，服务器代管已拒绝该地址。")
    request_body = body.requestBody
    if request_body.get("stream") is not True or not isinstance(request_body.get("messages"), list):
        raise HTTPException(400, "模型请求格式不正确。")
    if not request_body.get("model"):
        raise HTTPException(400, "模型名称不能为空。")
    with _database() as connection:
        _delete_expired_tasks(connection, _now())
        existing = connection.execute(
            "SELECT * FROM generation_tasks WHERE task_id=?", (body.taskId,)
        ).fetchone()
        if existing:
            if (
                existing["user_id"] != user_id
                or existing["conversation_id"] != body.conversationId
                or existing["user_message_id"] != body.userMessageId
                or existing["assistant_message_id"] != body.assistantMessageId
            ):
                raise HTTPException(409, "任务标识已绑定到其他消息，已拒绝复用。")
            return {"taskId": body.taskId, "status": existing["status"], "lastSeq": existing["last_seq"]}
        count = connection.execute(
            "SELECT COUNT(*) AS count FROM generation_tasks WHERE status IN ('queued','running')"
        ).fetchone()["count"]
        if count >= _MAX_QUEUED + _MAX_ACTIVE:
            raise HTTPException(429, "服务器任务队列已满，请稍后重试。")
        user_retained = _trim_terminal_tasks(
            connection,
            user_id=user_id,
            maximum_before_insert=_MAX_RETAINED_TASKS_PER_USER - 1,
        )
        if user_retained >= _MAX_RETAINED_TASKS_PER_USER:
            raise HTTPException(429, "当前账号的任务暂存已满，请等待已有任务完成后重试。")
        global_retained = _trim_terminal_tasks(
            connection,
            user_id=None,
            maximum_before_insert=_MAX_RETAINED_TASKS_GLOBAL - 1,
        )
        if global_retained >= _MAX_RETAINED_TASKS_GLOBAL:
            raise HTTPException(429, "服务器任务暂存空间繁忙，请稍后重试。")
        entitlement_id = None
        reservation_tokens = 0
        if body.entitlementId:
            entitlement_id = body.entitlementId
            payload, reservation_tokens = operations.reserve_entitlement(
                connection,
                user_id,
                entitlement_id,
                body.taskId,
                request_body,
            )
        else:
            payload = {
                "upstreamUrl": upstream_url,
                "apiKey": body.apiKey,
                "requestBody": request_body,
            }
        now = _now()
        connection.execute(
            "INSERT INTO generation_tasks(task_id,user_id,conversation_id,user_message_id,assistant_message_id,profile_id,entitlement_id,reservation_tokens,status,payload_cipher,created_at,updated_at) "
            "VALUES(?,?,?,?,?,?,?,?, 'queued',?,?,?)",
            (body.taskId, user_id, body.conversationId, body.userMessageId, body.assistantMessageId, body.profileId, entitlement_id, reservation_tokens, _encrypt(payload), now, now),
        )
        _append_event(connection, body.taskId, "queued", {"message": "已加入服务器队列"})
    return {"taskId": body.taskId, "status": "queued", "lastSeq": 1}


def _task_and_events(
    user_id: str,
    task_id: str,
    conversation_id: str,
    user_message_id: str,
    assistant_message_id: str,
    after_seq: int,
) -> dict[str, Any]:
    with _read_database() as connection:
        task = connection.execute(
            "SELECT * FROM generation_tasks WHERE task_id=? AND user_id=? AND conversation_id=? AND user_message_id=? AND assistant_message_id=?",
            (task_id, user_id, conversation_id, user_message_id, assistant_message_id),
        ).fetchone()
        if task is None:
            raise HTTPException(404, "找不到属于当前会话的代管任务。")
        rows = connection.execute(
            "SELECT seq,kind,data_cipher FROM generation_task_events WHERE task_id=? AND seq>? ORDER BY seq LIMIT 1000",
            (task_id, after_seq),
        ).fetchall()
        events = []
        for row in rows:
            try:
                data = _decrypt(row["data_cipher"])
            except Exception:
                data = {"message": "事件数据暂时无法读取。"}
            events.append({"seq": row["seq"], "type": row["kind"], "data": data})
        output_text = ""
        if task["output_cipher"]:
            try:
                output_text = str(_decrypt(task["output_cipher"]))
            except Exception:
                output_text = ""
        return {
            "taskId": task_id,
            "status": task["status"],
            "lastSeq": task["last_seq"],
            "outputText": output_text,
            "events": events,
        }


@router.get("/tasks/{task_id}/events")
async def get_task_events(
    task_id: str,
    conversationId: str = Query(min_length=8, max_length=128),
    userMessageId: str = Query(min_length=8, max_length=128),
    assistantMessageId: str = Query(min_length=8, max_length=128),
    afterSeq: int = Query(default=0, ge=0),
    authorization: str | None = Header(default=None),
):
    user_id = _current_user(authorization)
    if not _ID_RE.fullmatch(task_id):
        raise HTTPException(404, "找不到代管任务。")
    result = _task_and_events(user_id, task_id, conversationId, userMessageId, assistantMessageId, afterSeq)
    if not result["events"] and result["status"] in {"queued", "running"}:
        await asyncio.sleep(1.0)
        result = _task_and_events(user_id, task_id, conversationId, userMessageId, assistantMessageId, afterSeq)
    return result


def _claim_task() -> dict[str, Any] | None:
    with _database() as connection:
        row = connection.execute(
            "SELECT task_id,user_id FROM generation_tasks AS candidate "
            "WHERE status='queued' AND (SELECT COUNT(*) FROM generation_tasks active WHERE active.user_id=candidate.user_id AND active.status='running') < ? "
            "ORDER BY created_at,task_id LIMIT 1",
            (_MAX_ACTIVE_PER_USER,),
        ).fetchone()
        if row is None:
            return None
        changed = connection.execute(
            "UPDATE generation_tasks SET status='running',updated_at=? WHERE task_id=? AND status='queued'",
            (_now(), row["task_id"]),
        ).rowcount
        if changed != 1:
            return None
        _append_event(connection, row["task_id"], "started", {"message": "服务器开始处理"})
        task = connection.execute(
            "SELECT * FROM generation_tasks WHERE task_id=?", (row["task_id"],)
        ).fetchone()
        return {key: task[key] for key in task.keys()}


def _prune_expired_tasks() -> None:
    with _database() as connection:
        _delete_expired_tasks(connection, _now())


def _delete_expired_tasks(connection: sqlite3.Connection, now: int) -> None:
    cutoff = now - _TASK_TTL_SECONDS
    reservations = connection.execute(
        "SELECT task_id,user_id,entitlement_id,reservation_tokens "
        "FROM generation_tasks WHERE status='queued' AND entitlement_id IS NOT NULL "
        "AND updated_at < ?",
        (cutoff,),
    ).fetchall()
    for row in reservations:
        operations.settle_entitlement(
            connection, row["task_id"], row["entitlement_id"], row["user_id"],
            row["reservation_tokens"], None, "排队任务已过期，释放预留额度",
        )
    connection.execute(
        "DELETE FROM generation_tasks WHERE status!='running' AND updated_at < ?",
        (cutoff,),
    )


def _provider_error(status: int) -> str:
    if status == 429:
        return "模型服务商当前限流，请稍后重试。"
    if status in (401, 403):
        return "模型服务商拒绝了本次请求，请检查当前 API 配置。"
    if status >= 500:
        return "模型服务商暂时不可用，请稍后重试。"
    return f"模型服务商返回 HTTP {status}，请检查 API 配置。"


async def _run_task(task: dict[str, Any]) -> None:
    task_id = task["task_id"]
    answer = ""
    reasoning = ""
    tool_calls: dict[int, dict[str, str]] = {}
    usage: dict[str, int] = {}
    buffered_delta = ""
    payload: dict[str, Any] | None = None
    provider_started = False
    try:
        payload = _decrypt(task["payload_cipher"])
        if task.get("entitlement_id") and not operations.entitlement_active(task["user_id"], task["entitlement_id"]):
            raise RuntimeError("该灰度模型资格已撤销，任务没有发送给模型服务商。")
        headers = {"Accept": "text/event-stream", "Content-Type": "application/json"}
        if payload["apiKey"]:
            headers["Authorization"] = f"Bearer {payload['apiKey']}"
        # Allow long generations, but release a worker if the provider stops
        # producing SSE data for ten minutes.
        timeout = httpx.Timeout(connect=20.0, read=600.0, write=60.0, pool=20.0)
        async with httpx.AsyncClient(timeout=timeout, follow_redirects=False) as client:
            async with client.stream("POST", payload["upstreamUrl"], headers=headers, json=payload["requestBody"]) as response:
                if response.status_code < 200 or response.status_code >= 300:
                    raise RuntimeError(_provider_error(response.status_code))
                provider_started = True
                async for line in response.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    raw = line[5:].strip()
                    if not raw:
                        continue
                    if raw == "[DONE]":
                        break
                    try:
                        event = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    raw_usage = event.get("usage")
                    if isinstance(raw_usage, dict):
                        for source, target in (("prompt_tokens", "inputTokens"), ("completion_tokens", "outputTokens"), ("total_tokens", "totalTokens")):
                            if isinstance(raw_usage.get(source), int):
                                usage[target] = raw_usage[source]
                    choices = event.get("choices")
                    if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
                        continue
                    delta = choices[0].get("delta") or {}
                    if not isinstance(delta, dict):
                        continue
                    fragment = delta.get("content")
                    if isinstance(fragment, str) and fragment:
                        answer += fragment
                        buffered_delta += fragment
                        if len(buffered_delta) >= 256:
                            with _database() as connection:
                                _append_event(connection, task_id, "delta", {"text": buffered_delta})
                            buffered_delta = ""
                    reasoning_fragment = delta.get("reasoning_content")
                    if isinstance(reasoning_fragment, str):
                        reasoning += reasoning_fragment
                    for item in delta.get("tool_calls") or []:
                        if not isinstance(item, dict):
                            continue
                        index = int(item.get("index", len(tool_calls)))
                        target = tool_calls.setdefault(index, {"id": "", "name": "", "arguments": ""})
                        if isinstance(item.get("id"), str):
                            target["id"] += item["id"]
                        function = item.get("function") or {}
                        if isinstance(function, dict):
                            if isinstance(function.get("name"), str):
                                target["name"] += function["name"]
                            if isinstance(function.get("arguments"), str):
                                target["arguments"] += function["arguments"]
        if buffered_delta:
            with _database() as connection:
                _append_event(connection, task_id, "delta", {"text": buffered_delta})
        turn = {
            "text": answer,
            "reasoning": reasoning,
            "toolCalls": [tool_calls[index] for index in sorted(tool_calls) if tool_calls[index]["id"] and tool_calls[index]["name"]],
            **usage,
        }
        if task.get("entitlement_id"):
            if usage.get("totalTokens") is not None:
                turn["usageStatus"] = "actual"
                settled_tokens = usage["totalTokens"]
            else:
                serialized_messages = json.dumps(payload["requestBody"].get("messages", []), ensure_ascii=False, separators=(",", ":"))
                estimated_input = max(1, (len(serialized_messages) * 3 + 1) // 2)
                estimated_output = max(0, (len(answer) + len(reasoning)) * 3 // 2)
                settled_tokens = min(task["reservation_tokens"], estimated_input + estimated_output)
                turn.update({
                    "inputTokens": estimated_input,
                    "outputTokens": estimated_output,
                    "totalTokens": settled_tokens,
                    "usageStatus": "estimated",
                })
        if not answer and not turn["toolCalls"]:
            raise RuntimeError("模型没有返回内容，请检查模型名称和 API 服务状态。")
        with _database() as connection:
            if task.get("entitlement_id"):
                operations.settle_entitlement(
                    connection,
                    task_id,
                    task["entitlement_id"],
                    task["user_id"],
                    task["reservation_tokens"],
                    settled_tokens,
                    "上游实际 usage" if turn.get("usageStatus") == "actual" else "按本地字符数估算用量",
                )
            connection.execute(
                "UPDATE generation_tasks SET status='completed',payload_cipher=NULL,result_cipher=?,updated_at=? WHERE task_id=?",
                (_encrypt(turn), _now(), task_id),
            )
            _append_event(connection, task_id, "completed", {"turn": turn})
    except Exception as error:
        message = str(error)[:600] if isinstance(error, RuntimeError) else "模型连接中断，任务已保存为失败状态；可以检查部分回复后重新生成。"
        with _database() as connection:
            if task.get("entitlement_id"):
                estimated_input = 0
                if provider_started and payload is not None:
                    serialized_messages = json.dumps(payload.get("requestBody", {}).get("messages", []), ensure_ascii=False, separators=(",", ":"))
                    estimated_input = max(1, (len(serialized_messages) * 3 + 1) // 2)
                operations.settle_entitlement(
                    connection,
                    task_id,
                    task["entitlement_id"],
                    task["user_id"],
                    task["reservation_tokens"],
                    estimated_input if estimated_input else None,
                    "失败请求释放未使用预留；输入按保守估算结算" if estimated_input else "请求未开始，释放预留额度",
                )
            connection.execute(
                "UPDATE generation_tasks SET status='failed',payload_cipher=NULL,error_message=?,updated_at=? WHERE task_id=?",
                (message, _now(), task_id),
            )
            _append_event(connection, task_id, "error", {"message": message})


async def _worker_loop() -> None:
    next_prune_at = time.monotonic() + 3600
    while True:
        if time.monotonic() >= next_prune_at:
            await asyncio.to_thread(_prune_expired_tasks)
            next_prune_at = time.monotonic() + 3600
        _active_tasks.difference_update({task for task in _active_tasks if task.done()})
        while len(_active_tasks) < _MAX_ACTIVE:
            task = await asyncio.to_thread(_claim_task)
            if task is None:
                break
            running = asyncio.create_task(_run_task(task))
            _active_tasks.add(running)
        await asyncio.sleep(0.35 if _active_tasks else 0.8)


async def start_worker(path: Path) -> asyncio.Task:
    global _worker_task
    initialize(path)
    _worker_task = asyncio.create_task(_worker_loop(), name="cwhale-generation-queue")
    return _worker_task


async def stop_worker() -> None:
    global _worker_task
    if _worker_task is not None:
        _worker_task.cancel()
        try:
            await _worker_task
        except asyncio.CancelledError:
            pass
        _worker_task = None
    for task in list(_active_tasks):
        task.cancel()
    if _active_tasks:
        await asyncio.gather(*_active_tasks, return_exceptions=True)
    _active_tasks.clear()
