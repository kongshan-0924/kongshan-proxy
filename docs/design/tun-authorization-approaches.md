# macOS 代理客户端的 TUN 与授权方式对比

写这份是因为一个真实故障：**免密码助手装完立刻显示"需重装"，实际从未生效过**。
根因见文末。这里先把业界几种做法摆清楚，说明本项目为什么只能走现在这条路，
以及这条路的固有代价是什么——避免后来者再"优化"回坑里。

## 四种做法

### 1. NetworkExtension（Surge / Stash / Quantumult X / sing-box 官方 SFM）

- 机制：`NEPacketTunnelProvider` 打包成 App Extension，系统接管虚拟网卡，App 通过
  `NETunnelProviderManager` 启停。
- 授权：**首次保存 VPN 配置时系统弹一次"允许"**，之后启停零弹窗、开机自启也没问题。
- 前提：付费 Apple Developer 账号 + `com.apple.developer.networking.networkextension`
  权限 + Developer ID 签名 + 公证。**ad-hoc 签名拿不到这个 entitlement。**
- 结论：体验最好，但对本项目不可用（没有付费账号）。

### 2. 特权 LaunchDaemon 助手（ClashX / ClashX Meta / Docker Desktop / Tunnelblick）

- 机制：一个 root 常驻小程序，App 通过 Unix socket 让它代为执行需要 root 的动作。
- 安装：正规做法是 `SMJobBless`（现在是 `SMAppService.daemon`），要求 App 的
  `SMPrivilegedExecutables` 与助手的 designated requirement 互相匹配——**同样需要
  稳定的签名身份**。ad-hoc 下 SMJobBless 会失败，所以本项目改用
  「一条 osascript 提权 → `launchctl bootstrap`」自己装。
- 认人：**这是关键差异**。有开发者证书的项目（如 ClashX）用签名 requirement 认人：
  `anchor apple generic and identifier "..." and certificate leaf[subject.OU] = "TEAMID"`，
  这样 App 升级、重新签名都还认识，**不需要重装助手**。
  ad-hoc 没有证书链可锚定，唯一能钉的只有 **cdhash**，而 cdhash 每次构建都变。
- 结论：本项目采用。代价见下节。

### 3. 每次 osascript 提权（很多简易脚本型工具）

- 每次起停 TUN 都弹一次密码。本项目保留它作为**兜底**：助手没装或被拒时 TUN 仍然能用。

### 4. setuid root 二进制

- 安全上是灾难（任何本地进程都能驱动它），不考虑。

## 本项目的选择与固有代价

采用 **方式 2 + 方式 3 兜底**：

| 场景 | 行为 |
|---|---|
| 没装助手，第一次开 TUN | 自动弹一次密码装助手，装完这次就走助手 |
| 已装助手，日常开关 TUN | **零弹窗** |
| App 更新后第一次开 TUN | cdhash 变了 → 助手不认 → 自动重装（弹一次密码），之后继续零弹窗 |
| 用户拒绝/取消安装 | 回退每次弹密码，功能不受影响 |

**"App 更新 = 重装一次助手"是 ad-hoc 签名下无法回避的**。想消掉它只有两条路：
买开发者账号改用 NetworkExtension（方式 1），或用 Developer ID 签名改成签名
requirement 认人（方式 2 的正规版）。**不要**为了省这一次弹窗去放宽 cdhash 校验——
ad-hoc 的 identifier 谁都能伪造，cdhash 是这条链上唯一真正的门。

## 安全边界（现状）

1. 助手只接受 audit_token 验明身份的调用方：签名有效 + identifier 匹配 +
   **bundle 路径匹配** + cdhash 匹配，任一不过静默断连。
2. 助手只 exec 安装时拷进 root-only 目录、并钉死 cdhash 的 sing-box，参数固定
   `run -c /dev/stdin`。
3. 配置经 FD 传入后先做 schema 白名单（封死 root 写文件与远程无鉴权控制），
   校验通过的字节重新序列化后用助手自建的 pipe 投喂，不存在 TOCTOU。
4. 助手重启后会按"可执行路径 == 钉死的 sing-box"认领上一实例遗留的内核；
   调用方 App 还在就交回 App 收尾，不在就直接停掉，杜绝无人管的 root 内核。

## 那个让助手长期失效的 bug（务必别改回去）

`SecCodeCopyPath` 对 **bundle 型代码返回的是 `.app` 目录**，不是主可执行文件：

```
helper 实际看到：/Applications/kongshan.app
安装器曾钉死：  /Applications/kongshan.app/Contents/MacOS/kongshan
```

两者恒不相等 → `isTrusted` 永远 false → 助手静默拒绝每一个连接 → App 的
`status()` 拿不到响应 → 界面显示"需重装" → 用户重装多少次都一样。

修复：trust.json 增加 `clientBundlePath`（schema 升到 v3），身份校验比对它；
主可执行路径只用来算 cdhash。回归测试见
`Tests/HelperProtocolTests/HelperTrustEvaluationTests.swift` 的
`testBundlePathIdentityIsTrustedAndExecutablePathPinIsNotEnough`，以及真机只读回归
`Tests/KongshanCoreTests/HelperClientIdentityLiveTests.swift`。

## 第二个坑：`Bootstrap failed: 5: Input/output error`

`launchctl bootout` 是**异步**的。本项目的 helper 用 `poll(..., 1000)` 做 accept 循环，
收到 SIGTERM 后最多要 1 秒多才真正退出；安装脚本若紧接着 `bootstrap`，就会撞上仍在
卸载的 label，报 `Bootstrap failed: 5: Input/output error`。被 `launchctl disable` 过的
label 也报同一个错。

表现：用户输了密码，助手却装不上，界面仍显示"需重装"；并且因为安装失败回退到 osascript
兜底，**开一次 TUN 要输两次密码**。

正确的装载序列（见 `PrivilegedHelperInstaller.makeInstallScript`）：

```sh
launchctl bootout system/LABEL 2>/dev/null || true
# 轮询等它真的消失——这一步不能省
n=0; while launchctl print system/LABEL >/dev/null 2>&1 && [ $n -lt 50 ]; do sleep 0.1; n=$((n+1)); done
launchctl enable system/LABEL 2>/dev/null || true
launchctl bootstrap system PLIST || { launchctl bootout system/LABEL; sleep 1; launchctl bootstrap system PLIST; }
launchctl print system/LABEL >/dev/null   # 确认真的装上了
```

实测（用户域可复现，不需要 root）：让一个 LaunchAgent 在收到 SIGTERM 后延迟 2 秒退出，
旧写法必现 `exit=5 Bootstrap failed: 5: Input/output error`，新写法等 1.8 秒后 `exit=0`。
用秒退的 `/bin/sleep` 当任务是复现不出来的——**"慢退"才是触发条件**。

回归测试：`Tests/KongshanCoreTests/PrivilegedHelperInstallerTests.swift` 的
`PrivilegedHelperInstallScriptTests`（真 `sh -n` 语法校验 + 装载序列顺序断言 + 路径引号）。

## 第三个坑：`missing config fd`（SCM_RIGHTS 被普通 read 丢弃）

配置经 `pipe()` 的只读端用 `sendmsg`/SCM_RIGHTS 交给 helper。**SOCK_STREAM 上辅助数据
跟随本次发送的第一个字节投递**：发送端一次 sendmsg 发出「长度前缀 + body」，接收端若先用
普通 `read()` 读长度前缀，内核会把辅助数据**丢弃并关闭其中的 FD**，之后 recvmsg 再也拿不到。

表现：助手已安装、status 正常，但开 TUN 报 `助手拒绝：missing config fd`。

修法：线缆层收拢到 `HelperProtocol.HelperWire`，两端共用；接收端用 `recvmsg`（带控制缓冲）
读**长度前缀**。回归测试 `Tests/HelperProtocolTests/HelperWireTests.swift` 用真 socketpair
验证 FD 往返（并断言收到的 FD 与发出的是同一个 pipe），另有一条**反向证明**测试锁死
"不能用普通 read 读长度前缀"这个结论。

## 第四个坑：spawn 继承管道写端 → 内核永远等不到 EOF

helper 用 `pipe()` 建管道、`posix_spawn` 把读端 dup2 成 sing-box 的 stdin 来喂配置。
**`posix_spawn` 会把所有未标记 `FD_CLOEXEC` 的 fd 原样继承给子进程**——写端一旦被继承，
sing-box 就自己握着自己 stdin 管道的写端，helper 写完关闭也**永远等不到 EOF**。

表现：root sing-box 进程活着、`STAT=S`、**不监听任何端口、日志 0 字节**，
App 侧报 `sing-box 控制接口未就绪：Could not connect to the server.`。

修法：`pipe()` 之后对**两端**都 `fcntl(fd, F_SETFD, FD_CLOEXEC)`；日志 fd 用 `O_CLOEXEC` 打开；
helper 的监听 socket 与每条 accept 出来的连接同样置 CLOEXEC（控制面 fd 不该流进被管理的进程）。
真正给子进程的 stdin/stdout/stderr 是 `adddup2` 出来的副本，dup2 会清掉 CLOEXEC，不受影响。

回归测试：`Tests/KongshanCoreTests/SpawnStdinPipeTests.swift` 用 `/bin/cat` 当替身真 spawn，
正反两条——置 CLOEXEC 秒退，不置则永远等不到 EOF。

## 小结：四个坑串在一条链上

1. 身份校验比对错对象（`SecCodeCopyPath` 返回 .app 目录）→ 助手谁都不认，界面永远"需重装"；
2. launchd 装载竞态（bootout 异步 + helper 慢退）→ `Bootstrap failed: 5: EIO`，装不上、要输两次密码；
3. 线缆层 SCM_RIGHTS 被普通 `read()` 丢弃 → `missing config fd`；
4. spawn 继承管道写端 → 内核卡在读配置，控制接口连不上。

**修好一个才暴露下一个**——因为前一个把后面的代码路径整个挡住了，它们从未被执行过。
教训：这类"整条路径从未真正跑通"的功能，必须有能独立验证每一段的测试
（socketpair 回环、真 spawn、launchctl 序列），只靠端到端点一下是排不出来的。
