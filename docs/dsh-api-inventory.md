# dsh WebUI API 完整清单

来源：deepseek-harness 源码（`packages/host/webserver`、`packages/client/connection`、`packages/host/apiproxy`、`packages/api/gateway`、`docs/api-gateway.md`），版本 `0.1.0-rc.5`。

## 1. 服务器形态

- `dsh web` 启动一个 node:http 服务器，默认 `127.0.0.1:3080`（`--host 0.0.0.0`、`--port`、`--trusted-host` 可改）。
- 所有 API 挂在 `/api` 前缀下；其余路径由 SPA 静态服务兜底（miss → index.html，SPA 路由）。
- **没有认证层**。安全模型 = 绑定 loopback + Host 头信任栅栏（防 DNS rebinding / 跨站）：
  - Host 头必须是 loopback 或 `trustedHosts` 里声明的 authority，否则 403。
  - `sec-fetch-site: cross-site` 一律拒绝；带 Origin 时必须同源。
  - **特权方法钉死 loopback**（即使配了 trustedHosts）：`agentPreset.read/copy/openDocument/remove`、`host.pickDirectory`、`host.openPath`、`settings.*`（全部）、`credentials.*`（全部）、`llm.discoverModels`。
  - → 对我们的 sidecar 是好消息：sidecar 与 dsh 同机、走 loopback，全部方法可用，Host 头天然合法。

## 2. RPC 线上模型（四象限）

所有消息是四member判别联合（`type` 字段）：

| type | 载体 | 方向 |
|---|---|---|
| `client-request` | `POST /api/<method>` 请求体 | 客户端发起调用 |
| `server-response` | 该 POST 的响应体 | 应答（echo rpcId） |
| `server-request` | WS 下行帧（或进程内 SSE） | 服务器推送/提问 |
| `client-response` | `POST /api/respond` 请求体 | 回答 approval/question（echo rpcId） |

- `client-request` 体：`{ type: 'client-request', rpcId, method, payload }`，`method` 必须与 URL 路径段一致；`Content-Type: application/json` 强制（否则 415）。
- `server-response` 体：`{ type: 'server-response', rpcId, result }`，`result = { ok: true, value } | { ok: false, error: { code, message, details } }`。业务错误恒为 HTTP 200；4xx/5xx 只表达载体层错误。
- `POST /api/respond` 响应是载体回执：`{ accepted: true } | { accepted: false, reason: 'not-pending' | 'bad-response' }`。
- 错误码闭集（`RpcErrorDetailsMap`）：`bad-request` `cancelled` `session-not-found` `model-unavailable` `session-conflict` `agent-busy` `attachment-error` `queue-item-not-found` `steer-unavailable` `command-error` `unknown-command` `settings-rejected` `settings-conflict` `settings-not-exposed` `credential-rejected` `model-discovery-failed` `title-invalid` `fork-unavailable` `subagent-*`（7种）`workspace-*`（5种）`directory-*`（3种）`agent-preset-*`（5种）`invalid-time-zone` `internal`。

## 3. 一元方法全集（`POST /api/<method>`，共 51 个）

### session（12）
| 方法 | 说明 |
|---|---|
| `session.list` | 会话摘要列表（title、running、blank、cwd、preset、lineage） |
| `session.search` | 会话全文搜索（带 AbortSignal） |
| `session.create` | 建会话（cwd、agentPreset 可选） |
| `session.history` | 拉历史（分页 tail page，含 projections 基线块） |
| `session.models` | 该会话可用模型 |
| `session.selectModel` | 切模型 |
| `session.rename` | 改标题 |
| `session.fork` | 分叉会话 |
| `session.prompt` | 发消息（支持斜杠命令；附件引用；queue/steer 语义） |
| `session.attachment` | 上传附件（base64 图片，走 JSON 体，服务端限制约数 MB） |
| `session.updateQueue` | 编辑/删除排队中的消息 |
| `session.cancel` | 打断当前 turn |

### subagent（4）
`subagent.list`、`subagent.history`、`subagent.prompt`、`subagent.interrupt` — 子代理会话的查看与交互。

### host（5）
`host.describe`（能力/版本/cwd 描述）、`host.pickDirectory`†、`host.listDirectory`、`host.createDirectory`、`host.openPath`†（† = loopback 特权）。

### workspace（7）
`workspace.list / create / rename / delete / insertBefore / insertSessionBefore / archiveSession` — 侧栏工作区分组与排序、归档。

### skill / agentPreset（1 + 6）
`skill.list`；`agentPreset.list / select / read† / copy† / openDocument† / remove†`。

### goal（6）
`goal.create / edit / pause / resume / complete / clear`。

### settings / credentials（5 + 3，全特权）
`settings.describe / openDocument / update / replace / mutate`（带 expectedRevision 乐观并发）；`credentials.describe / set / unset`。

### llm（3）
`llm.providers`、`llm.models`（模型目录，非特权）、`llm.discoverModels`†（探测自定义端点，特权）。

## 4. Typert Remote 方法（同样走 `POST /api/<namespace>/<method>`）

新一代生成式 RPC，与上面共用 `/api` 通道，路径是两段式 `<namespace>/<method>`，payload 是 `{ args: {...} }`：

- `goals/create|edit|pause|resume|complete|clear`（与 goal.* 并存的新通道）
- `messageFeedback/list|put|delete`（消息点赞/点踩）
- `pluginInventory/list`（设置页插件清单）
- `cordisRunner/*`（self-modification 面板：runHostHalf、getClientCode、invoke 等 ~12 个，手机端 v1 可不做）

## 5. 事件流（下行）

浏览器走 **WebSocket**（HTTP GET 到这两个路径会得到 426）：

- `WS /api/events.mux` — 全会话聚合流。打开即发每个已挂会话的 `session/subscribed` 控制帧 + 重放未决 approval/question（rpcId 原样复用 = 刷新恢复基线）。
- `WS /api/events.host` — 主机级流：会话增删、running 翻转、agent 错误、workspace 变更。

帧是 `server-request` 全形：`{ type: 'server-request', rpcId, method: <帧type>, payload: <帧> }`。客户端在 WS 上**不许发消息**（发了就被 1008 关闭）；上行永远走 HTTP POST。

### mux 帧类型
- `session/event` — 原始会话事件透传（+ 可选 `view` 渲染意图）。事件词表：`turn/start|end`、`step/start|end`、`user/message`、`assistant/chunk`（流式文本）、`tool/call`、`tool/result`、`approval/asked|decided`、`session/title`、`plan/mode`、`compaction/start|summary`、`goal/change`、`subagent/descriptor`、`command/run|done`、`agent-preset/selected`、`permission/preset`、`llm/retry`、`hook/invoked|result` 等（merge 扩展，未知类型必须容忍）。
- `session/subscribed`（lastSeq）
- `approval/requested`（**可应答**：sessionId、approvalId、toolName、reason；用 `POST /api/respond` echo rpcId 回 `outcome: 'allowed-once' | 'rejected'`）
- `approval/resolved`
- `question/requested`（**可应答**：questions 批量；回 `answer` 整批）
- `question/resolved`
- `session/queue` — 排队/steering 收件箱全量快照
- `session/jobs` — 后台任务全量快照
- `session/projection` — 投影单元值推送（seq 高者胜，history tail 页给基线）
- `stream/error`

### host 帧类型
`host/session-added`（lineage、cwd、preset、blank）、`host/session-removed`、`host/session-status`（running 翻转）、`host/agent-error`、`host/workspace-changed|removed|order-changed`、`host/archived-sessions-changed`、`host/remote-event`（白名单转发的 cordis 事件）、`stream/error`。

### tool 渲染意图（`view`）
`tool/call`/`tool/result` 帧带 host 端算好的 `ToolCallView / ToolResultView`（`generic`/`terminal`/`diff` + locations），客户端不用理解每个工具就能渲染。**不持久化**，重放时 host 重算。

## 6. 下载通道

- `GET /api/session.export?sessionId=...&includeDescendants=` — 会话日志 ZIP（attachment 响应）。400 缺参 / 404 无会话。

## 7. 对 sidecar 转发的含义

1. 上行只有两种：`POST /api/*`（JSON in/out，一问一答）和 `GET /api/session.export`（流式二进制）。全部可无状态代理。
2. 下行两条 WS 长连（mux + host），只收不发，断线重连语义 = 重开流 + 重拉 history/list（服务端为此设计了 subscribed/重放/全量快照机制，手机端弱网友好）。
3. `session.prompt` 的取消靠 `session.cancel`（业务级），`session.search` 等长调用靠断开载体（AbortSignal 挂在请求上）——代理需要把「手机端放弃」映射为「对 dsh 的请求中断」。
4. 附件上传是 JSON base64（上限约几 MB + 1MB envelope headroom），转发时注意帧大小限制。
5. 无认证 → 信任边界完全由我们的 E2E 加密层承担；sidecar 绝不能把 dsh 端口暴露到公网，只走 loopback。
