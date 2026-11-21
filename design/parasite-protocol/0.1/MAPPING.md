# 社区作者怎样接入已有的公开 JSON 接口

适用条件是来源已经提供允许这种用途的公开、只读 HTTPS GET 接口，能返回 JSON，且不要求账号或密钥。社区作者在包内声明映射，手机直接请求原有接口，数据源无需修改服务。需要服务商授权、付费内容、专用 SDK 或 DRM 的场景应使用服务商协议或受支持的公开来源页。能打开详情页的卡只提供打开来源动作。

## 一个完整的新闻例子

下载 [新闻插件包](examples/news.pcard) 或打开 [作者清单](examples/news/manifest.json)。该例使用虚构数据，联调时把 [来源原始 JSON](examples/mapped/source-response.json) 作为传输层固定应答，与 [渲染前的预期 item](examples/mapped/expected-item.json) 比较。生产安装仍执行宿主对公开 HTTPS 的正常检查。

1. 用户说“查一下港口新闻”。宿主得到 `news.search` 和 `{"q":"港口"}`，核对用户授权及能力注册表。
2. `adapter.query` 把参数名 q 映射为 keyword。宿主发出 `GET https://news.example/api/articles?keyword=%E6%B8%AF%E5%8F%A3`，设置 `Accept: application/json`。整个流程只选择一个来源，来源不接收 hello、授权头、会话标识或整段对话。
3. 读 `itemsPointer=/data/stories` 对应的数组。对每个条目用 `fields` 取值，例如 id 读 /slug、title 读 /headline、publishedAt 读 /published。来源名没有映射时使用清单的 provider。offer=open 表示为合法的 sourceUrl 生成唯一 open 动作。
4. 渲染新闻卡“港口图书馆周六开放”。显示时间取 publishedAt，来源是“城市通讯（示例）”。打开按钮和口头指令均交给宿主校验并打开同一个来源地址。

## 映射契约

| 字段 | 要求 |
|---|---|
| origin / path | origin 满足 WIRE.md 的公开 HTTPS 要求。path 为固定绝对路径，仅使用字母、数字、下划线、短横线和斜杠；禁止双斜杠、路径模板、片段、查询串或任何替换主机的语法 |
| query | 输入参数名 → 来源查询字段名。两侧名称唯一，左侧必须是本 operation 声明的参数且覆盖全部已声明参数。宿主只编码有值的字段，按目标参数名排序，按 UTF-8 百分号编码，空格用 %20 |
| itemsPointer | 指向响应数组的 JSON Pointer；空字符串指整个文档，斜杠分段，~1 表示斜杠，~0 表示波浪号，数组用十进制下标 |
| fields | 标准 item 字段 → 相对于每个数组元素的 JSON Pointer。必有 id、title 映射；其余根据公共能力补齐。原始字段必须与目标字段类型一致，不隐式执行表达式或将数字 ID 转成字符串 |
| offer | none 生成空 offers。open 要求有效 sourceUrl 并生成一个 open 动作，还需要 link.open 权限 |
| 资源限制 | 线上请求含读取最多 8 秒，已解压 JSON 最多 256 KiB，无自动重试；按原顺序取前 20 项并统一校验。空数组为无结果，错误类型或缺必填值为 INVALID_RESPONSE。HTTP 429、401、403 和其他失败分别映射为限流、需要授权、禁止访问或来源不可用 |

一个映射插件只声明一个 operation。Schema 给出可绑定字段名；0.1 映射支持标量字段和打开来源动作。缺失的可选字段省略，任何已经取到但类型不符的值均视为失败。来源的文本只进入纯文本组件，不成为宿主指令。媒体试听、播放和嵌套走势图可用本机目录或已协商的服务商模式提供。

**本机握手。** 安装器检查宿主是否理解 mode、组件、字段类型与权限，校验公钥和资源摘要后，将该 capability 登记为可调用。这个决定与包哈希、公钥和用户准许的域名绑定。它代表宿主能执行这份清单，不能证明来源官方认可该作者。来源改变字段后检索失败时应显示错误，插件作者修订 Pointer、升级包版本并重新签名。
