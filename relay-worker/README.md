# Relay on Cloudflare Workers

`relay/` 的同一台交换机，换一个底座：Worker 做路由，三个 Durable Object 类持有 socket 和状态。**线上协议一个字节都没改**——`docs/protocol.md` 对两份实现同时有效，同一个 Bridle、同一个 app、同一套 `e2e/` 测试。

现有的 `relay/` 没有动，也不该动。这里是一个平行实现，供决定要不要切的时候比较。

- 为什么要有它：`docs/deployment.md` §1.5 —— 现在的 Relay 是北京一台小机器上的单进程，重启就掐断所有连接，且处于「违规但够不着」的备案灰色地带。
- 为什么可能不要它：见下面「需要拍板的事」，尤其第一条。

---

## 1. 结论

**能跑在免费版。**Durable Objects 自 2025 年起对 Workers Free 开放，只允许 SQLite backend（本实现就是），每天 100,000 次请求 + 13,000 GB-s 时长。按 1 台 Mac + 1 部手机的量级，请求数用掉千分之一，**时长才是真正的约束**：免费额度折算下来是每天约 29 小时的「手机实际连着」的时间，够一个人用，不够一个人把 app 挂在前台一整天再加第二台机器。算式在 §5。

**最大的坑是单帧上限从 64 MiB 掉到 32 MiB**，这是 Cloudflare 运行时的硬限制，代码层面无法绕过，且超限的表现是**整条隧道被 1009 关掉**，不是一个能重试的错误。`docs/protocol.md` §6.2 白纸黑字写着 64 MiB，所以这是一处**协议级不一致，需要人来拍板**（§4）。

第二个坑是免费额度是**日限**：超了就当天不再服务，UTC 0 点重置。Node 版没有这种悬崖。

---

## 2. 撮合模型

### 2.1 问题在哪

Node 版把 deviceId → socket 放在一个进程的 `Map` 里，「查到机器」和「够得着它的 socket」是同一件事。Durable Object 做不到这一点，因为：

> **Bridle 建连时，URL 里没有 deviceId。**它在 WebSocket 升级**之后**的签名消息里（`docs/protocol.md` §6.1）。

而选哪个 DO 必须在升级**之前**决定。`docs/deployment.md` §1「横向扩展」那一节说的就是这件事——当时的结论是"要么把路由键放进建连请求（改协议），要么共享设备目录"。这里走第二条，不改协议。

### 2.2 三个类

| 类 | 用 什么寻址 | 持有什么 | 生命周期 |
|---|---|---|---|
| `Switchboard` | `newUniqueId()`，一条 Bridle 连接一个 | 1 条 Bridle socket + 最多 8 条 app socket | 随 Bridle socket 生灭，**零持久存储** |
| `Exchange` | `idFromName("exchange")`，全局唯一 | 机器目录、`/healthz` 计数、全局上限、限流桶 | 常驻（其实是随时被驱逐再唤醒） |
| `PairCode` | `idFromName(<归一化短码>)`，一个码一个 | 一个待领的 bundle | 被领走或过期即自删 |

### 2.3 一条连接的全过程

```
Bridle 上线
  ws /v1/bridle
    → Worker: newUniqueId() 建一个 Switchboard，把升级请求转过去
    → Switchboard: acceptWebSocket，发 challenge，起 15s 闹钟
    ← Bridle: register{device,key,signature}
    → Switchboard: 验签 + 验 deviceId == sha256("reins-device"‖key)[0..16]
    → Exchange.register(device, name, version, 自己的 DO id)
        ├ 超过 REINS_MAX_MACHINES → 拒，Switchboard 回 4004
        ├ 该 device 已有别的 Switchboard → 让旧的 displace()（旧 socket 4000）
        └ 写 m:<device> → {switchboard, name, version, since, circuits}
    → Switchboard: 发 registered

手机接入
  ws /v1/app?device=X
    → Worker: Exchange.locate(X, 调用方 IP)
        ├ 令牌桶不够 → 4029
        ├ 目录里没有 → 4404
        ├ 全局 circuit 超上限 → 4008
        └ 返回 switchboard 的 DO id
    → Worker: idFromString(...) 把升级请求转给那个 Switchboard
    → Switchboard: 满 8 条 → 4008；否则分配 circuit id，
                   给 Bridle 发 Open 帧，Exchange.circuits(+1)

转发（此后不再有任何跨 DO 调用）
  app → Switchboard → 前面加 5 字节 mux 头 → Bridle
  Bridle → Switchboard → 剥掉 5 字节 → 对应 circuit 的 app socket
```

**两端在同一个对象里**，所以转发是一次内存操作。任何让 app 和 Bridle 落在不同 DO 的设计，都要为每一帧付一次网络跳转——而 Relay 的全部工作就是帧。

### 2.4 Hibernation 不是优化，是前提

普通 `ws.accept()` 持有的 socket，**从建连到断开的整段时间都按 wall-clock 计时长费**（[官方原文](https://developers.cloudflare.com/durable-objects/platform/pricing/)：`Calling accept() on a WebSocket in an Object will incur duration charges for the entire time the WebSocket is connected`）。一台 Bridle 挂 24 小时就是 86,400 秒 × 0.125 GB = **10,800 GB-s，占掉免费额度的 83%，而它什么都没干**。两台就超。

所以全部用 `state.acceptWebSocket()`。代价是：**休眠会清空内存状态**，构造函数会重跑。于是这个实现里没有任何实例字段承载连接状态——

| 需要记住的东西 | 放哪 | 为什么不能放内存 |
|---|---|---|
| 注册 challenge 的 nonce | Bridle socket 的 `serializeAttachment` | 挑战和应答之间隔着 15 秒，足够被驱逐 |
| 机器名 / 版本 / deviceId | 同上 | 同上 |
| 下一个 circuit id | 同上（`nextCircuit`） | 放 storage 会给每次接入加一行写；放这里随 socket 生灭 |
| 哪条 socket 是哪条 circuit | `acceptWebSocket` 的 tag：`c:<id>` | tag 由运行时维护，休眠后 `getWebSockets("c:3")` 照样找得到 |
| 已经拆过的 circuit | attachment 里的 `role: 'gone'` | 一条 socket 可能被本对象关掉**又**上报自己关闭，拆两次会给 Bridle 发一份它已经忘掉的讣告 |

`relay-worker/tests/worker.test.js` 里那条「a circuit still routes after a long idle」盯的就是这一条：把 circuit 表放进实例字段的写法，在那里会静默失联。

### 2.5 全局单例的代价

`Exchange` 是一个对象。它在**第一次被访问的地方**落地，之后所有机器注册、手机接入、`/healthz`、短码槽位都要跑一趟那里。

- 这个量级（个位数机器、每天几百次连接）完全不是问题，而且它**只在连接时**被访问，数据帧永远不经过它。
- 真到了需要分片的时候，改法是明确的：把目录拆成 per-device 的 hub（`idFromName("m:"+deviceId)`），`/healthz` 的全局计数另外用一个 census 对象维护。代价是每次接入多一跳、多一个类。
- 现在不做，理由和 `docs/deployment.md` §1 一样：**在有真实负载之前，跑一个实例并把它做对，比提前分片更诚实。**

---

## 3. 短码

`GET /v1/pair/claim?code=` **只带一个码，不带 deviceId**。这是整个移植里唯一一个"Node 版随手就能做、DO 版必须重新设计"的点。

**做法：按短码本身建 DO。**`idFromName(normalizeShortCode(code))`。

| 关心的性质 | 怎么保证 |
|---|---|
| 能路由 | 领取方知道码，码就是地址，一跳到位，不需要任何索引 |
| 一次性 | `claim()` 在**同一个对象内部**先删后返（`deleteAll()` 然后返回内存里那份），是一次存储操作，不是两个请求赛跑 |
| 每机器 3 个待领 | 计数在 `Exchange` 的 `o:<device>` 行上——只有那里能"每台机器一个地方"地数。发码时先占槽再写 bundle，领走后 `waitUntil` 把槽还回去 |
| 15 分钟上限 | Worker 侧 `min(expiresAt, now+15min)`，同一个值同时给 `PairCode` 和 `Exchange`，两边同时失效 |
| 过期不留垃圾 | `PairCode` 给自己设一个到期闹钟自删；`Exchange` 设一个"最近一个到期时刻"的闹钟批量清槽位并修正 `/healthz` 的 `offers` |
| 不缓存 | 所有 JSON 响应带 `cache-control: no-store`。缓存住一次领取等于把一次性的码变成可重放的 |

**bundle 在 Relay 里始终是一段 JSON 文本**，从收到到发出都没有被解析过一次（响应是 `{"bundle":` + 原文 + `}` 拼出来的）。这不是性能考虑，是让"内容盲"在这个唯一需要暂存用户数据的地方也成立。

码空间 28^8 ≈ 3.8×10^11，DO 命名空间天然分散，不存在热点对象。

---

## 4. 单帧 32 MiB —— 阻塞性，需要拍板

### 4.1 确切数字

> "WebSocket messages received by a Worker have a size limit of **32 MiB (33,554,432 bytes)**. If a larger message is sent, the WebSocket will be automatically closed with a `1009` "Message is too large" response."
> —— [Workers Runtime API · WebSockets](https://developers.cloudflare.com/workers/runtime-apis/websockets/)

> Durable Objects 限制表：`WebSocket message size` = **32 MiB (only for received messages)**
> —— [Durable Objects · Limits](https://developers.cloudflare.com/durable-objects/platform/limits/)

> "The maximum WebSocket message size limit for all Workers has been increased from 1 MiB to 32 MiB."（2025-10-31，适用于 Workers / Durable Objects / Browser Rendering）
> —— [Changelog](https://developers.cloudflare.com/changelog/post/2025-10-31-increased-websocket-message-size-limit/)

**注意 2025-10-31 之前这个数是 1 MiB。**任何更早的资料（包括很多社区帖子）都过时了；也就是说这件事在一年前根本不可行。

### 4.2 实测（本地 `wrangler dev`，真 Bridle + 参考实现的 phone）

| 单帧 | 上行（app→Relay→Bridle） | 下行（Bridle→Relay→app） |
|---|---|---|
| 30 MiB | 通过，1.5 s | 通过，1.1 s |
| 33 MiB | **隧道被关闭**，客户端只看到 `disconnected` | **隧道被关闭** |
| 40 MiB | 同上 | 同上 |

失败形态是关键：**不是一个能重试的错误码，是整条隧道断掉**。App 侧看到的是 `code: "disconnected"`，会自动重连并 `resume{since}`，然后**再发一次同样的大帧，再断一次**。没有任何一层能告诉用户"这个文件太大了"。

（Node 版其实是同一类失败——`ws` 的 `maxPayload` 超限也是 1009——只是门槛在 64 MiB。）

### 4.3 影响面

两个方向都要减：Bridle→Relay 那一段还多了 5 字节 mux 头，所以隧道净载荷上限是 **32 MiB − 5 字节 − Noise 的 16 字节 tag**。附件走 base64 塞在 JSON 里（`docs/deployment.md` §1 的原话：「附件走 base64 在 JSON 里，图片和大文件读取会撑到这个量级」），base64 涨 4/3，所以：

- 能过：约 **24 MiB 以内**的原始文件 / 图片 / 单次文件读取。
- 会断：超过这个量的单次 `session.prompt` 附件、整仓库级别的文件读取返回、大图。

日常对话、diff、终端输出离这个量级很远。真正的问题是"用户拍了一张 30 MB 的原图丢进去"这种事，一旦发生就是隧道反复断，而不是一句提示。

### 4.4 三个选项（我没有替你选）

| 选项 | 代价 | 谁要改 |
|---|---|---|
| **A. 接受降级** | 改 `docs/protocol.md` §6.2 的表（64 MiB → 32 MiB），并在 Bridle 侧加一个"帧太大"的本地拒绝，让它变成 `res{ok:false}` 而不是断链 | Bridle 一处 + 文档；协议表格变更 |
| **B. 隧道层分片** | 帧上加 `chunk` 语义，两端都要实现重组。**这是协议变更**，而 app 已经在用户手机上 | 协议 + Bridle + iOS + 参考实现 + 向量 |
| **C. 不切换** | Relay 继续跑在北京那台机器上，本目录只作为备选方案存档 | 无 |

**我没有改协议，也没有偷偷把 64 写成 32 假装没事。**`src/limits.ts` 里的 `RUNTIME_MAX_FRAME_BYTES` 只是把这个事实写下来，代码不 enforce 它——enforce 的是运行时，在我们的代码跑到之前就已经把 socket 关了。

---

## 5. 免费额度测算

### 5.1 额度与计费口径

| 项 | 免费额度 | 来源 |
|---|---|---|
| DO 请求 | 100,000 / 天 | [DO Pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/) |
| DO 时长 | 13,000 GB-s / 天 | 同上 |
| DO 存储（仅 SQLite backend） | 5 GB；5M 行读 / 天，100k 行写 / 天 | 同上 |
| Worker 请求 | 100,000 / 天 | [Workers Limits](https://developers.cloudflare.com/workers/platform/limits/) |
| Worker CPU | 10 ms / 请求 | 同上 |

计费口径里有三条决定了这套东西能不能白嫖：

1. **入站 WebSocket 消息按 20:1 折算**（"a 20:1 ratio is applied to incoming WebSocket messages"）。
2. **出站 WebSocket 消息不计费**（"There is no charge for outgoing WebSocket messages"）。
3. **休眠中的对象不计时长**（"Durable Objects that are idle and eligible for hibernation are not billed for duration"），且**协议层 ping 帧由运行时自动回 pong，不唤醒对象**（[WebSockets best practices](https://developers.cloudflare.com/durable-objects/best-practices/websockets/)）。

第 3 条对我们特别重要：Bridle 每 20 秒发一次 WS 协议 ping（`bridle/src/relay-client.ts` 的 `KEEPALIVE_MS`），**这些 ping 不会把对象叫醒**，所以一台没有手机连着的 Mac 常连一整天，时长成本约等于零。

所有 DO 都按 **128 MB = 0.125 GB** 计时长，与实际用量无关。于是 13,000 GB-s ÷ 0.125 GB = **104,000 对象·秒 / 天 ≈ 28.9 小时**。

### 5.2 1 台 Mac + 1 部手机，手机每天连 1 小时，几百条消息

**请求数**

| 来源 | 每天 | 折算后计费请求 |
|---|---|---|
| Bridle 上线（升级 + 注册消息 + `Exchange.register`），按重连 10 次算 | 10 × 4 | 40 |
| 手机接入/断开（`locate` + 转发 + `circuits±1`），按 5 次算 | 5 × 4 | 20 |
| 隧道 ping/pong：手机在线时每 25 秒一轮，每轮 2 条入站（Bridle 的 ping、手机的 pong） | 3600/25 × 2 = 288 条 | 288 / 20 ≈ 15 |
| 业务消息：300 次往返 = 600 条入站 | 600 条 | 600 / 20 = 30 |
| `/healthz`、`/v1/machine` 等 HTTP | ~20 | 20 |
| **合计** | | **≈ 125 / 100,000 = 0.13%** |

Worker 请求只有 HTTP 和升级本身（WS 消息不再经过 Worker），约 40 次/天。

**时长（真正的约束）**

手机连着的时候，隧道每 25 秒有一次 ping（`docs/protocol.md` §4.2，Bridle 侧 `PING_INTERVAL_MS`）。Cloudflare 只说对象"空闲一小段时间后"被驱逐，**没有给出这个数**（本地实测闹钟晚约 10 秒，只能算旁证）。所以这里按最坏情况算，即"手机在线期间对象一直常驻"：

```
手机在线 1 小时 = 3,600 秒 × 0.125 GB = 450 GB-s
450 / 13,000 = 3.5%
```

没有手机连着的 23 小时：只有协议 ping，不唤醒，≈ 0。

**存储**：每台在线机器一行（约 200 字节），每个待领短码一行。行写入是"每次注册/接入/断开各一两行"，一天几十行，对着 100k/天。

### 5.3 什么时候会爆

| 场景 | 每天时长 | 占比 |
|---|---|---|
| 手机每天连 1 小时 | 450 GB-s | 3.5% |
| 手机每天连 4 小时 | 1,800 GB-s | 14% |
| 手机 24 小时常连（app 常驻前台 + 常亮） | 10,800 GB-s | **83%** |
| 两台机器各自 24 小时常连手机 | 21,600 GB-s | **超** |
| 不用 Hibernation（`ws.accept()`），一台 Bridle 常连 | 10,800 GB-s | **83%，且什么都没干** |

一句话：**免费额度买的是"手机连着的小时数"，每天约 29 小时**。它跟你发了多少消息几乎无关。

**超了会怎样**：免费额度是日限，超出后该类操作直接失败，UTC 0 点重置。也就是"下午三点开始 Relay 不服务了，第二天早上八点自己好了"。Node 版没有这种失败模式，这一条要单独接受。

---

## 6. 容量上限在 DO 模型下还有没有意义

有，但**保护的东西变了**，所以默认值的理由也变了。

| | Node 版 | Worker 版 |
|---|---|---|
| `REINS_MAX_MACHINES` | 防止一台 1 GB 的机器耗尽文件描述符和内存 | 没有那台机器了。它现在防的是**别人用你的免费额度**：机器身份就是一对密钥，谁都能造一万个，一万条常连就是每天 108,000 GB-s |
| `REINS_MAX_CIRCUITS` | 同上，兜内存 | 同上，且它是 `/healthz` 那个数字的兜底 |
| 每机器 8 条 circuit | 协议 | **不变**，由 `Switchboard` 数自己的 socket 决定，是权威 |
| 每设备 3 个待领短码 | 协议 | **不变**，由 `Exchange` 的槽位表决定 |

两个全局上限继续从 `wrangler.jsonc` 的 `vars` 读，默认 1000 / 4000 不变。但要诚实说一句：**它们现在是软的**——`Exchange` 的计数是各个 `Switchboard` 上报的镜像，如果一个 `Switchboard` 在没跑完 close 回调的情况下消失，计数会偏高（偏保守，不会放行超额）。真正硬的限制是 Cloudflare 的日额度本身。

---

## 7. 与 Node Relay 的行为差异

线上字节全都一样，下面这些是可观察但不改协议的差异。

| # | 差异 | 影响 |
|---|---|---|
| 1 | 单帧上限 64 MiB → 32 MiB | §4，**需要拍板** |
| 2 | 注册超时闹钟本地实测晚 10 秒（15s 设定 → 25s 才关） | 只影响"连上但从不注册"的 socket；Bridle 自己 15 秒就放弃了。生产环境未测 |
| 3 | 被顶替的旧连接，其上的手机会收到 4004 明确关闭 | Node 版是把旧 machine 对象丢掉，手机的 socket 静默变成死链。**这里更正确**，但行为不同 |
| 4 | `uptimeSeconds` 是「Relay 第一次应答至今」，不是进程存活时间 | 没有进程了。`/healthz` 的语义变成"这套部署跑了多久" |
| 5 | `/healthz` 的计数是账本，不是实时统计 | 可能偏高（对象非正常消失时）。Node 版是从活着的 Map 现算的 |
| 6 | 限流桶在 `Exchange` 被驱逐时清零 | 被攻击时对象是热的，桶不会丢；闲下来清零无所谓 |
| 7 | `GET /install` 恒 404 | 官方部署本来就靠边缘 Redirect Rule（`docs/deployment.md` §2），Worker 不该碰它 |
| 8 | 部署产物没有排空（drain）流程 | 也不需要：更新 Worker 代码不会断开已有的 hibernation socket |
| 9 | 日额度悬崖 | §5.3 |

---

## 8. 跑起来

```sh
npx wrangler types --config relay-worker/wrangler.jsonc     # 生成 worker-configuration.d.ts（未入库）
npx wrangler dev   --config relay-worker/wrangler.jsonc
```

验收（本目录已实际跑通，结果见下）：

```sh
# 1) 部署验收标准，打本地 Worker
npm run build
REINS_E2E_RELAY_URL=ws://127.0.0.1:8787 node --test e2e/tests/deployed.test.js

# 2) 短码那条路（deployed.test.js 不覆盖）
REINS_WORKER_URL=ws://127.0.0.1:8787 node --test relay-worker/tests/worker.test.js
```

部署（**目前没有部署过**）：

```sh
npx wrangler deploy --config relay-worker/wrangler.jsonc
```

切域名之前必须做的两件事：

1. 把 `wrangler.jsonc` 里注释掉的 `routes` 打开——**只能是 `/healthz` 和 `/v1/*` 两条，绝不能是 `/*`**。`/*` 会同时吞掉 `/install` 的 Redirect Rule 和 `site` 那四个静态页，而它们全都还会返回 200，看起来一切正常。
2. 先删掉（或改指向）`reins.novabox.ai` 那条指向 Cloudflare Tunnel 的 CNAME 之前，确认 Worker 路由已经生效——两者绑在同一个 hostname 上。

---

## 9. 实际验证了什么

| 用例 | 结果 |
|---|---|
| `deployed.test.js`「the deployed relay answers」 | ✅ |
| `deployed.test.js`「a phone pairs and drives a machine through the deployed relay」 | ✅ 含流式下行 |
| `deployed.test.js`「the relay forgets a phone that hangs up」 | ✅ circuit 计数回落 |
| `deployed.test.js`「a real harness is reachable through the deployed relay」 | ✅ 打的是本机真实 dsh |
| `deployed.test.js`「the installer comes from the repository」 | ❌ 本地没有边缘 Redirect Rule，属于边缘配置不属于 Relay |
| `deployed.test.js`「the pages the app links to exist」 | ❌ 同上，那是 `site` worker 的四个页面 |
| 短码 offer → claim → 用领到的 bundle 完成握手 | ✅ |
| 同一个码领第二次 | ✅ 404 |
| 一台机器第 4 个待领短码 | ✅ 429；领走一个后又能发 |
| 伪造 device id 的 offer | ✅ 403 |
| 4 MiB 单帧双向 | ✅ |
| 30 / 33 / 40 MiB 单帧 | ✅ 测出 32 MiB 天花板，见 §4.2 |
| 长时间空闲后 circuit 仍可用 | ✅ 40 秒 |
| 同机器第二条连接顶掉第一条 | ✅ `/healthz` 机器数不变，手机连到新的那条 |
| 第 9 部手机 | ✅ 被拒 |
| 连上不注册 | ✅ 4001（实测 25 秒，见 §7.2） |
| 机器离线时手机接入 | ✅ 4404 + 原文 reason，`WebSocketCarrier.swift` 认这个码 |
| 短码过期自动清理 | ✅ `/healthz` 的 `offers` 归零 |

**没验证的**：真实部署（没有部署到你的账号）、真实 Cloudflare 网络上的 hibernation 计费行为、免费版 10 ms CPU 限制是否作用于 DO 调用（文档只说 DO 是 30 秒/请求，两处口径没有对上，而转发 30 MiB 帧要做一次整块拷贝）、多 colo 下 `Exchange` 单例的延迟。

---

## 10. 需要拍板的事

1. **单帧 64 MiB → 32 MiB**（§4）。接受降级 / 做隧道分片（改协议）/ 不切换。**这条不定，其它都不用谈。**
2. **接受日额度悬崖**：超了当天不服务（§5.3）。要不要同时保留北京那台机器做兜底。
3. **接受绑死 Cloudflare**：DO 没有等价物，换供应商等于再写一次。
4. `worker-configuration.d.ts` 和 `.wrangler/` 我加进了 `.gitignore`（前者 12,855 行生成物，后者是每次 `wrangler dev` 都会变的本地 SQLite）。如果你更希望入库，改回来即可。
5. `Exchange` 落在第一次访问它的地区。要不要用 `locationHint` 钉一个（比如 `apac`）。
