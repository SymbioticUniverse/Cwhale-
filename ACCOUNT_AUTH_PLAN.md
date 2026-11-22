# Cwhale 邮箱账号流程与服务端接口方案

状态：邮箱账号客户端与 API 已部署。`/v1/auth/` 通过现有 HTTPS/Nginx 转发到独立 systemd 服务；验证码发信使用 163 SMTP。服务端只处理账号认证数据，不提供聊天内容接口。Android 正式包通过 `tool/package_android.ps1 -AuthBaseUrl <账号服务 HTTPS 地址>` 构建。

## 数据边界

- 账号服务器只保存注册邮箱、密码哈希、邮箱验证状态、账号状态、验证码挑战和会话撤销信息。
- 明文密码只在用户提交时通过 HTTPS 发给账号服务器，不写入本机存储、日志、聊天记录或模型 API。
- 聊天、摘要、窗口记忆、全局记忆、模型 API Key、生成文件都继续保存在本机；登录不会上传或同步这些数据。
- 客户端只把轮换后的 refresh token 存在系统安全存储；access token 只驻留内存。退出登录会请求服务器撤销 refresh token，并清除本机 refresh token。
- 账号服务器地址通过 `--dart-define=CWHale_AUTH_BASE_URL=<账号服务 HTTPS 地址>` 配置。客户端只接受 HTTPS。

## 用户流程

```mermaid
flowchart TD
  SETTINGS[设置 / 账号与安全] --> LOGIN[邮箱登录]
  LOGIN -->|登录成功| ACCOUNT[账号状态]
  LOGIN -->|邮箱未验证| VERIFY[输入邮箱验证码]
  LOGIN -->|忘记密码| FORGOT[输入注册邮箱]
  LOGIN -->|邮箱注册| REGISTER[邮箱、密码、确认密码、同意条款]
  REGISTER -->|发验证邮件| VERIFY
  VERIFY -->|验证码正确| ACCOUNT
  FORGOT -->|发送重置验证码| RESET[验证码、新密码、确认新密码]
  RESET -->|重置成功| LOGIN
  ACCOUNT -->|退出登录| LOGIN
```

登录不作为本地聊天的启动门槛。服务器配置后，用户可以从设置进入账号页面。退出账号不清除任何本机聊天数据。

## HTTP API 约定

所有请求使用 JSON、HTTPS 和统一响应格式。建议错误响应为 `{"code":"INVALID_CODE","message":"验证码无效或已过期"}`。成功响应字段如下；服务器可以增加字段，但不要更改已有字段含义。

| 方法与路径 | 请求字段 | 成功响应 |
| --- | --- | --- |
| `POST /v1/auth/register` | `email`, `password` | `challengeId`, `retryAfterSeconds`, `expiresInSeconds` |
| `POST /v1/auth/email/verify` | `challengeId`, `code` | 登录会话对象 |
| `POST /v1/auth/email/resend` | `challengeId` | `retryAfterSeconds`, `expiresInSeconds` |
| `POST /v1/auth/login` | `email`, `password` | 登录会话对象 |
| `POST /v1/auth/password-reset/request` | `email` | 不论邮箱是否存在都返回同格式的 `challengeId`, `retryAfterSeconds`, `expiresInSeconds` |
| `POST /v1/auth/password-reset/resend` | `challengeId` | `retryAfterSeconds`, `expiresInSeconds` |
| `POST /v1/auth/password-reset/confirm` | `challengeId`, `code`, `newPassword` | `{"success":true}` |
| `POST /v1/auth/token/refresh` | `refreshToken` | 登录会话对象，返回轮换后的 refresh token |
| `POST /v1/auth/logout` | `refreshToken` | `{"success":true}` |

登录会话对象：

```json
{
  "accessToken": "短时效 bearer token",
  "refreshToken": "可轮换并可撤销的随机 token",
  "expiresIn": 900,
  "user": {
    "id": "用户 ID",
    "email": "user@example.com",
    "emailVerified": true
  }
}
```

未验证邮箱时，`POST /v1/auth/login` 返回 HTTP 403、`code: EMAIL_NOT_VERIFIED` 和 `challengeId`，客户端转到邮箱验证页。

## 服务端安全要求

- 密码使用 Argon2id 等专用密码哈希算法并配置合适的工作因子；绝不保存或回传明文密码。
- 邮箱统一去空格并小写归一化；验证码使用密码学安全随机数，至少 6 位，有效期建议 10 分钟，单次使用，错误尝试最多 5 次，重复发送至少间隔 60 秒。
- 注册、登录、验证码发送和密码重置都应按 IP 与账号限流。密码重置请求对已注册和未注册邮箱返回相同响应与大致相同耗时，避免账号枚举。
- refresh token 应有轮换、重放检测、撤销和过期策略；退出登录需立即撤销当前 refresh token。access token 建议短时效。
- 邮件验证码和 token 不写普通应用日志；响应不包含密码哈希、验证码或敏感账号状态。
- 服务端仅保存账号与认证数据。不得从客户端请求聊天记录、记忆、模型 API Key 或文件内容。

## 当前实现范围

设置页包含邮箱登录、注册、邮箱验证码、忘记密码、重置密码和退出登录界面；未配置账号端点的构建会显示未接入状态。API 服务端实现位于 `server/account-api/`，使用 SQLite、Argon2id、一次性邮件验证码与 refresh token 轮换；生产服务只接收账号认证数据，不提供聊天内容接口。Ubuntu/systemd/Nginx 部署步骤见 `server/account-api/README.md`。
