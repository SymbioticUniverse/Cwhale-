#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import shutil
import sys
from datetime import datetime, timezone
from pathlib import Path


AUTH_SNIPPET = """    location ^~ /v1/auth/ {
        proxy_pass http://127.0.0.1:8810;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 25s;
        client_max_body_size 16k;
    }
"""

GENERATION_SNIPPET = """    location ^~ /v1/generation/ {
        proxy_pass http://127.0.0.1:8810;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 30s;
        client_max_body_size 16m;
    }
"""


def _block_end(text: str, opening: int) -> int | None:
    depth = 0
    quote: str | None = None
    escaped = False
    comment = False
    for index in range(opening, len(text)):
        char = text[index]
        if comment:
            if char == "\n":
                comment = False
            continue
        if quote is not None:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = None
            continue
        if char == "#":
            comment = True
        elif char in {"'", '"'}:
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return index
    return None


def _server_blocks(text: str):
    for match in re.finditer(r"(?m)^\s*server\s*\{", text):
        opening = text.find("{", match.start(), match.end())
        ending = _block_end(text, opening)
        if ending is not None:
            yield match.start(), opening, ending, text[match.start() : ending + 1]


def main() -> int:
    parser = argparse.ArgumentParser(description="Add the Cwhale auth route to an existing HTTPS Nginx site.")
    parser.add_argument("--site-file", required=True, type=Path, help="Existing Nginx site configuration file")
    parser.add_argument("--hostname", required=True, help="Public hostname already configured in that HTTPS server block")
    args = parser.parse_args()
    nginx_site: Path = args.site_file
    hostname: str = args.hostname

    if not nginx_site.is_file():
        print(f"Expected Nginx site file is missing: {nginx_site}", file=sys.stderr)
        return 1
    original = nginx_site.read_text(encoding="utf-8")
    candidates = []
    for start, opening, ending, block in _server_blocks(original):
        names = re.search(r"(?m)^\s*server_name\s+([^;]+);", block)
        listens_https = re.search(r"(?m)^\s*listen\s+[^;]*\b443\b", block)
        if (
            names
            and listens_https
            and hostname in names.group(1).split()
        ):
            candidates.append((opening, ending, block))
    if len(candidates) != 1:
        print(
            f"Expected one HTTPS server block for {hostname}; found {len(candidates)}. No changes made.",
            file=sys.stderr,
        )
        return 1

    _, ending, block = candidates[0]
    snippets = []
    if not re.search(r"(?m)^\s*location\s+\^~\s+/v1/auth/", block):
        snippets.append(AUTH_SNIPPET)
    if not re.search(r"(?m)^\s*location\s+\^~\s+/v1/generation/", block):
        snippets.append(GENERATION_SNIPPET)
    for path in ("/v1/notifications", "/v1/notifications/", "/v1/me/gray-models", "/v1/admin/"):
        modifier = "^~" if path.endswith("/") else "="
        pattern = rf"(?m)^\s*location\s+(?:=\s+|\^~\s+)?{re.escape(path)}\s*\{{"
        if not re.search(pattern, block):
            snippets.append(
                AUTH_SNIPPET.replace("location ^~ /v1/auth/", f"location {modifier} {path}")
                .replace("client_max_body_size 16k", "client_max_body_size 1m")
            )
    if not snippets:
        print("Cwhale gateway routes already exist; no changes made.")
        return 0

    backup = Path("/var/backups/cwhale-account-api")
    backup.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup_file = backup / f"cwhale-auth-nginx-{stamp}.conf"
    shutil.copy2(nginx_site.resolve(), backup_file)

    updated = original[:ending] + "\n" + "\n".join(snippets) + original[ending:]
    nginx_site.write_text(updated, encoding="utf-8")
    print(f"Added missing Cwhale gateway routes. Backup: {backup_file}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
