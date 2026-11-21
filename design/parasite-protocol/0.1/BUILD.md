# Parasite 手机宿主施工单与联调验收

## 1 施工图

~~~mermaid
flowchart TD
    A["A 包导入：解包、验签、原子安装"] --> B["B 本机能力表：权限、来源和路由"]
    B --> C["C 三种适配器：目录、服务商协议、公开接口映射"]
    C --> D["D 实例存储：版本归属、资源、序号"]
    D --> E["E Flutter 视图：通用卡片与按钮"]
    B --> F["F 对话工具：已授权的能力和动作"]
    F --> G["G 统一 dispatch"]
    E --> G
    G --> C
    G --> H["H 本机媒体执行器与系统来源页"]
    H --> D
    E --> I["I 真机验收：点击、对话、恢复"]
    F --> I
~~~

下列新模块名字是建议施工位置。现有路径是仓库里已存在的接缝。每步的产出可以独立验收。

| 顺序 | 修改位置或新增职责 | 必须交付的结果 |
|---|---|---|
| A | 建议新增 `lib/cards/package_store.dart` | 用户从文件选取 .pcard；展示作者指纹和权限；读包、验证签名与所有摘要，暂存目录校验完毕再原子启用。使用 `getApplicationSupportDirectory()` 下的 cards/packages。模型无安装接口 |
| B | 建议新增 `lib/cards/registry.dart` | 从已启用的清单生成能力表。先按指定服务、授权、设备能力筛选。未指定时用用户首选，再用该能力的赛马日排名及[同分判定规则](PUBLISH.md)。无可用提供方显示原因。初期没有榜单时，多个合格插件让用户选，可保存为本机默认 |
| C | 建议新增 `lib/cards/adapters.dart` | 按清单 mode 选择。本机目录直接搜索，https 完成 hello/invoke，mapped 执行固定 GET 和字段映射。三者向宿主返回相同的已验证 item 列表。每次调用都核对参数、能力、域名和授权 |
| D | [chat_models.dart](../../../lib/chat_models.dart) 的 ChatMessage、selectVersion、addVersion；[local_store.dart](../../../lib/local_store.dart) 的 replaceMessage 及分块保存 | 给回复版本分配稳定 versionId，消息与其每个版本保存独立 cardRefs；索引不充当 ID。旧消息无该字段等同空列表。先持久化快照再提交版本引用；崩溃遗留的未引用文件可回收。删除消息时级联删除其全部版本的卡片引用和派生摘要 |
| E | [chat_screen.dart](../../../lib/chat_screen.dart) 的 _MessageBubble；建议抽出 `lib/cards/card_view.dart` | 使用 view 中已登记的原生组件，内容文本无执行能力。消息列表按已有分页；只有可视项创建组件，切历史版本读取所选版本的 refs，离线恢复快照。原 Office 文件卡保留现有打开方式 |
| F | [tool_executor.dart](../../../lib/tool_executor.dart) 的 definitions、execute、ToolExecutionResult；chat_screen 的 _send、_buildPrompt、_regenerateMessage | 工具结果增加可选 cardItems；模型仅收到短标题、必要字段、候选序号和本机引用。_send 遇到工具结果就保存卡片，随后模型总结失败也能展示。重新生成时给新版本独立实例，失败保留旧版本，绝不自动重放历史媒体动作 |
| G | 建议新增 `lib/cards/dispatcher.dart` | 点击与模型工具走同一入口。接受实例 ID 和受控动作名，每次从本机记录重新查权限、版本和资源。生成的文字、模型提供的 URL 或服务商任意命令都无法跳过这个入口 |
| H | [local_file_opener.dart](../../../lib/local_file_opener.dart) 的 openUrl 与受控媒体执行器 | 打开链接只接受已验证 offer。播放保留实例所有权，收到播放器成功事件才进入 playing；错误给出来源和原因。准入第一个平台时必须验证实际支持的 MIME、暂停、结束、抢占、锁屏和中断恢复 |

## 2 本机桥接接口

以下是宿主内部稳定的调用边界，服务商只实现 WIRE.md 里的 HTTP 协议。

| 入口 | 输入 | 返回或行为 |
|---|---|---|
| `card_query` | capability 和结构化 args；当前 threadId、messageId、versionId、授权从宿主上下文取得 | 选服务并调用。在宿主生成的稳定 operationId 下建一个结果组，每个 item 一个 instanceId；返回最多 20 个序号、标题、必要字段及实例引用。空结果不创建实例 |
| `card_action` | instanceId、action、args | 从实例所属插件和资源反查可用动作。模型和 UI 均不可传任意目标 URL。当前窗口或已明确选中的设备播放会话以外的实例不可访问 |
| `applyEvent` | instanceId、宿主分配的 generation、seq、状态及受控字段 | 仅接受当前 generation、严格递增 seq 的本机适配器事件。状态落盘成功再通知界面。禁止借用另一实例的状态或把响应数据解析成新的指令 |

**建议的最小存储记录。** 每个实例存 instanceId、threadId、messageId、versionId、operationId、pluginId、签名公钥指纹、packageVersion、capability、resourceId、结构化查询参数、view、过滤后的 item 快照、生成时间、generation 和 seq。服务商的资源 ID 在插件及服务商范围内使用；同一资源在两个窗口有两个实例 ID。对话和窗口清理沿用已有删除范围。快照剔除 session、认证头、远程签名 URL、插件私钥；URL 即使没有查询串也不能自行认定可长期保存。历史记录重新执行依赖服务的动作时，明确使用当前授权刷新并按旧 resourceId 对齐，找不到就报告来源已失效。

**并发例子。** 同一行情卡先查近一月再查近一年，宿主发起时将 generation 从 3 依次加到 4、5。年线先返回就提交 5，月线后返回直接丢弃。查询成功可以替换该实例的内容，刷新失败保留先前行情和原始报价时间。工具循环中相同 operationId 的增量、回放或恢复须复用已持久化实例，不能重复插卡。

~~~mermaid
stateDiagram-v2
    [*] --> Ready: 确认并保存查询结果
    Ready --> Starting: 已授权的试听或播放
    Starting --> Playing: 播放器确认
    Starting --> Failed: 解码或授权失败
    Playing --> Paused: 播放器确认暂停
    Paused --> Starting: 用户继续
    Playing --> Ready: 自然结束
    Failed --> Starting: 用户重试且来源有效
    Playing --> Snapshot: 进程结束后从本机恢复
    Ready --> Snapshot: 插件卸载或离线恢复
    Snapshot --> Ready: 用户操作并重新验证来源
~~~

对话中的“暂停”和卡面上的暂停都调用 `card_action(instanceId, pause, {})`。播放器才拥有实际播放状态；卡片离开可视区只是卸载视图，用户没有下达暂停。用户开始播放另一项时先停止前一实例，只有对应播放器回调可以更新它的状态。重启读到先前的 playing 只展示历史；获取到真实、仍活动的平台播放会话后才可显示为正在播放。

## 3 样包的卡面施工图

下面每个方框对应聊天中的一张原生卡。按标注数据绑定，浅色与深色用宿主主题色。来源与权益标签由宿主生成。卡面按可用宽度布局，不使用固定屏幕像素；主动作有可读的文字和辅助功能标签。

~~~text
音乐样包 · 查询后的单项                电影样包 · 查询后的单项
┌─────────────────────────┐      ┌─────────────────────────┐
│ 两音                    │      │ 最后一班渡轮            │
│ 两音工作室              │      │ 2026 · 虚构示例         │
│ 音源：两音工作室（示例）│      │ 丧尸题材短片……          │
│ [▷ 试听]                │      │ 来源：示例影社          │
└─────────────────────────┘      │ [打开来源 ↗]            │
                                 └─────────────────────────┘
~~~

| 操作 | 卡面变化 | 可观察的底层结果 |
|---|---|---|
| 点音乐卡试听 | 先显示加载，播放器确认后出现暂停，样音自然结束后恢复试听 | 读取签名包内 assets/two-notes.wav，网络请求数为零 |
| 点电影卡打开来源 | 系统打开来源页，回到应用仍在同一条消息 | 唯一允许目标是该 item 的已验证 open offer |
| 用户问“看一下第二部” | 在当前结果组选择第二项；只有一个候选时提示用户核对 | 不会选用另一版本或另一窗口的第二条 |
| 新闻卡刷新失败 | 旧标题和发布时间仍可读，旁边出现“刷新失败”和重试按钮 | 同一实例保留最后一次成功快照 |
| 股票卡从 1m 切到 1y | 范围选择更新，加载中标明旧数据所属区间，确认新结果后替换图形 | 允许更新的响应必须同时匹配实例、证券和最新请求序号 |

## 4 作者从样包发布自己的插件

在干净的工作目录操作。样例不需要模型 API Key 或 Parasite 账号。以下命令是给开发者的制作范例。

1. 将 [music.pcard](examples/music.pcard) 解压到一个空目录，在该目录编辑 manifest.json 和作品文件。要做远程影片插件，改用 [film.pcard](examples/film.pcard)，将 .example 域名替换为实际服务的 origin、domains 和来源目标。域名改变后重新签。
2. 生成并妥善保存一把作者私钥。以下 PowerShell 命令用 Node.js 将 PKCS#8 PEM 存在包目录之外，文件已存在则拒绝覆盖。后续版本沿用它。

~~~powershell
node -e "const f=require('node:fs'),c=require('node:crypto');const k=c.generateKeyPairSync('ed25519').privateKey;f.writeFileSync('../author-private.pem',k.export({format:'pem',type:'pkcs8'}),{flag:'wx'})"
~~~

3. 有包内媒体时，对每个文件计算 Hash 后更新清单，再对冻结后的清单字节签名。以音乐样包为例。

~~~powershell
(Get-FileHash -LiteralPath 'assets/two-notes.wav' -Algorithm SHA256).Hash.ToLowerInvariant()
node -e "const f=require('node:fs'),c=require('node:crypto'),k=c.createPrivateKey(f.readFileSync('../author-private.pem')),m=f.readFileSync('manifest.json');f.writeFileSync('signature.json',JSON.stringify({type:'signature',algorithm:'Ed25519',publicKey:c.createPublicKey(k).export({format:'jwk'}).x,signature:c.sign(null,m,k).toString('base64url')}))"
tar.exe -a -cf ../my-card.zip manifest.json signature.json assets
Copy-Item -LiteralPath ../my-card.zip -Destination ../my-card.pcard
~~~

   无包内资源时省略 tar 命令末尾的 assets。压缩清单、签名及已登记资源即可。作者私钥始终留在上级目录。开发者可以用本项目的 [Schema](protocol.schema.json) 独立校验 JSON。宿主的最终验收还包含签名、来源、权限、状态和 UI 行为。

## 5 按角色验收

| ID | 谁执行及具体输入 | 必须观察到的结果 |
|---|---|---|
| PKG-01 | 安装原样音乐包，然后断网；本地 catalog 直接输入 q=两音 | 仅一项 recording-1，来源是两音工作室，按钮“试听”。无需握手、登录或模型调用即可在预览器驱动该查询 |
| PKG-02 | 只改 manifest 一个字节；或只改 WAV 一个字节 | 分别因验签失败、资源摘要失败拒绝安装；旧版本照常 |
| PKG-03 | 更换签名公钥发布同名；原作者新增网络域名后用户拒绝更新 | 前者拒绝覆盖；后者保持旧版启用，不能联系新增域名 |
| MAP-01 | 在验收传输层用 [来源报文](examples/mapped/source-response.json) 回应新闻查询 | 一次 GET，无 hello；逐字段等于 [预期卡项](examples/mapped/expected-item.json)，点击打开相同来源链接 |
| NET-01 | 用电影服务回放 wire 中 01→04 | 握手后仅发一次 invoke，产生一张 film-17 卡，实际按钮“打开来源”，无播放按钮 |
| NET-02 | welcome 的 nonce 改一位、回显错插件或新增未请求能力 | 丢弃握手，不调用 invoke；错误状态可以在宿主看到 |
| NET-03 | 首次 invoke 回 05-expired，新握手后再次 409 | 同一业务请求至多两次 invoke，最终报会话失效；没有无限请求 |
| NET-04 | 返回 200 空数组、429、非白名单媒体 URL 各一次 | 分别是空结果、限流提示、无效响应；三个结果不混用 |
| PRIV-01 | 打开普通聊天；打开历史卡；发送一次明确影片查询 | 前两步对插件服务零请求；最后一次只向用户授权的服务发送握手和 q。抓取测试日志中应无聊天正文、模型 API Key 或全局记忆 |
| UI-01 | 在测试宿主返回两首同名曲，再分别点击第二项、用文字指定第二项 | 两种方式均命中第二个 resourceId。用户只说搜索时不播放。播放器确认后才显示播放中 |
| UI-02 | 以两张独立卡看同一股票，两次切范围并让响应倒序到达 | 只有目标实例更新，最后选择的范围保留；报价时间来自服务商 |
| UI-03 | 展示一条新闻，发布于昨日，刷新发生在今天；换浅色/深色 | 发布日期仍是昨日，原文来自受控来源；标题、时间、按钮两种主题下均可读 |
| DATA-01 | 刷新、杀进程、重启并打开旧聊天、切回复版本、再卸载插件 | 快照可分页阅读；不同版本不串卡；不会自动播放、自动重连；卸载后不可执行插件动作 |
| DATA-02 | 卡片已经落盘，随后模型生成最后一句时断线；重试加载消息 | 已得到的卡仍可见，实例数不增加 |
| END-01 | 完成目录、线上服务商和公开接口映射验收，再让陌生作者只替换内容发布一个插件 | 两个独立作者可复用同一套机制，宿主无需新增作者专用判断 |

**完成线。** 验证包和报文只能证明材料内部一致。宿主工程完成的交付证据是 PKG、MAP、NET、PRIV、UI、DATA 全部通过，以及一段真机操作记录。演示仅覆盖离线目录时应标注该范围；实际线上音源、会员或正片可用性要用已接入服务商的真实授权另行验收。
