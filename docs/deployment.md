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

Relay 是无状态的哑管道。它不存数据库、不存日志里的明文、没有配置文件——全部配置来自环境变量。

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
| `GET` | `/install` | 安装脚本，给 `curl \| sh` 用 |
| `GET` | `/v1/machine/<deviceId>` | 这台机器现在在不在线 |
| `POST` | `/v1/pair/offer` | Bridle 挂一个短码邀请 |
| `GET` | `/v1/pair/claim?code=…` | app 用短码换配对载荷 |
| `WS` | `/v1/bridle` | Bridle 的常连 |
| `WS` | `/v1/app` | app 的连接 |

`/install` 是哑管道原则的唯一例外，理由很实在：app 让人粘贴 `curl -fsSL https://reins.novabox.ai/install | sh`，这个 URL 总得有东西应答。放在 Relay 里等于一个域名一次部署，不用为了两个页面再养一个静态站。脚本在启动时读一次进内存——每次请求读盘等于给一个公开无认证的接口挂了个磁盘放大器。

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

另有按调用方的令牌桶限流（允许一个突发，然后必须等）。

### 容量

一条线路 = 两个 WebSocket + 一个转发循环，没有解析、没有落盘。瓶颈是文件描述符和带宽，不是 CPU。单进程扛几千条线路没问题。

要横向扩，**不能**简单起多个实例：Relay 按 deviceId 在进程内存里撮合两条 socket，app 和 Bridle 必须落到同一个进程。要么按 deviceId 做一致性哈希的 L4 分流，要么先只跑一个实例——以现在的负载后者更诚实。

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
curl -fsSL https://reins.novabox.ai/install | head -3
```

第三条应该吐出 `#!/usr/bin/env sh`。到这一步，app 引导页里那行 `curl … | sh` 就是真的了。

### 私有仓库期间的注意

安装脚本本身能从 Relay 拿到，但它里面 `git clone` 的是私有仓库——没有 GitHub 访问权的人跑到那一步会失败，脚本会明确说是私有仓库并给出手动 clone 命令。要真正对外，仓库得转公开，或者改成从发布产物安装。

脚本是幂等的（重跑是更新不是重装），装完把 `bridle` 链接到 `~/.local/bin`。app 里那行命令要改的话，改 `ios/Reins/App/Links.swift` 一处。

---

## 3. iOS app

### 上真机 / TestFlight

`ios/project.yml` 里签名是关掉的（`CODE_SIGNING_ALLOWED: NO`），模拟器够用。要上真机：

1. `DEVELOPMENT_TEAM` 填成你的 Team ID。
2. 去掉 `CODE_SIGNING_REQUIRED: NO` 和 `CODE_SIGNING_ALLOWED: NO`。
3. `PRODUCT_BUNDLE_IDENTIFIER` 换成你在 Apple 那边注册的 id（现在是 `app.reins.Reins`）。
4. `xcodegen generate`，然后 Xcode 里 Archive。

### 提审时会被问到的

- **相机权限**：扫配对二维码。`INFOPLIST_KEY_NSCameraUsageDescription` 里已经写清了用途。
- **本地网络权限**：同 Wi-Fi 直连电脑。`INFOPLIST_KEY_NSLocalNetworkUsageDescription` 说明了为什么。
- **ATS 例外**：`NSAllowsLocalNetworking: true`。直连是局域网内的明文 WebSocket，里面搬的全是 Noise 密文——底下再套一层 TLS 是给一个没人能签发证书的名字做认证，没有意义。走 Relay 的路径是 `wss`，没有例外。
- **加密出口合规**：用了非豁免加密（ChaCha20-Poly1305、X25519）。走标准的 App Store 加密声明流程。

### 还要写的

`https://reins.novabox.ai/help` 和 `https://reins.novabox.ai/privacy` 两个页面。Relay 现在对这两个路径返回 404。隐私页得说清楚：Relay 只看得到密文，不收集会话内容；能观测到的只有在线状态和流量计数。

页面本身放哪都行——Cloudflare Pages 挂个 Worker 路由，或者跟 `/install` 一样加进 Relay。

---

## 域名本身

`novabox.ai` 的注册到期日是 **2026-10-07**，从今天（2026-08-15）算还有 53 天。GoDaddy 那边确认一下自动续费是开的——域名一掉，所有已配对的 Bridle 会同时连不上 Relay（局域网直连还能用，因为那条路不经过域名）。
