# 部署

三样东西要上线：Relay、install.sh 的托管地址、iOS app。前两样今天就能做，第三样卡在 Apple 那边。

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

### 路由

| 方法 | 路径 | 用途 |
|---|---|---|
| `GET` | `/healthz` | 健康检查，给负载均衡用 |
| `GET` | `/v1/machine/<deviceId>` | 这台机器现在在不在线 |
| `POST` | `/v1/pair/offer` | Bridle 挂一个短码邀请 |
| `GET` | `/v1/pair/claim?code=…` | app 用短码换配对载荷 |
| `WS` | `/v1/bridle` | Bridle 的常连 |
| `WS` | `/v1/app` | app 的连接 |

### 前面要放 TLS

Relay 自己不做 TLS。放在 Caddy / nginx / 云厂商的 LB 后面，证书交给它们。

Caddy 够用，两行：

```
relay.reins.app {
	reverse_proxy 127.0.0.1:8787
}
```

WebSocket 不用额外配置，Caddy 默认透传 upgrade。

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

## 2. install.sh 的托管地址

app 的引导页让人粘贴：

```sh
curl -fsSL https://reins.app/install | sh
```

这个 URL 要指向本仓库的 [`install.sh`](../install.sh)。最省事的做法是在 `reins.app` 上加一条重定向到 raw 文件；**仓库是私有的时候 raw URL 需要 token，所以私有期间只能走 `git clone` + `sh install.sh`**，README 里已经这么写了。

脚本本身跑得起来、幂等（重跑是更新而不是重装），装完把 `bridle` 链接到 `~/.local/bin`。

如果 app 里那行命令要改，改 `ios/Reins/App/Links.swift` 一处。

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

`https://reins.app/help` 和 `https://reins.app/privacy` 两个页面。隐私页得说清楚：Relay 只看得到密文，不收集会话内容；能观测到的只有在线状态和流量计数。
