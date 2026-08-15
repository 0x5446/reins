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

三样东西要上线：Relay、DNS 记录、iOS app。**前两样已经上线**（2026-08-15），第三样卡在 Apple 那边。

## 当前生产部署

| 项 | 值 |
|---|---|
| 主机 | 阿里云北京，Ubuntu 26.04，2 核 / 1.5 GB |
| Relay | systemd `reins-relay`，监听 `127.0.0.1:8787`，**不开公网端口** |
| 源码路径 | `/opt/reins`，`root:root` 只读，服务账号 `reins`（nologin） |
| 入口 | Cloudflare Tunnel `reins-relay`，systemd `cloudflared` |
| 隧道配置 | `/etc/cloudflared/config.yml`（本地管理，不是面板管理） |
| DNS | `reins.novabox.ai` CNAME → `<tunnel-id>.cfargotunnel.com`，橙云开 |
| `/install` | Cloudflare Redirect Rule → GitHub raw，**不经过 Relay** |
| `/` `/get` `/help` `/privacy` | Cloudflare Worker `reins-site`（静态资源，无源站） |

一个域名，三样东西按路径分开：

| 路径 | 谁在服务 | 为什么是它 |
|---|---|---|
| `/v1/*`、`/healthz` | Relay（隧道回源） | 唯一需要有状态进程的部分 |
| `/install` | Cloudflare 重定向规则 | 中继和安装链路必须是两个信任域 |
| `/`、`/get`、`/help`、`/privacy` | Worker 静态资源，跑在边缘 | Relay 是北京一台小机器上的单实例；它挂了隐私页不能跟着挂，而 App Store 审核会去拉那个链接 |
| `/_/*` | 同上 | 站点自己的静态资源。加 favicon 或图片时不用再加一条路由 |

**Worker 路由绝不能写成 `/*`**。那会把 `/healthz`、`/install`、`/v1/*` 全吞掉，也就是整个产品——而四个页面依然返回 200，看起来一切正常。`deployed.test.js` 里有一条专门盯这个：`/healthz` 的 content-type 必须还是 `application/json`。

验证方式是 `e2e/tests/deployed.test.js`，它打的是真实公网地址而不是进程内的 Relay：

```sh
REINS_E2E_RELAY_URL=wss://reins.novabox.ai npm run build && \
  node --test e2e/tests/deployed.test.js
```

没有这个环境变量它会跳过。**别把它从 CI 里删掉再指望别的测试能替代它**——其余 e2e 全跑在 loopback 上，隧道拒绝 WebSocket 升级、代理把流缓冲成没用、容量上限设错，这几种它们一个都发现不了。

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

**B. Cloudflare Tunnel** —— 现在用的就是这条。理由见下面的备案一节；简单说是：这台机器在中国大陆，备案这条路对 `.ai` 是死的，隧道让执法链条够不着。**注意这是"够不着"，不是"不适用"**——早先这里写的是"不监听公网端口就不构成对外提供服务"，那句话是错的。

```sh
cloudflared tunnel login                      # 浏览器授权，写出 ~/.cloudflared/cert.pem
cloudflared tunnel create reins-relay
cloudflared tunnel route dns reins-relay reins.novabox.ai
sudo cloudflared service install              # 读 /etc/cloudflared/config.yml
```

`config.yml` 里配 ingress（`reins.novabox.ai` → `http://127.0.0.1:8787`，兜底 `http_status:404`）。

**为什么用本地管理的隧道而不是面板管理的**：面板管理需要写 `PUT /accounts/*/cfd_tunnel/*/configurations`，而 Cloudflare 的 WAF 会拦掉从 dashboard 会话发出的程序化写请求（403 + "Attention Required" 页面），Zero Trust 那套 UI 又要先走 onboarding。`cloudflared tunnel login` 拿到的 `cert.pem` 直接带 DNS 写权限，一条命令建记录，绕开这两处。配置在 `/etc/cloudflared/config.yml` 里也更容易和仓库对上。

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

## 1.5 ICP 备案：现状是"违规但够不着"，不是"不适用"

这一节存在的原因是**上一版文档在这里写错了**，而错的方式很典型：把云厂商帮助文档的口径当成了法规口径。留着这段，是因为下一个人多半会犯同一个错。

### 法条怎么说

《非经营性互联网信息服务备案管理办法》（信产部令 33 号）第五条的触发要件是：

> **在中华人民共和国境内的组织或个人**，利用通过互联网域名访问的网站……提供非经营性互联网信息服务

要件是**境内主体 + 域名可访问的网站 + 提供信息服务**。条文里**没有"服务器在境内"这几个字**。域名在境内主体名下、站点公网可达，字面上就落进去了——机器监听哪个地址不改变这一点。

阿里云帮助文档里那句"域名解析至中国内地服务器并开通 Web 访问"是**云厂商自己的判定口径**，用来决定它要不要替你阻断，不是法规的构成要件。把两者当成一回事是上一版的错误。

### 为什么 `.ai` 让备案变成不可能

不是"麻烦"，是路径根本不存在：

- `.ai` 不在工信部批复的可备案顶级域清单里（工信部「中国互联网域名体系」只列 CN 体系；阿里云核验要求附录也不含 `.ai`）
- 依据是工信部信管〔2017〕264 号：2018-01-01 起新增备案的顶级域必须经批复
- 另一道锁：注册商也须是工信部批复机构，GoDaddy 不在列

### 为什么现在没事

备案的强制执行靠**境内接入服务提供者代为核查与阻断**（264 号文），而阻断作用在**入站** HTTP Host / TLS SNI 上。这套机制看不见当前架构：域名解析到 Cloudflare 的 Anycast IP，阿里云侧只有一条出站加密长连接，没有入站 80/443，没有 Host 可查。

调研没有找到任何一手案例是"因跑 cloudflared 出站隧道被阿里云关停"。找到的关停案例都是：违规内容、挖矿、未备案域名解析到内地 IP 且走 80/443。

### 真实风险在别处

按严重度排：

1. **中国区 App Store 上架强校验 ICP 备案号**（苹果 2023-09 起；2024-04 起还校验 App 名称与工信部记录一致）。`.ai` 无法备案 ⇒ **这个域名下的产品上不了中国区**。这是最硬的一条，且和 Relay 放哪无关，换域名才解得开。
2. **被动牵连停机**：他人把未备案域名解析到这台 ECS 的公网 IP，触发平台巡检直接停机。跟我们怎么部署无关，纯看运气，有真实案例。
3. **配合调查时无法自证**：一台境内机器跑端到端加密中继、拿不出明文、没有日志。真被问到时，解释成本远高于备案本身。
4. 备案罚则本身（33 号令：责令改正 + 1 万元罚款）——需要管局立案，常规入口是接入商转达，而那条链断了。

### 决定（2026-08-15）

**维持现状**，明确接受上述灰色状态。评估过的替代方案：

| 方案 | 边际成本 | 状态 |
|---|---|---|
| 现状：北京 ECS + CF Tunnel | ¥0（机器已存在） | **采用** |
| 境外 VPS（香港/新加坡） | ¥24/月起 | 未采用。合规干净，且中国用户少一跳折返 |
| Cloudflare Workers + Durable Objects，无源站 | ¥0（免费版：10 万请求/天、13,000 GB-s/天；入站 WS 消息 20:1 折算；休眠连接不计时长） | 未采用。免费额度对个人量级绰绰有余，但 Relay 要按 Hibernation API 重写，单帧上限从 64 MiB 降到 32 MiB，且绑死 Cloudflare |
| 老实备案 | — | 不可行，`.ai` 出局 |

**扩大规模前重新评估这一节。**上面的风险评估建立在"个人、小流量、不公开推广"之上；有真实用户之后每一条的概率都变。

---

## 2. DNS

已经加好了，`cloudflared tunnel route dns` 建的：

| 类型 | 名称 | 内容 | 代理 |
|---|---|---|---|
| `CNAME` | `reins` | `a553d87c-715d-4045-9e2d-012ee543c96c.cfargotunnel.com` | 橙云开 |

自己重建的话不用手动填，跑 `cloudflared tunnel route dns <隧道名> reins.novabox.ai`。

验证：

```sh
dig +short reins.novabox.ai
curl -fsSL https://reins.novabox.ai/healthz
```

`dig` 出来了但 `curl` 说解析不了，是本机解析器缓存了刚才那次 NXDOMAIN（SOA 的 negative TTL 是 1800 秒）。macOS 上 `sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder`。

### 安装脚本挂哪

**不挂在 Relay 上**（见 §1）。仓库转公开后直接从 GitHub 取：

```sh
curl -fsSL https://raw.githubusercontent.com/0x5446/reins/main/install.sh | sh
```

短地址已经配好了，是一条 Cloudflare **Redirect Rule**（不是 Worker，不用写代码）：

```
reins.novabox.ai/install  →  302  https://raw.githubusercontent.com/0x5446/reins/main/install.sh
```

这样 app 里那行 `curl -fsSL https://reins.novabox.ai/install | sh` 仍然成立，但中继被攻破**不会**污染安装链路——两者是不同的信任域。

重定向本身现在就生效，但跟过去是 404：仓库还是私有的。**仓库转公开的那一刻它自己就通了**，不需要再动 Cloudflare。

指向 `main` 而不是某个 tag，是有意的：这一层是引导脚本，永远取最新；`install.sh` 内部再用 `REINS_REF` 把真正 checkout 的源码钉到发布 tag 上。两层分开，改发布版本不用动 Cloudflare 规则。

### 转公开之前必须做完的

仓库一旦公开，提交历史收不回来。这几条是不可绕过的：

- [ ] **全历史秘密扫描**（`gitleaks detect --no-git` 与 `--log-opts=--all` 各一遍）
- [ ] **打 tag**：`install.sh` 默认 checkout `REINS_REF`（现在是 `v0.1.0`）。这个 tag 不存在的话，安装脚本会在 `git clone --branch` 那步失败——私有期间没人跑得到，公开的第一分钟就有人跑得到
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
| 2 | 部署 Relay | `deployed.test.js` 打公网地址全绿 | — ✅ 已完成 |
| 3 | 写 `/help` 与 `/privacy` | 隐私页说清 Relay 能观测到什么 | — ✅ 已完成 |
| 4 | 仓库转公开 | 全历史秘密扫描通过、LICENSE 就位、包元数据非 UNLICENSED、打出 `install.sh` 里 `REINS_REF` 指的那个 tag | 人工确认 |
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

### 对外页面

四个页面在 `site/public/`，部署命令：

```sh
npx wrangler deploy --config site/wrangler.jsonc
```

隐私页（`site/public/privacy.html`）是**唯一一份对外承诺 Relay 能看到什么的文档**，所以它里面每一条都要能在代码里对上，而不是能自圆其说。写的时候核对过这几处，改动 Relay 或配对流程时要一起改：

| 页面上的说法 | 权威在哪 |
|---|---|
| Relay 不落盘、不记日志 | `relay/src/` 里没有任何 `writeFile` / `console.*` |
| Relay 内存里存了什么 | `registry.ts` 的 `Machine`、`offers.ts` 的 `HeldOffer` |
| 机器名是明文 | `Machine.name`，注册时上报，配对前就要显示给 app |
| 配对期最多 15 分钟持有 bundle | `PairingBundle` 含 LAN 地址、公钥、一次性 token |
| 手机端解除配对是单向的 | `AppModel.unpair` 只动本地；Mac 侧要 `bridle revoke` |

**不要在隐私页上写代码没做到的事。**"手机上解除配对会同时通知电脑" 这种话写起来顺手，但它是假的——一部想被遗忘的手机，恰恰是最不该听它自称的那一部。

---

## 域名本身

`novabox.ai` 的注册到期日是 **2026-10-07**，从今天（2026-08-15）算还有 53 天。GoDaddy 那边确认一下自动续费是开的——域名一掉，所有已配对的 Bridle 会同时连不上 Relay（局域网直连还能用，因为那条路不经过域名）。
