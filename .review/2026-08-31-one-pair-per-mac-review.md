# Deep Review 综合结论

VERDICT: NEEDS_FIX

**轮次**：1 / 2
**类型**：design

> 范围：docs/one-pair-per-mac.md（一机一配对，实例归 Bridle 配置）
> Review engine：codex codex-cli 0.148.0（host: claude; engine_source: auto；模型：gpt-5.6-sol effort=high；llm-proxy 不可达，走默认 ChatGPT 路由）
> Cursor：disabled（design 类型不启用）
> 维度：基础 goalfit + feasibility；**consistency 两次 540s 超时，标 unavailable**（覆盖不完整，但存活 Warning 已定 NEEDS_FIX，结论不受影响；重跑建议在公司代理恢复后）
> Phase 2 验证：7 条已派（2 组共识代表 + 5 单来源）；结果 7 VERIFIED / 0 FALSE_POSITIVE / 0 UNVERIFIABLE
> Repo: /Users/alpha/.walkcode/workspace/rowel ｜ HeadSHA: 8e1c67c ｜ RunDir: /var/folders/.../deep-review-rowel-8e1c67c-1788160614.ZE3v
> 规模：95 行 / 1 文件 ｜ 模式：--plan-only（未动被审文件）
> 附注：run_parallel.sh 第 141 行自身有乱码字节，AUTH 嫌疑分支触发时脚本崩溃（`CODEX_MODEL�: unbound variable`）——上游 skill 的 bug，值得回报；本轮产物未受影响

## 📋 需求点交付核对

| 需求点 | 状态 | 缺口 |
|---|---|---|
| R1 一机一配对成为事实 | ⚠️ | 只改措辞不改机制，换 HOME 仍可造第二配对 → #1 |
| R2 实例配置可增删改 | ⚠️ | 命令有了，运行中生效规则没有 → #6 |
| R3 电脑端 list（含发现） | ⚠️ | probeDsh 只返回首个应答者，发现范围留待议 → #3 |
| R4 手机端 list/选择 | ✅ | §3/§5 |
| R5 选择生效于全部功能 | ⚠️ | 只隔离了会话缓存，游标/审批/提问/折叠等全漏 → #2 |
| R6 安全模型不变 | ✅ | §2 |
| R7 兼容与迁移 | ⚠️ | 有矩阵，无回滚；reset 不可逆 → #7 |
| R8 多实例 wake 不聋 | ⚠️ | pending 有实例维度，attach 计数没有 → #4 |

## 🔴🔴 顶级必修（跨维共识 + VERIFIED）

1. **[W/R1] 机器级唯一约束缺失**（goalfit+feasibility）——"推荐形态、机制不改"使 R1 沦为口号；需固定位置的机器级锚/锁，旧身份仅限迁移用途并给出退出期限。
2. **[W/R5] 实例状态隔离不完整**（goalfit+feasibility）——`Tunnel.highestSeq`、MachineSession 的 sessions/workspaces/archived/approvals/questions/defaultModel、折叠持久化键全部单份；切实例=旧状态滞留+迟到回写打错实例。需完整状态所有权定义+代际丢弃+切换验收矩阵。

## 🔴 高置信（单来源 + VERIFIED）

3. **[W/R3] 发现契约缺失**——probeDsh 契约是"第一个应答者"，多实例必漏；需全量收集+host.describe 验证+与配置/注册表合并。
4. **[W/R8] 全局 attach 计数压死另一实例的 wake**——`flushWake` 在 `core.attached>0` 直接返回；连着甲时乙的审批永久无人知晓。计数必须按实例。
5. **[W] (peer,instance) 重放缓冲内存相乘**——正确形状：每实例一份共享 EventLog + 每手机一个游标；补删除生命周期与总预算。
6. **[W/R2] 配置变更无生效规则**——首版应明确"改完须重启"，或定义热更协调器；删当前/默认实例的行为要写。
7. **[W] 迁移无回滚**——reset 不可逆；需分阶段迁移 + dshUrl/instances 双写一个版本期 + 降级命令。

## 维度元信息

| 来源 | VERDICT | issues | exit |
|---|---|---|---|
| dim-goalfit | NEEDS_FIX | 3 | 0 |
| dim-feasibility | NEEDS_FIX | 6 | 0 |
| dim-consistency | unavailable | — | 124×2（默认路由超时） |

原始产物见 RunDir。
