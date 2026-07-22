# TUN 免密码 · 特权助手设计与威胁模型

状态：设计定稿，待实现。分支 `feat/tun-passwordless-helper`。
签名前提：**ad-hoc**（用户决定不购买 Developer ID，自用）。安全控制全部保留，仅"对端身份校验"按 ad-hoc 折扣（见 §5.1）。

## 1. 目标 / 非目标

**目标**：TUN 启停/改配置不再每次弹系统授权。安装时授权一次，之后零弹窗。

**非目标**：
- 不改系统代理路径（它本就免密码）。
- 不追求可分发安全性（无公证/无 Developer ID）；仅面向本机自用。
- 不动 sing-box 本身，不引入新代理协议。

## 2. 现状：为什么每次弹

TUN 内核需 root，现用 `osascript … with administrator privileges` 临时提权。macOS 规定**每次这种提权都弹一次**授权框。无常驻的、已授权的通道 → 启停/改配置/崩溃重启每次都弹。

## 3. 方案总览：手动 LaunchDaemon + Unix socket

（SMAppService/SMJobBless 需 Developer ID，ad-hoc 下不可靠，故走手动 daemon。）

```
kongshan.app (普通权限)
   │  ① 安装时：一次 osascript 授权，装 plist + 拷 helper + bootstrap
   │  ② 运行时：连 root 拥有的 Unix socket，发 start/stop/status（零弹窗）
   ▼
/Library/LaunchDaemons/com.kaysen.kongshan.helper.plist  →  launchd 常驻
   ▼
KongshanHelper (root)  —— 只 exec 内置 sing-box + 我们生成的配置
```

- **一次授权**：仅"安装/卸载助手"这一步走 osascript 提权。日常启停 TUN 经 socket，不提权。
- **helper 极小**：只做"起/停 TUN"，不是通用 root 执行器。

## 4. 威胁模型

攻击者 = **已在本机、以当前用户身份运行的进程**（恶意软件/被诱导运行的程序）。目标 = 借 helper 拿 root。
（物理接触、已 root、内核漏洞不在范围内；用户已 root 则本方案无意义。）

关键攻击面：**任何本地进程都能连 helper 的 socket**。因此 helper 必须假设"连进来的不一定是 kongshan"，逐条设防（§5）。

## 5. 安全控制（逐条）

### 5.1 对端身份校验（命门；ad-hoc 折扣在此）
- helper 在每个连接上取对端 `audit_token`（Unix socket 用 `getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN)`）。
- `SecCodeCreateWithAuditToken` → `SecCodeCheckValidityWithErrors`，校验对端：
  1. 签名有效（未被篡改）；
  2. `identifier == "com.kaysen.kongshan"`；
  3. **可执行路径 == 安装时记录的 App 路径**（`/Applications/kongshan.app/Contents/MacOS/kongshan`）。
- ✅ 有 Developer ID 时这里能钉 `TeamID`，攻击者无法伪造 → 最强。
- ⚠️ **ad-hoc 折扣**：无可信锚点，默认靠"有效签名 + identifier + 路径钉死"。攻击者需**能覆盖 `/Applications/kongshan.app`** 才可绕过——而能写 /Applications 的进程已具很高权限，对自用机器属可接受残余风险。
- **默认不钉 cdhash**：因为你频繁重新构建，cdhash 每次都变，钉死会导致**每次构建后都要重装助手**，实用性差。
- **可选加固（默认关）**：钉 cdhash（安全性更高但每次构建需"重新授权助手"）。给一个开关，需要时开。

### 5.2 只跑固定命令（防提权核心）
- helper **绝不**执行 App 传来的任意路径/参数/命令。
- 只会 `exec` **它自己旁边、随 App 打包的 sing-box**（绝对路径写死 + 每次校验其 cdhash），参数固定 `run`，从 stdin 读配置。

### 5.3 配置传递（护凭据）
- 配置（含订阅密码/obfs）**不落盘、不进命令行/环境变量**。
- App 经 socket 用 `SCM_RIGHTS` 传一个**只读匿名 FD**（memfd/管道），helper 直接接到 sing-box 的 stdin。clash_api secret 仍只在内存。

### 5.4 进程归属
- helper 记录自己起的 sing-box PID；停止只 `SIGINT` **这个自己起的、且命令行匹配内置 sing-box 的**进程。绝不按外部传入的 PID 杀。

### 5.5 socket 权限与位置
- socket 放 root 拥有、`0700` 的目录（如 `/Library/Application Support/kongshan/helper/`），socket `0600`（仅 root 可读写）——不过仍不能只靠权限，§5.1 校验是主防线（同用户进程也可能连）。
- 只监听本机 Unix domain，不开网络。

### 5.6 生命周期 / 清理
- App 退出/崩溃：helper 定期 `kill -0` 检查安装时记录的 App，主 App 不在则自动停 TUN，避免残留 root 内核接管网络。
- 卸载：一键 `launchctl bootout` + 删 plist/helper/socket（走一次授权）。

## 6. 组件与文件

- **新 target `KongshanHelper`**（可执行）：main 里建 socket、accept、鉴权、起停 sing-box。依赖 Security.framework。
- **`Sources/KongshanHelperProtocol/`**（共享）：请求/响应编码（简单长度前缀 + JSON；FD 走辅助数据）。App 与 helper 共用。
- **App 侧 `PrivilegedHelperClient`**：连 socket、发指令、传 FD、超时。替换现有 `PrivilegedLauncher` 的 TUN 路径（保留旧 osascript 路径作未装助手时的兜底）。
- **`Resources/com.kaysen.kongshan.helper.plist`**：LaunchDaemon 模板。
- **安装脚本片段**（osascript 内）：拷 helper 到 `/Library/…` 或直接 `BundleProgram` 指 App 内 helper；写 plist（含安装时的 App 路径 + cdhash）；`launchctl bootstrap system`。
- **`build_app.sh`**：把 helper 可执行 + plist 模板打进 `.app`。
- **设置→隧道 UI**：安装/卸载助手开关 + 状态（已装/未装/需重装因 cdhash 变）。

## 7. 安装 / 卸载流程（唯一授权点）

**安装**（用户在设置里点，弹一次密码）：
1. App 算自身 cdhash + 路径，生成 plist（把这两个值写进 helper 的配置文件，root 拥有 0600）。
2. 一条 osascript 完成：拷 helper→固定路径、写 plist→`/Library/LaunchDaemons/`、`launchctl bootstrap system …`。
3. 校验 helper 起来、socket 可连、`status` 正常。

**卸载**：一条 osascript：`launchctl bootout` + 删文件。

## 8. 协议（App ↔ helper）

- `start`：附一个只读 FD（配置）。helper 校验对端(§5.1) → 起 sing-box(§5.2/5.3) → 回 PID/成败。
- `stop`：停自己起的内核(§5.4)。
- `status`：是否在跑 + 版本。
- 编码：长度前缀 + JSON；FD 经 `sendmsg`/`SCM_RIGHTS`。无动态命令字段。

## 9. 测试与安全审查

- **单元可测**：协议编解码、鉴权判定逻辑（给定 audit token/签名信息 → 通过/拒绝）、配置校验、PID 归属判定。用假 socket/假校验器注入。
- **不在自动化里真装**：privileged 安装改系统，需**用户在真机点一次授权**验证（我开发期间不装）。
- **专门安全审查**：独立 subagent 审 §5 每条是否真落地，重点 5.1/5.2/5.3（对端校验、固定 exec、FD 传递）。有漏洞不合并。

## 10. 残余风险（用户已知并接受，自用）

- ad-hoc 下 §5.1 靠路径+cdhash，非 TeamID 锚点；能覆盖 /Applications 或重签同 cdhash 的高权限攻击者可绕过。
- 每次重新构建 App 需重装/更新助手（cdhash 变）。
- 一个常驻 root daemon 增大攻击面（由 §5 各条压制到最小）。

## 11. 里程碑

1. 本设计 + 威胁模型（本文，✅）
2. 共享协议 + helper 骨架（socket/accept/鉴权/固定 exec/FD）
3. App 客户端 + 设置 UI 安装/卸载 + 与现有 TUN 启停对接（保留 osascript 兜底）
4. build_app.sh 打包 helper+plist
5. 单元测试
6. 独立安全审查 → 用户真机点一次授权验收
