# 服务商握手和调用报文

0.1 的 HTTPS 适配器实现两个 POST 端点。作者直接托管服务，宿主直接连接清单指定的 origin。离线 catalog 由宿主本机执行，跳过整段远程握手。

| 请求 | 用途 | 成功 |
|---|---|---|
| `POST /parasite/v1/hello` | 验证此 origin 接受的协议、插件 ID、能力子集，颁发临时会话 | 200，welcome |
| `POST /parasite/v1/invoke` | 在临时会话里执行一项声明过的只读查询 | 200，result；无命中为 items 空数组 |

路径中的 v1 标识本草案确定的 HTTP 路径族，真正的线协议版本通过 hello 协商。按 HTTPS 默认端口 443 连接，origin 只有 scheme 和 host，拒绝用户名、密码、路径、查询和片段。两个 POST 都使用 `Content-Type: application/json` 和 `Accept: application/json`。body 为 UTF-8 JSON，禁止重名键。服务商对 hello/invoke 及错误响应发送 `Cache-Control: no-store`。每次 hello、每个新 invoke 都用新的小写 UUIDv4 作为 id。同一逻辑请求重试复用原 invoke id 和业务参数。

## 1 握手时序图

~~~mermaid
sequenceDiagram
    actor U as 用户
    participant H as 手机宿主
    participant L as 本机能力与权限表
    participant P as 选中的服务商
    U->>H: 查丧尸题材电影
    H->>L: 选择 movie.search 并核对服务商及授权
    alt 拒绝访问
        L-->>H: 未授权
        H-->>U: 显示本机状态，结束
    else 已获授权
        H->>P: POST hello，版本、能力、随机 nonce
        P-->>H: welcome，回显、能力交集、session、有效期
        H->>H: 验证并按域名和身份绑定会话
        H->>P: POST invoke，查询参数，Session 头
        alt 会话过期
            P-->>H: 409 SESSION_EXPIRED
            H->>P: 新 hello，取得新会话
            H->>P: 同一 invoke ID 再发一次
        end
        P-->>H: result，资源与允许的动作
        H->>H: 校验、绑定实例、保存展示快照
        H-->>U: 显示电影卡
        U->>H: 打开来源
        H->>H: 核对实例、域名及动作，交给系统打开
    end
~~~

### 第一次请求

~~~http
POST /parasite/v1/hello HTTP/1.1
Host: film.example
Content-Type: application/json
Accept: application/json

{"type":"hello","id":"11111111-1111-4111-8111-111111111111","nonce":"0123456789abcdef0123456789abcdef","pluginId":"example.filmclub","versions":["0.1"],"capabilities":["movie.search"]}
~~~

nonce 由宿主用安全随机源生成 16 字节，编码为小写十六进制，仅用于本次握手关联。这里的固定 nonce、ID 和令牌只用于联调样例。服务商按宿主给出的版本顺序选第一个双方支持的版本，并返回请求能力与本服务能力的交集；交集为空返回 UNSUPPORTED_CAPABILITY。服务商只接受自己配置过的 pluginId。

~~~json
{"type":"welcome","id":"11111111-1111-4111-8111-111111111111","nonce":"0123456789abcdef0123456789abcdef","pluginId":"example.filmclub","version":"0.1","session":"fixture-session-only","ttlSeconds":300,"capabilities":["movie.search"]}
~~~

宿主验证响应 id、nonce、pluginId 完全一致，version 在本次提议中，capabilities 非空、无重复且是请求子集；本轮要执行的能力也必须被接受。任一不符时丢弃 welcome，不发 invoke。TLS 验证对端域名，nonce 不作为身份凭证。正式服务的 session 至少使用 128 位不可预测随机量、base64url 编码，并绑定插件、认证账号（如有）、协议和允许的能力。到期服务端必须拒绝。

宿主只在内存缓存 session，键为插件 ID、包内容摘要、origin、服务账号和协商能力集；从收到 welcome 起以单调时钟计时，到期主动重握手。换账号、卸载、升级或撤销授权必须清除对应会话。两个并发的首次查询可共享同一在途握手，仍各自使用唯一 invoke id。

### 查询请求与响应

~~~http
POST /parasite/v1/invoke HTTP/1.1
Host: film.example
Content-Type: application/json
Accept: application/json
Parasite-Session: fixture-session-only

{"type":"invoke","id":"22222222-2222-4222-8222-222222222222","version":"0.1","capability":"movie.search","args":{"q":"丧尸"}}
~~~

~~~json
{
  "type":"result","id":"22222222-2222-4222-8222-222222222222","version":"0.1",
  "items":[{
    "id":"film-17","title":"最后一班渡轮","subtitle":"2026 · 虚构示例",
    "summary":"丧尸题材短片，用于演示来源页跳转。",
    "sourceName":"示例影社","sourceUrl":"https://film.example/titles/17",
    "offers":[{"kind":"open","target":"https://film.example/titles/17"}]
  }]
}
~~~

服务商先校验 session、版本、能力、必填和枚举，再查询自己的目录。宿主先校验响应与请求的 id 和版本，再验证资源 ID 在本批中唯一、形状正确、域名与权限合法。违反契约时整批报 INVALID_RESPONSE；数据部分成功而某个设备缺少播放器时，可显示已验证文本和可用的其他动作。示例的唯一主按钮是“打开来源”。这条响应不能呈现为“播放正片”。

## 2 访问凭证和动作边界

- `auth:none` 时省略 Authorization。若清单为 `providerBearer`，由用户在该插件的凭证入口录入服务商签发的访问令牌，安全存储按插件 ID、签名公钥和 origin 隔离。首次 hello 前缺令牌就停在“连接服务账号”。只对两个同 origin POST 设置 `Authorization: Bearer <provider-token>`。插件看不到凭证，模型档案密钥绝不复用。0.1 不规定服务商如何发放其令牌。
- 权限对应表为 query.remote → 指定服务商只读查询，media.preview → 试听/预告，media.play → 完整播放，link.open → 通过系统打开 HTTPS 来源页。握手前展示并取得本轮或已保存的服务授权。用户选定某首歌并要求试听可以授权本次媒体动作，仅要求搜索时不能自动拉媒体流。
- 远端只允许清单精确列出的公开 HTTPS DNS 主机；安装后首次连接和每次重连均验证证书、解析地址和实际连接目标，拒绝内网、localhost、IP 字面量及本机文件。适配器、媒体与封面加载器都必须执行这条边界。0.1 拒绝宿主代取请求的 HTTP 重定向；需要 CDN 的服务商直接给出已登记的最终公开地址。包内媒体只认验签清单里的路径。外部来源页在用户点击后交给系统打开，宿主不向它附带任何请求头或令牌。
- preview/play 必须有 mime，允许首版明列的 WAV、MP3 和 MP4；宿主校验内容类型及设备解码支持。open 必须为 HTTPS，禁止携带 mime。每个 item 的同类 offer 最多一个。预告与正片必须分别由服务商授权并明确标注。需要 DRM 或其他登录流程才能播放的资源可以只提供 open。
- expiresAt 是 UTC 或含时区偏移的 RFC 3339 时间。过期 offer 置灰，用户可请求刷新；不传播私有播放地址。快照只落展示字段、稳定资源 ID 和动作种类。HTTPS 目标按点击时需要从有效内存结果或重新授权的查询取回；包内资产按已验证包及路径读取。

## 3 故障和时限

| HTTP | 服务商 code | 宿主行为 |
|---|---|---|
| 400 | INVALID_REQUEST | 标记参数错误，允许用户修改 |
| 401 / 403 | AUTH_REQUIRED / FORBIDDEN | 提示连接账号或缺少权益。不能把权限错误渲染为空结果 |
| 409 | SESSION_EXPIRED | 清除会话；在同一用户动作内重握手再重发一次 |
| 422 | UNSUPPORTED_VERSION / UNSUPPORTED_CAPABILITY | 停止调用，显示需要升级或服务不支持 |
| 429 | RATE_LIMITED | 展示限流，可读取以秒为单位的 Retry-After；用户稍后重试 |
| 503 | UNAVAILABLE | 保留已有卡片，提供重试 |

可解析请求的错误均回显原 id。例如 `{"type":"error","id":"22222222-2222-4222-8222-222222222222","code":"SESSION_EXPIRED","message":"握手会话已过期"}`。连 id 都无法解析时返回 400 空 body。网络/TLS、未知响应、id 不符和格式失败由宿主处理为 NETWORK_ERROR 或 INVALID_RESPONSE，不让模型补写卡片。

单次 hello 最多 4 秒，invoke 最多 8 秒，整个发现与查询含恢复共 15 秒，使用单调时钟；这些时限只适用于卡片查询。一次用户动作最多尝试两次 invoke，只自动恢复一次 409 SESSION_EXPIRED，其余重试由用户发起。响应体解压后 hello ≤ 8 KiB、invoke ≤ 256 KiB；边读边计数超限即停。invoke id 相同且能力、账号、插件和 args 相同的请求在 60 秒内返回原结果或加入同一在途查询；已通过 session 检验后才登记。相同 ID 搭配不同有效参数报 INVALID_REQUEST。手机取消或换窗口时失效的异步结果不得写入另一实例；重新选择服务商前重新核对数据授权。
