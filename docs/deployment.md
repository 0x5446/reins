# 部署

全部挂在 **`reins.novabox.ai`** 一个域名下：Relay 的 WebSocket、短码 API、还有 `curl | sh` 拉的那个安装脚本。不需要第二个静态站点——它唯一的内容会是两个说明页。

`novabox.ai` 现状（2026-08-15 查）：

| 项 | 值 |
|---|---|
| 注册商 | GoDaddy |
| DNS | Cloudflare（`cameron.ns.cloudflare.com` / `mina.ns.cloudflare.com`） |
| 邮件 | Cloudflare Email Routing |
| 根域 | 没有 A 记录，没在跑网站 |
| 已用子域 | 没有（www / api / app / relay / docs 全空） |
| 到期 | 2026-10-07 |

`reins.novabox.ai` 是空的，随时能用。

三样东西要上线：Relay、DNS 记录、iOS app。前两样今天就能做，第三样卡在 Apple 那边。

---

## 1. Relay

Relay **没有持久内容，但有连接撮合状态**。它不存数据库、不存明文、没有配置文件，全部配置来自环境变量——但设备、线路、待领短码都在进程内存里（`registry.ts` / `offers.ts`）。

这个区别在部署时是全部：**进程退出会断掉每一条在线连接，并丢掉所有待领短码。**

### 跑起来

```sh
npm install
npm run build
PORT=8787 node relay/lib/main.js
```

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `PORT` | `8787` | 监听端口 |
| `HOST` | `0.0.0.0` | 监听地址 |
| `REINS_INSTALL_SCRIPT` | 仓库里的 `install.sh` | `/install` 返回哪个文件；设成空字符串就关掉这个路由 |

### 路由

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/healthz` | 健康检查，给负载均衡用 |
| `GET` | `/install` | 安装脚本，**默认关闭**，仅自托管时可开 |
| `GET` | `/v1/machine/<deviceId>` | 这台机器现在在不在线 |
| `POST` | `/v1/pair/offer` | Bridle 挂一个短码邀请 |
| `GET` | `/v1/pair/claim?code=…` | app 用短码换配对载荷 |
| `WS` | `/v1/bridle` | Bridle 的常连 |
| `WS` | `/v1/app` | app 的连接 |

`/install` 这条路由**默认关闭**（`REINS_INSTALL_SCRIPT=` 空字符串）。

它存在是给自托管的人用的——自己跑一套时，一个域名一次部署确实省事。但**官方部署不开它**：把安装脚本和公网中继放在同一个部署单元，等于把一次中继入侵放大成对所有新用户的供应链投毒。官方的安装脚本从仓库直接取（§2）。

### 前面要放 TLS

Relay 自己不做 TLS。放在 Caddy / nginx / 云厂商的 LB 后面，证书交给它们。

Caddy 够用，两行：

```
reins.novabox.ai {
	reverse_proxy 127.0.0.1:8787
}
```

WebSocket 不用额外配置，Caddy 默认透传 upgrade。

### 走 Cloudflare（novabox.ai 已经在上面）

DNS 在 Cloudflare，所以最省事的两条路：

**A. 有公网机器** —— A 记录 `reins` 指向那台机器，橙云（proxied）打开。Cloudflare 的代理支持 WebSocket，不用额外开关。源站上放 Caddy 或者直接让 Cloudflare 回源到 8787。

**B. 没有公网机器** —— Cloudflare Tunnel：

```sh
cloudflared tunnel create reins
cloudflared tunnel route dns reins reins.novabox.ai
cloudflared tunnel run --url http://127.0.0.1:8787 reins
```

不用开端口、不用公网 IP，和 Bridle 自己的思路一样。

两条路都要注意的：

- **心跳 25 秒**，比 Cloudflare 的 WebSocket 空闲超时（100 秒）短得多，连接不会被中途掐掉。
- **单帧上限 64 MiB**。Cloudflare 免费版对 WebSocket 消息大小没有明确文档化的限制，但大附件（整个仓库的文件读取、大图）真撞上的时候，先怀疑这一层。要排除嫌疑就临时关橙云（DNS only）对比一次。
- **不要开 Cloudflare 的缓存规则去缓存 `/v1/*`**。短码是一次性的，缓存住等于把它变成可重放的。`/install` 那条已经自己带了 `max-age=300`。

### 内建的限制

这些是硬编码的，不是配置项——它们是协议的一部分，调松了会让滥用变便宜：

| 限制 | 值 | 为什么 |
|---|---|---|
| 单帧最大 | 64 MiB | 附件走 base64 在 JSON 里，图片和大文件读取会撑到这个量级 |
| 注册超时 | 15 秒 | Bridle 连上后必须在这个时间内签名证明身份 |
| 心跳 | 25 秒 | 比常见的 60 秒空闲超时短，穿得过大多数中间设备 |
| 每台机器的并发线路 | 8 | 一个人的几部设备够用，僵尸线路堆不起来 |
| 每设备待领短码 | 3 | 反复 `bridle pair` 不会把短码空间填满 |
| 短码有效期上限 | 15 分钟 | Bridle 请求更长也会被砍到这个值 |

全局上限是**容量而非协议**，所以可配，默认保守：

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `REINS_MAX_MACHINES` | 1000 | 机器身份就是一对密钥，谁都能造一万个。没有全局上限，这个免费中继就是别人出钱的通用加密转发器 |
| `REINS_MAX_CIRCUITS` | 4000 | 很多机器各开几条时的内存兜底 |

按每连接约 40 KB 估：1000 台机器 + 4000 条线路 ≈ 200 MB，一台 1 GB 的小机器扛得住。**机器更大就往上调，不要留着默认值假装容量更大。**

全局上限是**硬拒绝**而不是软降级：降级的中继让所有人一起变慢，拒绝一台只让一台失败。已连接的机器重连**不受**上限影响——把正在用的人挤掉是错的那一半。

另有按调用方的令牌桶限流（允许一个突发，然后必须等）。

### 容量

一条线路 = 两个 WebSocket + 一个转发循环，没有解析、没有落盘。瓶颈是文件描述符和带宽，不是 CPU。单进程扛几千条线路没问题。

### 升级：排空，不要重启

单实例阶段用双进程切换：

1. 新进程起在另一个端口，`/healthz` 通过
2. 旧进程停止接受新线路（关掉它的 upgrade 处理）
3. 等已有线路自然结束，或到超时上限
4. 切流量，关旧进程

客户端会自动重连并 `resume{since}` 补齐缺口——但**待领短码不会迁移**，升级窗口内正在配对的人要重新拿一个码。这是可接受的，只要升级不在高峰。

**不做这个的后果**：每次部署都在制造这个品类抱怨最多的那件事（重连丢东西）。

### 横向扩展：现在做不到，原因要说清楚

Relay 按 deviceId 在**进程内存**里撮合两条 socket，app 和 Bridle 必须落到同一个进程。

早期文档建议"按 deviceId 做一致性哈希的 L4 分流"。**那行不通**：Bridle 建连时 URL 里没有 deviceId，它在 WebSocket 建立**之后**的注册消息里，四层负载均衡在建连时拿不到。

要真的多实例，得二选一：

- **把路由键放进建连请求**（URL 查询参数或子域名），代理据此分流，Bridle 随后再用签名证明这个键确实是它的
- **共享设备目录**（Redis 之类），实例间转发

两者都是真实工作量。**在有真实负载之前，跑一个实例并把排空做对，比提前分片更诚实。**

### 它拿不到什么

Relay 看不到明文、看不到你的 dsh 地址、看不到会话内容。它知道的全部是：哪个 deviceId 在线、谁连了谁、搬了多少字节。

这不是承诺，是结构上做不到——加密在 Bridle 和 app 之间，Relay 只有密文。`e2e/tests/security.test.js` 里的 `the relay only ever sees ciphertext` 盯着这一条。

---

## 2. DNS

Cloudflare 面板里加一条：

| 类型 | 名称 | 内容 | 代理 |
|---|---|---|---|
| `A`（或 `CNAME`） | `reins` | 你的 Relay 源站 | 橙云开 |

走 Cloudflare Tunnel 的话 `cloudflared tunnel route dns` 会替你加，不用手动建。

加完验一下：

```sh
dig +short reins.novabox.ai
curl -fsSL https://reins.novabox.ai/healthz
```

### 安装脚本挂哪

**不挂在 Relay 上**（见 §1）。仓库转公开后直接从 GitHub 取：

```sh
curl -fsSL https://raw.githubusercontent.com/0x5446/reins/main/install.sh | sh
```

想要一个短一点的地址，就在 Cloudflare 加一条 **Redirect Rule**（不是 Worker，不用写代码）：

```
reins.novabox.ai/install  →  302  https://raw.githubusercontent.com/0x5446/reins/main/install.sh
```

这样 app 里那行 `curl -fsSL https://reins.novabox.ai/install | sh` 仍然成立，但中继被攻破**不会**污染安装链路——两者是不同的信任域。

### 转公开之前必须做完的

仓库一旦公开，提交历史收不回来。这几条是不可绕过的：

- [ ] **全历史秘密扫描**（`gitleaks detect --no-git` 与 `--log-opts=--all` 各一遍）
- [x] LICENSE 就位（MIT）
- [x] 包元数据不再是 `UNLICENSED` / `private`
- [ ] 依赖许可证核对（`npm ls --all` 里没有 GPL 传染项）
- [ ] `/privacy` 页面已写：Relay 能观测到在线状态、连接关系、流量计数；推送落地后还会知道 device token 与机器的关联
- [ ] 至少两名发布维护者，或明确写出当前是单人维护及其后果

### 私有仓库期间的注意

安装脚本本身能从 Relay 拿到，但它里面 `git clone` 的是私有仓库——没有 GitHub 访问权的人跑到那一步会失败，脚本会明确说是私有仓库并给出手动 clone 命令。要真正对外，仓库得转公开，或者改成从发布产物安装。

脚本是幂等的（重跑是更新不是重装），装完把 `bridle` 链接到 `~/.local/bin`。app 里那行命令要改的话，改 `ios/Reins/App/Links.swift` 一处。

---

## 3. iOS app

### 上真机 / TestFlight

签名已开。bundle id 是 `ai.novabox.reins`，team 从环境变量来：

```sh
REINS_TEAM_ID=<你的 Team ID> xcodegen generate
```

**免费个人 team 与付费的区别，是整个发布计划的分水岭：**

| | 免费个人 team | 付费 Developer Program（$99/年） |
|---|---|---|
| 装到自己设备 | ✓ | ✓ |
| profile 有效期 | **7 天**，过期即闪退 | 1 年 |
| TestFlight | ✗ | ✓ |
| 推送（`aps-environment`） | ✗ 后台 Keys 页面也不开放 | ✓ |
| 上架 | ✗ | ✓ |

**一个决策卡三件事**：TestFlight、推送、上架的共同前置都是这 $99。

### 提审时会被问到的

- **相机权限**：扫配对二维码。`INFOPLIST_KEY_NSCameraUsageDescription` 里已经写清了用途。
- **本地网络权限**：同 Wi-Fi 直连电脑。`INFOPLIST_KEY_NSLocalNetworkUsageDescription` 说明了为什么。
- **ATS 例外**：`NSAllowsLocalNetworking: true`。直连是局域网内的明文 WebSocket，里面搬的全是 Noise 密文——底下再套一层 TLS 是给一个没人能签发证书的名字做认证，没有意义。走 Relay 的路径是 `wss`，没有例外。
- **加密出口合规**：用了非豁免加密（ChaCha20-Poly1305、X25519）。走标准的 App Store 加密声明流程。

### 发布关键路径

上市是当前最大的杠杆，所以它不是部署文档的附录，是一条有顺序、有门槛的路径。每一项做完才能做下一项。

| # | 事项 | 门槛（做完的判据） | 阻塞于 |
|---|---|---|---|
| 1 | 版本协商落地 | 新旧双向互通测试通过 | — ✅ 已完成 |
| 2 | 仓库转公开 | 全历史秘密扫描通过、LICENSE 就位、包元数据非 UNLICENSED | 人工确认 |
| 3 | 部署 Relay | `/healthz` 与 `/install` 从公网可达 | 一台机器或 CF Tunnel |
| 4 | 写 `/help` 与 `/privacy` | 隐私页说清 Relay 能观测到什么 | — |
| 5 | 购买 Developer Program | 账号可签发 APNs key | **$99** |
| 6 | TestFlight 外测 | 一个非自己的设备装上并完成一次配对 | 5 |
| 7 | 提交审核 | 加密出口声明、权限说明齐备 | 6 |

### 如果一直不买那 $99

这不是"推迟"，是**换一个产品定位**，必须说清楚而不是含糊过去：

- 阶段目标降为**源码开发预览**：会用 Xcode 的人自己 clone、自己签、每 7 天重装一次
- README 与所有对外表述**不得**宣称"可发布产品"或"上架中"
- 推送与定时任务**从路线图移除**，不是标为"待做"——没有付费账号它们永远不会做完
- 分发只能靠源码；浏览器插件（Chrome Store $5 一次性、无设备限制）反而成为唯一能真正上架的客户端

**这条路可以走，但它是一个不同的产品。**混着说会让所有计划都建立在一个没做的决策上。

### 还要写的

`https://reins.novabox.ai/help` 和 `https://reins.novabox.ai/privacy` 两个页面。Relay 现在对这两个路径返回 404。隐私页得说清楚：Relay 只看得到密文，不收集会话内容；能观测到的只有在线状态和流量计数。

页面本身放哪都行——Cloudflare Pages 挂个 Worker 路由，或者跟 `/install` 一样加进 Relay。

---

## 域名本身

`novabox.ai` 的注册到期日是 **2026-10-07**，从今天（2026-08-15）算还有 53 天。GoDaddy 那边确认一下自动续费是开的——域名一掉，所有已配对的 Bridle 会同时连不上 Relay（局域网直连还能用，因为那条路不经过域名）。
