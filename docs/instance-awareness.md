# 设计：实例感知（哪个 dsh、连着谁、死了怎么办）

状态：v2（2026-08-31）。v1 经跨模型 deep-review 判 NEEDS_FIX（5 条 Warning 全部回证坐实，报告见 `.review/2026-08-31-instance-awareness-review.md`），本版逐条吸收。源于真实使用中的三次踩坑，全部发生在同一周。

## 1. 问题（全部来自实况，不是假想）

一台 Mac 跑了两个 bridle 身份（真环境 + 演示环境）之后，产品的"pair Macs"心智模型出现四道裂缝：

1. **同名不可辨。** 两条记录都叫 `alphadeMacBook-Pro`——顶部胶囊、机器列表、离线横幅全都分不清谁是谁。机器名默认取 hostname，同一台 Mac 上的第二个身份必然同名。
2. **断连时最显眼的出口是最具破坏性的那个。** Settings 里机器行的唯一动作就是 Forget（整行点击即进解除配对确认）；用户面对离线的第一反应真的就是"只能点 forget 了对吧"。Rename 在模型层存在（`AppModel.rename(machine:to:)`），但**没有任何 UI 调用它**——死能力。
3. **离线空态没有行动路径。** "The Mac is asleep, off your network, or Bridle isn't running on it." 三种可能并列，一个都没告诉用户怎么验证、怎么修。
4. **配对的真实单位与产品语言不一致。** 实际配对的是 bridle 身份（一个 `REINS_HOME` 的密钥对），身份指向一个 dsh 实例；"pair Macs" 在一机一实例时成立，多实例时心智断裂。

## 2. 设计原则（承接既有 UI 硬规则）

- **派生优先**：能从已有事实推导的，不新增任何落盘状态。唯一例外见 §4.3 的诊断状态——它是对**本轮**连接尝试的结构化记录（内存态，随下一轮拨号作废），不是跨启动的记忆。
- **不断言不知道的事**（硬规则 #3）：收窄可能性只能用 app 真正持有的证据。
- **破坏性操作要能被找到、也要说清代价**（硬规则 #4）——但不该是唯一能被找到的动作。
- 产品语言分工（2026-08-31 定版，取代早先"保持 Mac"）：**配对与会话的单位说 dsh**（"Pair another dsh" / "Paired dsh"——一台 Mac 可以跑两个，每条配对就是其中一个）；**物理机器的状态说 Mac**（睡眠、网络、在不在房间）；每条配对的显示名仍是机器名（撞名加指纹后缀），因为人靠机器认东西。"bridle 身份"仍是实现词汇，不进 UI。

## 3. 用户需要感知的四个事实与对应证据

| 事实 | app 的证据 |
|---|---|
| A. 这条记录是谁 | 机器名、指纹、relay 设备 id；（本提案后）harness 端口与实例目录提示 |
| B. 现在连着哪条 | `active.machine.id` ✓ 已有 |
| C. 死的是哪一层 | relay 关闭码（4404 = bridle 未注册）、直连超时、`dshReachable`——证据存在但今日被压成文案，见 §4.3 |
| D. 死了怎么办 | 无。今日全靠用户脑补 |

## 4. 方案

### 4.1 身份可辨（A）——两层，都是派生

**冲突后缀（app 侧，零协议改动）**：当且仅当两条配对记录显示名相同，所有同名记录获得指纹后缀（如 `F943`）。

- **后缀独立渲染，永不参与截断**（review #4）：机器名与后缀是两个视图元素；名称过长时截名称（头部或中部省略），后缀恒可见。禁止把后缀拼进名字字符串再 `lineLimit(1)`——那正是把区分标记送去被截掉。
- **碰撞规则**（review #4）：指纹首组（4 位）仍相同则扩展到 8 位、12 位，直至组内唯一。
- 纯函数（`[PairedMachine] → 每条的 (显示名, 后缀?)`），只影响显示，不落盘。单机器用户永远看不到后缀。
- 生效面：顶部胶囊、机器列表行、离线空态与横幅里的机器名。
- 验收：20 字符以上机器名 + 最大动态字体下，两条同名记录在胶囊处仍可肉眼区分。

**harness 端口与实例目录（协议可选字段）**：ready 帧新增可选 `harness: { url, home }`——bridle 的 `state.dshUrl` 与自己的 `REINS_HOME` 实际值。app 在机器详情与急救卡使用。老 bridle 不发此字段，app 不显示，向后兼容（协议 §14 版本纪律照旧）。

> 安全评估（v1 待议，已议）：配对方本就可经隧道调 `host.describe` 看到 cwd/home 等信息，loopback 端口与 home 目录对**已配对设备**不构成新的信息类别；字段只进 Noise 隧道内的 ready 帧，relay 依然只见密文。

### 4.2 Rename 从死能力变活（B/A）

Settings 机器行改为进入**机器详情页**：

- 名称（可编辑，即 `AppModel.rename` 的 UI 化）
- 指纹（既有字段）
- harness 端口：**仅当前连接收到 ready 后显示**；其他机器与冷启动后显示"上次连接时为 :3081"式的缓存**不做**（review #3）——没有数据来源就明说"连接后可见"，不发明持久化
- Forget：红色、置底，保留二次确认与"单向性"说明；行上 swipe 保留
- ~~最近一次连上的时间~~（v1 有，review #3/goalfit 判范围蔓延，删）

**重配对不覆盖手机端改名**（review #5）：`pair(with:)` 在同 device id 命中时保留手机端名称，只更新地址、token 等连接信息；详情页提供显式"使用 Mac 的名字"操作恢复。补重配对测试。

**删除时序**（review 建议项）：详情页内确认 Forget 后先退出详情页，再执行 `unpair`——`unpair` 会触发 `restoreLastConnection()` 切换活动机器，页面不得停留在已删除记录上。补删除当前/非当前机器两条界面测试。

### 4.3 分层诊断（C）——先把证据变成结构，再收窄陈述

**前置：连接诊断状态**（review #2，这是本节的地基）。今日 `Tunnel.dial()` 把各路径失败折成 `[String]` 文案，relay 的 4404 关闭码进 UI 前已丢失，`harnessDetail` 断线后不清除——按文案分档等于解析自己的展示字符串，且可能拿上一轮的旧证据下结论。改为：

- 每轮拨号产出结构化 `DialDiagnosis`：按路径（direct×N / relay）记录 `{ 路径, 结果: 超时|拒绝(关闭码)|不可达 }`；relay 关闭码（4404 等）原样保留
- 生存期 = 到下一轮拨号开始；隧道建立即作废——**旧证据不许给新断线作证**
- `dshReachable` 仅在当前隧道在线时可用；隧道断开即视为未知
- §9.2 派生：这是对本轮尝试的记录，不是跨启动记忆，不落盘

**三档空态文案**（基于上述结构）：

| 证据 | 空态首行 |
|---|---|
| relay 路径拒绝且关闭码 4404 | "Bridle 没有连上中继——Mac 睡了，或 Bridle 没在跑。" |
| 隧道在、`dshReachable: false` | "Bridle 在线，但它连不上这台 Mac 上的 dsh。" |
| 直连超时且 relay 路径不可达（网络层失败，非 4404） | 保留现状三选一（此时确实无法收窄，不装懂） |

测试三组组合：直连超时+relay 4404；relay 自身不可达；dsh 不可达后隧道断开（旧证据必须作废）。

### 4.4 急救卡（D）——三档全覆盖，只指导，不越权

离线空态在诊断行下方加可展开的 "On the Mac" 卡片。**统一话术，不猜安装形态**（review #1）：第一步永远是查真相的命令，第二步按查到的结果分支——把形态判断交给 `bridle status` 的输出，而不是 app 的猜测。

| 档位 | 卡片内容 |
|---|---|
| bridle 层死（4404） | ① 跑 `REINS_HOME=<目录> bridle status`（有 §4.1 的 home 提示则代入；没有则给不带前缀的命令并注明"若配了多个身份，用 REINS_HOME 指向对应目录"）② 按输出分支：显示"由 dsh 插件运行"→ 重启 dsh；显示未运行 → `bridle start`（同样带目录前缀） |
| dsh 层死（隧道在、dshReachable=false） | 说明"Bridle 活着、harness 不在"，给 `dsh web` 与端口提示（§4.1 的 harness url 有则代入） |
| 网络层失败（第三档，v1 缺失） | ① 确认 Mac 醒着、和手机同网或能出公网 ② Mac 上 `curl <relay>/healthz` 验证出网 ③ 通了还连不上再看 `bridle status` |

配套（bridle 侧小改动）：`bridle status` 输出增加一行运行形态（"running inside dsh (plugin)" / "running standalone"）——插件的 runtime.json 快照加一个 `via: 'plugin' | 'cli'` 字段即可，两个入口各写各的，零探测。

命令一律拼成 `npx @reins/bridle status` 形式，不写裸 `bridle`：插件安装只把 CLI 落进 profile 的 `node_modules`，不进用户 PATH——纯插件用户敲 `bridle` 是 command not found。npx 对两种形态都成立（发包后）。

文案明说 app 无法远程执行——隧道是唯一通道，机器侧死了只能人到场。这是诚实，也是安全边界。

### 4.5 明确不做

| 不做 | 理由 |
|---|---|
| app 远程拉起 bridle/dsh | 无通道（通道本身就是死掉的那层）；即便经 relay 加控制通道也等于把开机权交给电话，越权 |
| 同时连接多台机器 | 既有决策（每 socket 一份射频唤醒）不变 |
| 自动改 Mac 侧 machineName | 显示层能解决的不动源头；源头改名仍留给 `bridle.json` 手改或未来 CLI |
| pair 时自动加 " 2" 后缀落盘 | 记忆式方案；冲突消失后缀还赖着，派生方案冲突消失即还原 |
| 非当前机器的端口/时间缓存 | 无诚实数据来源（review #3）；"连接后可见"比一个可能过期的数字更真 |

## 5. 落点

| 层 | 改动 |
|---|---|
| ios `Models.swift` | 冲突标签纯函数（名称+独立后缀、碰撞扩展）+ 单测 |
| ios `Net/Tunnel.swift` | `DialDiagnosis` 结构化拨号结果（保留 relay 关闭码、失效时机）+ 组合测试 |
| ios `Net/WebSocketCarrier.swift` | 关闭码结构化上传（不再只出文案） |
| ios `Store/MachineSession.swift` | 诊断状态承接；`harnessDetail` 断线清除；ready 的 `harness` 字段解码传递 |
| ios `Store/AppModel.swift` | 重配对保留手机端名称 + 测试 |
| ios `RootView` / `SettingsView` | 胶囊/列表用标签（后缀独立渲染）；机器详情页（rename、Forget 降权重、删除先退出）；空态三档 + 急救卡 |
| ios `Protocol/Frames.swift` | ready 可选 `harness { url, home }` 解码 |
| protocol / bridle | ready 帧可选 `harness` 字段；runtime.json 加 `via` 字段；`bridle status` 显示运行形态（`docs/protocol.md` §ready 增补） |
| docs | `architecture.md` §9.2 增补一条硬规则引用本文件 |

## 6. 待议

（v1 的两条待议均已在 §4.4 / §4.1 议决，本节暂空。）
