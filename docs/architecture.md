# Reins 架构

## 命名

| 组件 | 名字 | 由来 |
|---|---|---|
| iOS App | **Reins**（缰绳） | 你手里握着的那一头。远程操控 agent。 |
| 电脑端伴生进程 | **Bridle**（笼头） | 套在马头上的那一头，缰绳接在它上面。与 dsh 同机、只走 loopback。 |
| 中继服务 | **Relay** | 两条 WebSocket 之间的哑管道，只搬密文。 |

一句话：**Bridle 套住 dsh，Relay 传递密文，Reins 握在手里。**

## 拓扑

```
 iPhone                    公网                     用户的电脑
┌────────┐            ┌──────────┐            ┌──────────────────┐
│ Reins  │◄──wss─────►│  Relay   │◄──wss─────►│ Bridle           │
│ (app)  │  密文帧    │ (哑管道) │  密文帧    │  │               │
└────────┘            └──────────┘            │  ├─ HTTP loopback│
     ▲                                        │  │  POST /api/*  │
     └──────── E2E 加密通道（端到端）──────────┘  └─ WS  /api/events.*
                                               └────────► dsh web
                                                     127.0.0.1:3080
```

- Bridle 主动外连 Relay，**不需要端口转发、不需要公网 IP、不需要动路由器**。
- Relay 只按 deviceId 撮合两条 socket，转发不透明字节。它拿不到明文、拿不到 dsh 地址、拿不到 API key。
- dsh 只监听 loopback。Bridle 与它同机，Host 头天然合法，51 个方法（含 loopback 特权方法）全部可用。
- 备用**直连模式**：同一套加密，App 直接连 Bridle 的 LAN 地址或 Tailscale 地址，不经 Relay。

## 加密通道

静态密钥 + 每连接临时密钥，三次 DH（Noise IK 同构），全部用两端标准库：Node `node:crypto` / Swift `CryptoKit`，**零第三方密码学依赖**。

### 配对（一次）
Bridle 生成静态 X25519 密钥对，落盘 `~/.reins/bridle.json`（0600）。
配对载荷（QR / 短码）包含：`relayURL`、`deviceId`、`bridle静态公钥`、`一次性配对密钥`。
App 生成自己的静态密钥对存 Keychain，用一次性密钥完成首次握手后，双方互相钉住对方静态公钥（TOFU）。一次性密钥即刻作废。

### 每次连接握手
```
app  → bridle : Ea (临时公钥) ‖ Sa (静态公钥, 用一次性/已钉密钥加密)
bridle → app  : Eb (临时公钥)
共享 = HKDF-SHA256( DH(Ea,Eb) ‖ DH(Ea,Sb) ‖ DH(Sa,Eb) ‖ DH(Sa,Sb) )
          ├─ k_a2b  (app → bridle)
          └─ k_b2a  (bridle → app)
```
前向保密（临时密钥）+ 双向认证（静态密钥）。任一方静态公钥不匹配 → 立即断开，App 显示「设备身份变了」。

### 数据帧
ChaCha20-Poly1305，nonce = 4 字节方向前缀 ‖ 8 字节单调计数器；计数器回退或重复 = 断开（抗重放）。AAD 绑定帧序号，防重排。

## 隧道协议（密文之内）

单条隧道复用全部 dsh 流量：

| 帧 | 方向 | 语义 |
|---|---|---|
| `req {id, method, payload}` | app→bridle | 映射到 `POST /api/<method>` |
| `res {id, result}` | bridle→app | 该 POST 的 `server-response.result` |
| `cancel {id}` | app→bridle | 中断在途 HTTP 请求（对应 AbortSignal） |
| `ev {seq, stream, frame}` | bridle→app | mux / host 事件流帧，带隧道级单调 seq |
| `resume {since}` | app→bridle | 重连时补发 seq 之后的帧 |
| `resync {}` | bridle→app | 缓冲已翻篇，App 重拉 list/history |
| `hello / ready` | 双向 | 版本协商、dsh 状态、bridle 版本 |
| `ping / pong` | 双向 | 15s 心跳，检测半死连接 |

Bridle 侧保留最近 2000 条事件帧的环形缓冲。手机切后台、过隧道、地铁断网回来 → `resume` 秒级续上，不丢帧、不重拉全量。这是移动端相对 webui 的第一个硬优势（webui 断线只能重开流+重拉历史）。

## dsh 侧对接要点

- 上行只有 `POST /api/<method>`（JSON）与 `GET /api/session.export`（ZIP 流），无状态代理即可。
- 下行两条 WS：`/api/events.mux`（会话事件、审批、提问、队列、任务、投影）与 `/api/events.host`（会话增删、running 翻转、workspace 变更）。客户端在 WS 上不许发消息。
- 审批/提问是**可应答的服务器请求**：原样 echo `rpcId`，走 `POST /api/respond`。
- `tool/call` / `tool/result` 帧自带 host 算好的渲染意图（`generic` / `terminal` / `diff` + locations），App 不必认识每个工具就能渲染。
- 事件类型是 merge-extensible 的开放集合，App 对未知类型必须降级渲染而不是崩。

完整 API 清单见 [dsh-api-inventory.md](dsh-api-inventory.md)。

## 安装与配置流程（摩擦点逐个消灭）

1. **电脑端一行命令**：`npx @reins/bridle` 。无需先装 dsh：Bridle 探测本机 dsh（默认端口、`~/.dsh`、运行中进程），没有就引导装/起。
2. **自动起 dsh**：Bridle 可托管 `dsh web` 子进程，崩溃自动重启，端口冲突自动换。
3. **配对零输入**：终端直接画 QR；同时给一个本机页面。不能扫码时有 8 位短码可手输。
4. **App 端三步**：装 App → 扫码 → 用。无账号、无密码、无端口转发、无证书。
5. **持久化**：Bridle 可 `--install-service` 装成 launchd 常驻，开机自启；`reins status` 一眼看清。
6. **多机**：一个 App 可配多台电脑，顶部切换器切换，各自独立密钥。

## 仓库结构

```
bridle/   Node CLI：加密通道、dsh 代理、配对、进程托管
relay/    Node 服务：哑管道，可部署 Fly/Railway/自建
ios/      SwiftUI App：Reins
docs/     架构与 API 清单
```
