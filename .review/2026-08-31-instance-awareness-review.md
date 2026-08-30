# Deep Review 综合结论

VERDICT: NEEDS_FIX

**轮次**：1 / 2
**类型**：design

> 范围：docs/instance-awareness.md（实例感知设计提案）；用户诉求：清晰感知 pair 的哪个 dsh 实例、当前用哪个、实例没启动时 app 内如何指导检查与启动
> Review engine：codex codex-cli 0.148.0（host: claude; engine_source: auto；模型：gpt-5.6-sol effort=high）
> Cursor：disabled（design 类型不启用）
> 维度：基础 goalfit + consistency + feasibility + 信号触发 无
> Phase 2 验证：5 条已派（0 条免验——三组共识全为同引擎，按规则必验）；结果 5 VERIFIED / 0 FALSE_POSITIVE / 0 UNVERIFIABLE
> Repo: /Users/alpha/.walkcode/workspace/reins
> HeadSHA: 224d988（run 启动时）；报告时 HEAD=38d59db —— 偏差已核：前进的提交内容 = 被审文档本身入库 + 与目标无关的 bridle 心跳修复；被审文档三个时点（审查时工作区 / 38d59db / 报告时工作区）字节一致（git diff 证明）
> RunDir: /var/folders/00/s7tt4dgj53v123y8671yb3b00000gn/T/deep-review-reins-224d988-1788105345.VJWm
> 规模：82 行 / 1 文件
> 运行备注：codex work 代理（llm-proxy）不可达（HTTP 000），首轮三维度全部超时；经 DEEP_REVIEW_CODEX_PROFILE="" 切默认 ChatGPT 路由重跑成功，模型不变（gpt-5.6-sol high）
> 模式：默认报告模式（--plan-only，未动被审文件）

## 📋 需求点交付核对

| 需求点 | 状态 | 兑现位置 / 缺口 |
|---|---|---|
| R1 同名可区分 | ⚠️ 部分兑现 | §4.1 覆盖后缀/单实例隐藏；胶囊截断会吃掉尾部后缀 → 见 #4 |
| R2 当前连接可感知 | ✅ 已兑现 | §3-B、§4.1；现有选择器勾选保留 |
| R3 离线分层诊断 | ✅ 已兑现（设计层） | §4.3 三档；数据契约缺口见 #2 |
| R4 行动路径 | ⚠️ 部分兑现 | §4.4 两档有指引；第三档缺失、形态识别待议、命令可能操作错实例 → 见 #1 |
| R5 Rename 可用 | ✅ 已兑现（设计层） | §4.2；重配对覆盖问题见 #5 |
| R6 协议向后兼容 | ✅ 已兑现 | §4.1 可选字段 |
| R7 原则一致 | ✅ 已兑现 | §2/§4.3/§4.5 |

## 🔴🔴 顶级必修

### 1. [Warning] R4 部分兑现（§4.4 急救卡未定稿）
> **一句话**：离线急救方案有整整一档没有指引，且给出的命令可能查错甚至启动错实例。

- **Category**: Completeness ｜ **Requirement**: R4
- **Confidence**: goalfit 1.0, consistency 0.99, feasibility 0.99
- **来源**: goalfit + consistency + feasibility（三维共识）
- **证据**: §4.4 只列"bridle 层死 / dsh 层死"两档；§6 承认 runtime.json 不记安装形态；`bridle/src/identity.ts` 未设 `REINS_HOME` 时固定 `~/.reins`——多身份机器上裸跑 `bridle status`/`bridle start` 默认操作主身份，不一定是手机指的那条。
- **问题**: 实现者拿到的不是可交付的定案；照写会误导插件用户跑独立 Bridle，还可能触发 §8.1 的同身份进程冲突（有单实例锁兜底，但用户看到的是莫名拒绝）。
- **修复**: 三档决策表写全；采用无须识别形态的统一话术（先 `bridle status`，插件形态→重启 dsh，独立形态→`bridle start`）；ready 帧顺带实例目录提示，命令带 `REINS_HOME=<目录>` 前缀，未知时并列两分支并明说；删除对应待议项。
- **回证**: VERIFIED @ 52-58, 79-81

### 2. [Warning] §4.3 三档诊断缺结构化且新鲜的证据 (Symbol: 4.3 分层诊断)
> **一句话**：界面拿到的失败证据是压平的文案和过期状态，撑不起三档判断。

- **Category**: Consistency / Feasibility
- **Confidence**: consistency 0.98, feasibility 0.99
- **来源**: consistency + feasibility（两维共识）
- **证据**: `Tunnel.swift` `dial()` 把各路径失败折成 `[String]`；`WebSocketCarrier` 的 4404 关闭码在进 UI 前已转文案；`MachineSession.harnessDetail` 断线不清除；§5 落点没有状态模型条目。
- **问题**: 实现只能解析可变文案或用上一次的旧证据，多路径同时失败时给错诊断，违背 §9.2 "不断言不知道的事"。
- **修复**: 设计补"连接诊断状态"一节：每轮拨号按路径保留结构化结果（含 relay 关闭码），定义优先级与失效时机；`dshReachable` 仅当前隧道在线时可用；§5 加 `TunnelStatus`/`Frames.swift`/`MachineSession` 条目 + 三组组合测试。
- **回证**: VERIFIED @ 42-50, `dial(...) -> (winner, failures: [String], refusal)`

### 3. [Warning] §4.2 详情页两字段无数据来源 (Symbol: 4.2 Rename)
> **一句话**：详情页要显示的端口和最近连接时间，在非当前机器和重启后根本拿不到。

- **Category**: Feasibility / Consistency
- **Confidence**: consistency 0.97, feasibility 0.98
- **来源**: consistency + feasibility（两维共识）
- **证据**: `PairedMachine` 无这两个字段；`AppModel` 只保留一个活动会话；`harness` 只能在 ready 后取得；落盘缓存与 §2 "不新增落盘状态"冲突；§5 未列相应改动。
- **问题**: 按文档实现不出来，或实现者被迫自行发明持久化，偏离设计原则。
- **修复**: 删"最近一次连上的时间"（无需求支撑，goalfit 同判定）；端口仅当前连接收到 ready 后显示，其余时点明确显示"未获取"；§5 补 `Frames.swift`→`MachineSession` 传递条目。
- **回证**: VERIFIED @ 38-40

## 🔴 高置信

### 4. [Warning] R1 部分兑现（§4.1 胶囊截断吃掉后缀）
> **一句话**：长机器名会把末尾的区分标记截掉，最需要区分的地方还是分不清。

- **Category**: Completeness ｜ **Requirement**: R1 ｜ **来源**: goalfit（单来源）｜ **Confidence**: 0.98
- **证据**: `RootView.swift` `MachineChip` `Text(name).lineLimit(1)`；§4.1 只说"追加指纹首组"，无截断与四位碰撞规则。
- **修复**: 后缀独立渲染、不参与名称截断（名称截中间/头部，后缀恒可见）；指纹首组碰撞时扩展位数直至唯一；补长名/动态字体验收条件。
- **回证**: VERIFIED @ doc:34 + RootView.swift:168-170

### 5. [Warning] §4.2 重配对会无提示覆盖手机端改名
> **一句话**：用户特意改的机器名，重新扫一次码就被电脑端名字冲掉了。

- **Category**: Consistency ｜ **来源**: consistency（单来源）｜ **Confidence**: 0.98
- **证据**: `AppModel.swift` `pair(with:)`：`machine.name = bundle.name.isEmpty ? machines[index].name : bundle.name`。
- **修复**: 设计明确重配对规则：同 device id 命中时保留手机端名称、只更新地址等连接信息；另设显式"恢复电脑端名称"操作；补重配对测试。
- **回证**: VERIFIED @ AppModel.swift:164-169

## 💡 Suggestion（未回证，参考）

- **goalfit I3**（§4.2）"最近一次连上的时间"属范围蔓延——已并入 #3 的修复（删除该字段）。
- **feasibility I4**（§4.2）删除当前机器后详情页可能停留在失效记录：确认删除后先退出详情页再 `unpair`；补两条界面测试。

## ❌ 已驳回

无（5/5 回证全部 VERIFIED）。

## 维度元信息

| 来源 | VERDICT | issues | exit | 备注 |
|---|---|---|---|---|
| dim-goalfit | NEEDS_FIX | 3 | 0 | 首轮 124（llm-proxy 不可达），换默认路由重跑 |
| dim-consistency | NEEDS_FIX | 4 | 0 | 同上 |
| dim-feasibility | NEEDS_FIX | 4 | 0 | 同上 |

## 原始报告

- 各维度：`$RUN_DIR/dim-{goalfit,consistency,feasibility}.md`；回证：`$RUN_DIR/verify-{1..5}.md`
- 元信息：`$RUN_DIR/meta-dim.txt`；身份：`$RUN_DIR/run.json`（含 profile 切换备注）
