# Cwhale 邮箱账号 API

本服务实现 [`ACCOUNT_AUTH_PLAN.md`](../../ACCOUNT_AUTH_PLAN.md) 中的邮箱注册、邮箱验证、登录、找回密码和 refresh token 轮换接口。只保存账号认证所需的邮箱、Argon2id 密码哈希、一次性验证码哈希、会话撤销记录和不可逆的限流键；不提供聊天、记忆、API Key 或文件的上传接口。

部署到 Ubuntu 服务器后，服务只监听 `127.0.0.1:8810`，现有 Nginx HTTPS 站点将 `/v1/auth/` 反向代理到它。静态官网的 root/location 保持原样。SQLite 数据库位于 `/var/lib/cwhale-account/`，应纳入服务器加密备份。

## 必需的邮件配置

注册验证和密码重置需要可用的 SMTP 发件账号。推荐使用邮箱服务商提供的应用专用密码，使用 587/STARTTLS 或 465/隐式 TLS。发件地址必须是服务商已验证的地址。不要把 SMTP 密码、应用密钥或账号服务器 secret 写进 APK、Git 或 Nginx 配置。

## Ubuntu 安装

以有 sudo 权限的部署账户执行。安装 Python 3.11 或更新版本、`python3-venv`、Nginx；应用源文件放在 `/opt/cwhale-account-api/current`：

```sh
sudo useradd --system --home /var/lib/cwhale-account --shell /usr/sbin/nologin cwhale-account
sudo install -d -o cwhale-account -g cwhale-account -m 0750 /var/lib/cwhale-account
sudo install -d -o root -g cwhale-account -m 0750 /opt/cwhale-account-api/current
sudo cp -a server/account-api/. /opt/cwhale-account-api/current/
sudo python3 -m venv /opt/cwhale-account-api/current/.venv
sudo /opt/cwhale-account-api/current/.venv/bin/pip install --requirement /opt/cwhale-account-api/current/requirements.txt
```

创建 `/etc/cwhale-account-api.env`，内容参考 `.env.example`。`CWH_AUTH_SECRET` 必须是新的随机值（至少 32 字节）；SMTP 凭据使用邮件服务商的应用密码。文件权限设为 `0600`，属主设为 `root:root`。SQLite 目录必须可由 `cwhale-account` 写入。

```sh
sudo chown root:root /etc/cwhale-account-api.env
sudo chmod 0600 /etc/cwhale-account-api.env
sudo install -o root -g root -m 0644 server/account-api/cwhale-account-api.service /etc/systemd/system/cwhale-account-api.service
sudo systemctl daemon-reload
sudo systemctl enable --now cwhale-account-api
curl --fail http://127.0.0.1:8810/healthz
```

将 `nginx-location.conf` 中的 `location` 块加入现有 HTTPS server block，在不删除网站其他配置的前提下执行 `nginx -t`，通过后再 reload Nginx。确认部署时配置的公开 HTTPS 地址下 `/v1/auth/...` 返回 JSON，而不是官网 HTML。

## APK 配置

服务和 SMTP 通过健康检查后，将部署时配置的公开 HTTPS 地址作为客户端 API base URL 构建 APK。APK 只包含公开的 HTTPS 服务地址，不包含账号数据库、SMTP 凭据或签名 secret。

## 运维

- 检查状态：`systemctl status cwhale-account-api`。
- 查看服务错误：`journalctl -u cwhale-account-api --since today`。应用日志不记录请求正文、邮箱验证码、密码、refresh token 或模型聊天数据。
- 更新程序前先在线备份 SQLite 数据库；将数据库和服务 secret 分开保护。恢复数据库时须同时恢复匹配的 `CWH_AUTH_SECRET`，否则会话和验证码签名校验失效。
- SMTP 不可用时，注册和注册验证码重发会返回明确错误；密码找回请求仍使用统一响应以降低邮箱枚举风险。
- 生产前需配置主机安全更新、防火墙仅开放必要的 SSH/HTTP/HTTPS 端口，并确认服务器和备份有访问控制。
