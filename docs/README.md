# 文档索引

四份文档，职责不重叠。按需要读，不必按顺序。

| 文档 | 回答什么 | 谁该读 |
|---|---|---|
| [`architecture.md`](architecture.md) | **为什么这样设计**，接缝在哪，新功能落在哪 | 要改这个系统的人；review 设计的人 |
| [`protocol.md`](protocol.md) | **线上到底是什么字节**，精确到位 | 要写第三方客户端、或重新实现任一端的人 |
| [`fold.md`](fold.md) | **事件如何变成屏幕上的东西**，逐事件规则与边界情况 | 要写任何一个客户端的人 |
| [`dsh-api-inventory.md`](dsh-api-inventory.md) | dsh 的 44 个客户端方法与四象限 RPC 模型 | 要调用 dsh 的人 |
| [`deployment.md`](deployment.md) | Relay 怎么部署，DNS 怎么配，上架前还缺什么 | 要把它跑起来的人 |

## 规格等级

不是每一节都同等成熟，读的时候要知道自己在读哪一种：

**规范级** —— 已实现，有测试守着，可照着重新实现：

- `protocol.md` 全部（权威是 `protocol/scripts/emit-vectors.js` 的向量）
- `fold.md` 全部（权威是 `ios/ReinsTests/StoreTests.swift`）
- `architecture.md` §1–§9、§14–§18

**设计级** —— 决策已定、落点已定，但尚未实现，实施前应先补一份规范级文档：

- `architecture.md` §10 推送
- `architecture.md` §11 定时任务
- `architecture.md` §12 多 agent 后端
- `architecture.md` §13 trace

## 冲突时以什么为准

```
测试向量  >  测试  >  代码  >  文档
```

文档与代码不一致时，先判断哪个是对的：如果文档描述的是**应该**的行为而代码没做到，那是代码 bug；如果文档记错了**已经**稳定的行为，那是文档 bug。两种都要修，不要只改一边让它们"看起来一致"。

## 给 AI 编码用的读法

要实现一个新客户端：`protocol.md` → `fold.md` → 跑通向量 → 接真实 Bridle。

要在现有代码里加功能：`architecture.md` §3（三个扩展点）→ 附录（新功能该往哪放）。

要评估一个改动是否安全：`architecture.md` §16（不变量清单），每条都有对应测试。
