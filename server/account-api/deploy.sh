#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo: sudo bash deploy.sh" >&2
  exit 1
fi

SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT=/opt/cwhale-account-api
RELEASES_DIR="$INSTALL_ROOT/releases"
STAMP="$(date -u +%Y%m%d%H%M%S)"
RELEASE_DIR="$RELEASES_DIR/$STAMP"
CURRENT_LINK="$INSTALL_ROOT/current"
ENV_FILE=/etc/cwhale-account-api.env
SERVICE_FILE=/etc/systemd/system/cwhale-account-api.service

if [[ -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
  echo "Refusing to replace non-symlink path: $CURRENT_LINK" >&2
  exit 1
fi

if ! id cwhale-account >/dev/null 2>&1; then
  useradd --system --user-group --home-dir /var/lib/cwhale-account \
    --shell /usr/sbin/nologin cwhale-account
fi
install -d -o cwhale-account -g cwhale-account -m 0750 /var/lib/cwhale-account
install -d -o root -g root -m 0755 "$RELEASE_DIR"
PIP_CACHE_DIR="${PIP_CACHE_DIR:-/var/cache/cwhale-account-api/pip}"
install -d -o root -g root -m 0750 "$PIP_CACHE_DIR"

for file in main.py generation_queue.py operations.py requirements.txt cwhale-account-api.service; do
  install -o root -g root -m 0644 "$SOURCE_DIR/$file" "$RELEASE_DIR/$file"
done

(
  # The unprivileged service must be able to read its runtime even when
  # the deployment caller uses a private umask for backups.
  umask 022
  python3 -m venv "$RELEASE_DIR/.venv"
  PIP_CACHE_DIR="$PIP_CACHE_DIR" \
    "$RELEASE_DIR/.venv/bin/python" -m pip install --disable-pip-version-check \
    --no-input --requirement "$RELEASE_DIR/requirements.txt"
)
runuser -u cwhale-account -- "$RELEASE_DIR/.venv/bin/python" -B -c \
  'import argon2, cryptography, fastapi, httpx, uvicorn'
runuser -u cwhale-account -- test -x "$RELEASE_DIR/.venv/bin/uvicorn"

if [[ ! -e "$ENV_FILE" ]]; then
  install -o root -g root -m 0600 /dev/null "$ENV_FILE"
  auth_secret="$(openssl rand -hex 32)"
  cat >"$ENV_FILE" <<EOF
CWH_AUTH_SECRET=$auth_secret
CWH_AUTH_DB=/var/lib/cwhale-account/accounts.sqlite3
CWH_SMTP_HOST=
CWH_SMTP_PORT=465
CWH_SMTP_USER=
CWH_SMTP_PASSWORD=
CWH_SMTP_FROM=
CWH_SMTP_FROM_NAME=Cwhale
CWH_ADMIN_EMAILS=
EOF
  unset auth_secret
  chmod 0600 "$ENV_FILE"
fi

if ! grep -q '^CWH_ADMIN_EMAILS=' "$ENV_FILE"; then
  printf '\n# Comma-separated verified account emails allowed to use the local admin workbench.\nCWH_ADMIN_EMAILS=\n' >>"$ENV_FILE"
  chmod 0600 "$ENV_FILE"
fi

install -o root -g root -m 0644 "$RELEASE_DIR/cwhale-account-api.service" "$SERVICE_FILE"
ln -sfn "$RELEASE_DIR" "$CURRENT_LINK"
systemctl daemon-reload
systemctl enable --now cwhale-account-api
systemctl restart cwhale-account-api

for attempt in $(seq 1 15); do
  if curl --fail --silent http://127.0.0.1:8810/healthz >/dev/null; then
    echo "Cwhale account API is healthy at 127.0.0.1:8810 (release $STAMP)."
    exit 0
  fi
  sleep 1
done

systemctl --no-pager --full status cwhale-account-api || true
journalctl --no-pager -u cwhale-account-api -n 50 || true
exit 1
