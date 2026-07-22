# TUN 免密码特权助手 · 实现任务书（给实现者 / Codex）

> 配套阅读（必读）：`docs/design/tun-passwordless-helper.md`（设计 + 威胁模型 §4/§5）。
> 本文是可执行的任务清单，把**安全红线**和**关键 API**写死，照做即可。做完由本项目维护者审查后合并到 `main`。

## 0. 现状（已完成，别重做）

分支 `feat/tun-passwordless-helper`，`swift build` / `swift test`（174 通过）绿：
- `Sources/HelperProtocol/`：共享模块。含 `HelperConstants`（socket/plist/路径/identifier）、`HelperRequest`（`status`/`startTun`/`stopTun`，**刻意无任意命令字段**）、`HelperResponse`、`HelperTrustConfig`、`HelperFraming`（4 字节大端长度前缀 + JSON，1MiB 上限）。
- `Sources/KongshanHelper/main.swift`：**拒绝优先**骨架（`HelperSecurity.isTrustedClient` 目前恒 `false`，`HelperEngine` 起停返回未实现，`main` 打日志即退）。
- `Package.swift`：已加 `HelperProtocol` target、`KongshanHelper` 可执行 target（链 `Security.framework`）、`HelperProtocolTests`。
- 现有 `Sources/KongshanCore/PrivilegedLauncher.swift`：**保留**，作为未装助手时的 osascript 兜底。

## 1. 铁律（违反即打回，不合并）

1. **helper 绝不执行任意命令**。只 `exec` 内置 sing-box（路径由 helper 自身位置推导 + exec 前校验其签名/cdhash），参数固定 `run`，配置从 stdin。`HelperRequest` 不许新增任何路径/命令/参数字段。
2. **拒绝优先**。`isTrustedClient` 未正确实现前，一律返回 false。任何"校验失败也放行"的分支都不行。
3. **配置不落盘、不进命令行/环境变量**。只经 socket 的 `SCM_RIGHTS` 传只读 FD → sing-box stdin。clash_api secret 只在内存。
4. **只杀自己起的进程**。停止只对"helper 本次启动、且命令行匹配内置 sing-box"的 PID 发 `SIGINT`。不接受外部传入 PID。
5. **不在自动化里真安装 daemon**。安装改系统、需管理员授权，由用户在真机点一次。CI/开发机上不 bootstrap、不写 `/Library/LaunchDaemons`。
6. **不删/不弱化** `PrivilegedLauncher` 兜底；未装助手时 TUN 仍走它。

## 2. 里程碑 2b — helper 安全核心（`Sources/KongshanHelper/`）

### 2b.1 Unix socket 服务
- 在 `HelperConstants.socketPath` 建 `AF_UNIX`/`SOCK_STREAM`：先确保 `stateDirectory` 存在（root、`0700`），`unlink` 旧 socket，`bind`，`chmod 0600`，`listen`。
- accept 循环（可单线程串行处理，够用）。收 `SIGTERM`/`SIGINT` 优雅退出：停内核、关 socket、`unlink`。
- launchd 用 `MachServices` 或 socket-activation 均可；本项目走**自建 socket**（plist 里 `KeepAlive` + `ProgramArguments` 直接跑 helper，helper 自己 bind），实现最简单、可控。

### 2b.2 对端身份校验（威胁模型 §5.1；安全命门）
每个连接 accept 后、处理任何请求前：
1. 取对端审计令牌：`getsockopt(connfd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len)`，`token: audit_token_t`。失败→拒绝。
2. 由令牌得 `SecCode`：`SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: Data(token)], [], &code)`。
3. 校验签名有效 + identifier：`SecCodeCheckValidityWithErrors(code, [.enforceRevocationChecks 视情况], requirement, &err)`，`requirement` = `identifier "com.kaysen.kongshan"`（编译用 `SecRequirementCreateWithString`）。
4. 校验**可执行路径**：`SecCodeCopyPath`/`SecCodeCopySigningInformation` 取对端可执行路径，须 `==` `HelperTrustConfig.clientExecutablePath`（安装时写入）。
5. **可选** cdhash：若 `trust.pinnedCDHashHex != nil`，比对 `kSecCodeInfoUnique`。默认 nil 不比。
6. 以上任一不过 → 记日志（不含敏感信息）+ 断连。全过 → 放行。
- 把判定逻辑抽成**可注入的纯函数**（输入：审计信息/签名信息 + trust；输出：bool），方便里程碑 5 单测，不依赖真实 socket。

### 2b.3 startTun：收 FD + 固定 exec
- `recvmsg` 收请求帧同时取 `SCM_RIGHTS` 里的**只读 FD**（App 传来的配置，如匿名管道读端）。无 FD → 拒绝。
- 解析内置 sing-box 路径：由 helper 自身可执行路径推导（同 `.app` 内，如 `../Resources/sing-box` 或与设计一致的固定相对位置）。**exec 前**校验该 sing-box 的签名/cdhash（防被替换）。
- `posix_spawn`/`Process` 跑 `sing-box run`（无 `-c`，从 stdin 读），把收到的 FD 作为子进程 stdin，日志重定向到内核日志文件（沿用现有 `logs/sing-box-tun.log` 约定）。记录 PID。
- 回 `HelperResponse(ok:true, kernelPID:…)`。

### 2b.4 stopTun / 生命周期
- `stopTun`：对记录的 PID 校验命令行确为内置 sing-box 后 `SIGINT`；清 PID。
- 自愈/防残留：helper 周期 `kill(clientPID, 0)`（clientPID 可在 startTun 时随连接身份获得）或监听连接断开；主 App 长期不在 → 自动停内核，避免残留 root 内核接管网络。

## 3. 里程碑 3 — App 客户端 + 设置 UI + 接线

### 3.1 客户端（新 `Sources/KongshanCore/PrivilegedHelperClient.swift`）
- 连 `HelperConstants.socketPath`；发 `HelperFraming` 帧；`startTun` 时用 `sendmsg`+`SCM_RIGHTS` 传配置只读 FD（用 `pipe()`，写端喂 config 数据后关闭，读端传给 helper）。读响应。超时 + 错误处理。
- 与现有 `PrivilegedLaunching` 协议对齐（`start(config:)`/`stop()`），做成可替换实现。

### 3.2 接线（`AppState` TUN 启停路径）
- 起 TUN 时：若助手已安装且可连 → 用 `PrivilegedHelperClient`（**零弹窗**）；否则回退现有 `PrivilegedLauncher`（osascript，弹窗）。停同理。
- 不改系统代理路径。

### 3.3 设置 → 隧道 UI
- "安装免密码助手" / "卸载" 按钮 + 状态（已装 / 未装 / 需重装[路径变了]）。
- **安装**（一条 osascript 提权，弹一次）：建 `stateDirectory`（root `0700`）；写 `trust.json`（`0600`，`clientExecutablePath` = 当前 App 可执行路径，`pinnedCDHashHex` 默认 nil）；放 LaunchDaemon plist 到 `/Library/LaunchDaemons/com.kaysen.kongshan.helper.plist`；`launchctl bootstrap system …`。装完连 socket 发 `status` 自检。
- **卸载**（一条 osascript）：`launchctl bootout system …` + 删 plist / socket / stateDirectory。
- osascript 命令用固定字符串拼接，路径 `shellQuote`，参考现有 `PrivilegedCommandBuilder` 风格。

## 4. 里程碑 4 — 打包（`scripts/build_app.sh`）

- 把 `KongshanHelper` 可执行拷进 `.app`（如 `Contents/MacOS/KongshanHelper`）。
- 放 LaunchDaemon plist 模板到 `.app`（如 `Contents/Library/LaunchDaemons/…plist` 或 `Resources/`，安装时读取并写系统路径）。
- plist：`Label` = `com.kaysen.kongshan.helper`，`ProgramArguments` 指向安装后 helper 位置，`KeepAlive` 合理，`RunAtLoad` 视策略。
- helper 与 sing-box 一起被 ad-hoc `codesign`（已有 `codesign --deep`，确认覆盖到 helper）。

## 5. 里程碑 5 — 测试

- `HelperProtocolTests`：已有帧/请求往返、超限拒绝。
- 新增（helper 或 core，纯逻辑、可注入）：
  - 校验判定：给定"签名 OK/坏、identifier 对/错、路径匹配/不匹配、cdhash 命中/不命中" → 期望放行/拒绝。**至少覆盖每个拒绝分支**。
  - 请求分发：`status` 通、未鉴权连接一律拒。
  - trust.json 缺失/损坏 → 拒绝。
- **不写**真装 daemon 的测试（铁律 5）。

## 6. 交付与我方验收（合并前我会逐条核对）

- [ ] `swift build` + `swift test` 全绿（含新测试）。
- [ ] 铁律 §1 全部满足（尤其 §1.1 固定 exec、§1.2 拒绝优先、§1.3 FD 不落盘、§1.4 只杀自起）。
- [ ] 未装助手时 TUN 仍能经 osascript 兜底启停。
- [ ] 无 clash_api secret / 配置明文落盘（grep 确认）。
- [ ] 校验逻辑有单测覆盖每个拒绝分支。
- [ ] 我会额外派独立 subagent 做**安全审查**，重点盯 §5.1/§5.2/§5.3；有提权面问题不合并。
- [ ] 真机安装授权验收由用户点一次（我不在自动化里装）。

## 7. 给实现者的提醒

- 在 `feat/tun-passwordless-helper` 分支上继续提交（别直接推 main；最终由维护者审查后合并）。
- 每完成一个里程碑单独提交，commit message 说清动了什么。
- 拿不准的安全取舍，宁可更严（拒绝），并在 PR/交接里标出来让审查者看。
- 别碰侧栏相关文件（另一分支 `fix/sidebar-toggle` 在改），避免冲突。
