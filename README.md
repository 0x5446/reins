# Reins

用 iPhone 操控跑在你电脑上的 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)。端到端加密，中继服务器看不到明文。

| 组件 | 是什么 | 跑在哪 |
|---|---|---|
| **Reins** | iOS app，你手里的那一头 | iPhone |
| **Bridle** | 伴生进程，套住本机的 dsh | 和 dsh 同一台电脑 |
| **Relay** | 哑管道，只搬密文 | 公网 |

```
 iPhone                  公网                   你的电脑
┌────────┐          ┌──────────┐          ┌──────────────────┐
│ Reins  │◄──wss───►│  Relay   │◄──wss───►│ Bridle ──► dsh   │
└────────┘   密文   └──────────┘   密文   └──────────────────┘
     └──────────── 端到端加密通道 ────────────┘
```

Bridle 主动外连 Relay，**不需要端口转发、不需要公网 IP、不需要动路由器**。手机和电脑在同一个 Wi-Fi 时自动走直连，不经过 Relay。

设计细节见 [`docs/architecture.md`](docs/architecture.md)，dsh 那 51 个 API 的清单见 [`docs/dsh-api-inventory.md`](docs/dsh-api-inventory.md)。

---

## 装上去用

### 1. 电脑端：装 Bridle

```sh
curl -fsSL https://reins.novabox.ai/install | sh
```

需要 Node 22+ 和 git。脚本不会替你装 Node，只会告诉你缺什么；装完 `bridle` 链接到 `~/.local/bin`。

> Relay 还没部署的时候这个 URL 拿不到东西，从源码装：
>
> ```sh
> git clone https://github.com/0x5446/reins.git ~/.reins/src
> sh ~/.reins/src/install.sh
> ```

### 2. 电脑端：配对

```sh
bridle pair
```

终端里出一个二维码。第一次跑 `bridle` 会自动进配对流程，不用单独敲这条。

SSH 上去、终端画不出二维码，加 `--link` 打印原始配对链接。

### 3. 手机端：扫码

装好 Reins，打开，扫终端里那个码。扫完就连上了——不需要注册账号，不需要填服务器地址，不需要输密码。

短码是给扫不了码的场景准备的（比如手机不在手边、屏幕共享）：终端上同时印了一个 8 位短码，在 app 里手输也行。走短码时两端会各显示一个 6 位数字，**对上了才是安全的**（同一套 Bluetooth 数字配对的逻辑，防中间人）。

### 4. 让它一直跑着

```sh
bridle service install
```

登录后自动起，关终端也不断。`bridle service uninstall` 卸掉。

---

## bridle 命令

```
bridle                    启动（第一次会带你配对）
bridle pair               出一个新的配对二维码和短码
bridle status             机器、Relay、dsh、已配对设备
bridle devices            列出已配对设备
bridle revoke <prefix>    踢掉一台设备
bridle service install    开机自启
bridle service uninstall  取消自启
bridle doctor             体检这台机器的环境
```

`start` 的选项：

```
--relay <url>       换 Relay（默认公共 Relay）
--dsh <url>         dsh 地址，如果不在常见端口上
--dsh-command <cmd> 怎么启动 dsh（默认 dsh）
--direct-port <n>   固定局域网直连端口
--no-direct         不监听局域网
--no-auto-start     不自动拉起 dsh
--pair              已有配对设备时也印一份邀请
--link              连原始配对链接一起印（SSH 场景用）
```

状态文件在 `~/.reins/bridle.json`，权限 0600，里面有这台机器的静态私钥。`REINS_HOME` 可以改位置。

---

## 安全模型

**Relay 只看得到密文。** 它按 deviceId 撮合两条 socket，转发不透明字节。拿不到明文、拿不到你的 dsh 地址、拿不到任何 API key。这一条有 e2e 测试盯着（`the relay only ever sees ciphertext`）。

**加密通道**是 Noise_IK_25519_ChaChaPoly_SHA256，两端都只用标准库（Node `node:crypto` / Swift `CryptoKit`），零第三方密码学依赖。每连接一对临时密钥（前向保密），静态密钥双向认证（TOFU 钉住）。帧用 ChaCha20-Poly1305，nonce 是单调计数器——重放、乱序、篡改都会当场断开而不是被吞掉。

**配对令牌一次性。** 二维码被拍到，最多值一次连接尝试；用过就作废。之后设备靠自己的静态公钥被认出来。

**dsh 本身没有认证层**，它的安全模型是「只绑 loopback + Host 头信任栅栏」。Bridle 和它同机，所以 51 个方法（含只允许 loopback 的特权方法）全都能用。这也意味着：**Bridle 等于 dsh 的完整权限**，配对进来的设备能做的事和坐在这台电脑前一样多。`bridle revoke` 是收回权限的唯一方式。

**在手机上取消配对是单向的。** app 里「忘记这台 Mac」只清手机这边；电脑那边还认这台手机，得在电脑上 `bridle revoke`。app 的设置页里就是这么写的，不含糊。

---

## 从源码开发

```sh
npm install
npm run build          # tsc -b protocol bridle relay e2e
npm test               # 62 个单元测试
npm run test:e2e       # 20 个端到端测试（需要本机能跑起 dsh）
npm run test:ios       # 46 个 iOS 测试（需要 Xcode + xcodegen）
npm run vectors        # 重新生成跨语言测试向量
```

工作区：

```
protocol/   Noise、帧、配对载荷、Relay 线上格式（TypeScript）
bridle/     伴生进程 + CLI
relay/      中继服务
e2e/        跨三方的端到端测试
ios/        iOS app（Swift + SwiftUI，XcodeGen 生成工程）
```

### 两套实现怎么对齐

Noise 握手和帧编码在 TypeScript 和 Swift 里各写了一遍。「我自己写的服务器能连上我自己写的客户端」证明不了任何事，所以 `npm run vectors` 用固定密钥、固定临时密钥跑出一份确定性向量（`ios/ReinsTests/Fixtures/protocol-vectors.json`），Swift 侧逐字节比对：握手消息、handshake hash、6 位确认数、传输层密文、配对链接、帧编码。

这里的失败是协议分叉，不是 flaky test。

### iOS

```sh
brew install xcodegen
cd ios && ./run-tests.sh
```

`Reins.xcodeproj` 是生成的，不入库。改了文件列表跑一遍 `xcodegen generate`。

最低 iOS 17（用了 Observation）。签名在 `project.yml` 里关掉了，模拟器够用；上真机要填 `DEVELOPMENT_TEAM`。

---

## 上线前还缺什么

代码是完整的，跑得起来，测试全绿。但一个商业产品还差这些**不在源码树里**的东西：

1. **Relay 没部署**。域名定在 `reins.novabox.ai`（DNS 在 Cloudflare），Relay 自己会在 `/install` 上供出安装脚本，所以一个域名一次部署就够。步骤见 [`docs/deployment.md`](docs/deployment.md)。在那之前用 `bridle --relay <你自己的地址>`。
2. **`/help` 和 `/privacy` 两个页面**还没写，现在返回 404。
3. **App Store / TestFlight** 没提交。需要 Apple 开发者账号和一个真实 bundle id。
4. **仓库是私有的**，所以 `install.sh` 里的 `git clone` 对外人会失败。要真正对外得转公开或改成从发布产物安装。

app 里所有对外链接集中在 `ios/Reins/App/Links.swift` 一个文件，换域名改一处。
```
