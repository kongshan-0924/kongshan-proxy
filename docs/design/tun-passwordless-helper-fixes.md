# TUN 免密码助手 · 修复任务书（第二轮，给实现者 / Codex）

> 背景：里程碑 2b–5 已实现并经独立安全审查。**结论：核心设计站得住，无可被普通用户直接利用的严重提权洞**（签名+路径钉死这道命门成立）。但**不是干净合并**：有 2 个功能性阻断（不修就用不了）+ 1 个中危安全项 + 3 个低危加固。本轮把它们修掉，维护者复审 + 重跑安全审查后合并 main。
> 关联：`tun-passwordless-helper.md`（威胁模型）、`tun-passwordless-helper-tasks.md`（§1 铁律，仍全部生效）。

## 铁律（不变，违反打回）
§1.1 只 exec 内置 sing-box、固定参数 `run`、配置从 stdin；§1.2 拒绝优先；§1.3 配置不落盘/不进命令行环境；§1.4 只杀自起进程；§1.5 不在自动化里真安装 daemon；§1.6 不弱化 osascript 兜底。

---

## A. 必修 · 功能阻断①：socket 权限把 App 挡在门外

- **位置**：`KongshanHelper/main.swift` `setupSocket()`（stateDirectory `chmod 0700`、socket `chmod 0600`）；`PrivilegedHelperInstaller.swift` 安装脚本（`umask 077` + `mkdir -p` + `chmod 700`）。
- **问题**：目录 `0700 root`、socket `0600 root`。App 是**普通用户**进程，对该目录无搜索(x)权限、对 socket 无写权限 → `connect()` 得 `EACCES` → `isReachable()==false` → 永远回退 osascript 弹密码。免密码通道形同虚设。
- **为什么放松是安全的**：安全由 §5.1（audit token 对端校验）把关，**从不依赖 socket 权限**（设计本就假设"同用户任意进程都能连"）。
- **修法**：
  1. 目录（`stateDirectory` 及其父 `.../kongshan`）设 **`0711`**（root 拥有，others 可穿越、不可列目录）。
  2. socket 文件设 **`0666`**（others 可连）。
  3. **保持目录 root 拥有、非 world-writable**（别设 0777），否则攻击者可 `unlink` socket 再 `bind` 假 helper 骗 App（socket-squatting，虽拿不到 root 但要避免）。
  4. `trust.json` 保持 `0600 root`，日志 `0644`。
- 改两处：helper 的 `setupSocket()` 与 installer 的安装脚本都要设成上面的权限（installer 的 `mkdir -p` 会因 umask 把父 `kongshan` 建成 0700，需显式 `chmod 0711` 到每层）。

## B. 必修 · 功能阻断②：大配置写死锁

- **位置**：`PrivilegedHelperClient.swift` `start(config:)`：`writeAll(config, writeEnd)` → `close(writeEnd)` → `sendFrame(startTun, configFD: readEnd)`。
- **问题**：先把整份 config **写满 pipe** 再把读端交给 helper。配置常达数百 KB（真实机场 ~470KB），远超 pipe 缓冲(~64KB)，`writeAll` 无人读 → **死锁**。
- **修法**：先把读端交给 helper（helper 起 sing-box 开始读 stdin），**再并发写**：
  ```
  pipe() → readEnd, writeEnd
  sendFrame(.startTun, configFD: readEnd)   // sendmsg 把 readEnd 复制进 socket
  close(readEnd)
  Thread.detachNewThread { writeAll(config, to: writeEnd); close(writeEnd) }  // 后台并发写，sing-box 边读边排空
  let response = receiveFrame()             // helper spawn 后即回应
  ```
  写在后台线程，与 sing-box 读取并发，不阻塞 actor、不死锁。helper 若拒绝且关掉读端，写端会得 `EPIPE`，后台线程要容错退出（别卡死）。

## C. 必修 · 安全中危：bundle 可写位置 = 提权

- **位置**：`main.swift` `singBoxURL()`（由 helper 自身位置推导）、`verifySingBoxSignature()`（`SecStaticCodeCheckValidity(code, [], nil)`——**nil requirement，只验签名有效、不钉是哪一个**）；plist `ProgramArguments` 直指 **bundle 内** helper。
- **问题**：审查按"App 在 `/Applications` = 只有管理员能写"论证安全。但 **`/Applications` 对 `admin` 组可写，用户是管理员账户** → 普通进程**无需授权**即可替换 bundle 内的 `sing-box` 或 `KongshanHelper` 二进制。ad-hoc 签名零成本，`verifySingBoxSignature` 只验"有效"必过 → 被 root 的 helper/launchd 执行攻击者代码 → **本地提权到 root**。
- **修法（三管齐下，关键是前两条）**：
  1. **helper 拷到 root-only 位置**：安装时把 bundle 的 `KongshanHelper` 拷到 `stateDirectory`（root 拥有、非 world/group-writable，如 `0755 root:wheel`），**plist 的 `ProgramArguments` 指向这个拷贝**，不再直指 bundle。这样 launchd 跑的是用户改不动的 helper。
  2. **钉死 sing-box 身份**：安装时算 bundle 内 sing-box 的 **cdhash**，写进 `trust.json`（新增字段 `singBoxCDHashHex`，root `0600`，用户改不动）。helper `exec` 前校验目标 sing-box 的 cdhash `==` 钉死值（用 `SecCodeCopySigningInformation` 取 `kSecCodeInfoUnique`），不匹配则拒绝启动。这样即便 bundle 内 sing-box 被换，也起不来（TUN 失败但不提权）。sing-box 是固定 vendored 二进制、极少变；变了走"需重装"。
     - helper 里 sing-box 路径改为从 `trust.json` 读（安装时记录 bundle sing-box 绝对路径），而非 `../Resources` 相对推导（因为 helper 已被拷走，相对关系变了）。
  3. **安装前校验位置**（防御深度）：`install()` 前检查 App bundle **不在用户家目录**（`$HOME` 下）；在的话拒装并提示"请把 kongshan.app 移到 /Applications 再安装助手"。
- 有了 1+2，helper 只会跑"root-only 的 helper + cdhash 钉死的 sing-box"，**即便调用方被冒充、App 在别处，也无法让 helper 以 root 跑任意代码**。

---

## D. 加固 · 低危（都做）

1. **结构化生成 root 配置**（`PrivilegedHelperInstaller.swift`）：plist 用 `PropertyListSerialization`、trust.json 用 `JSONEncoder`（`HelperTrustConfig` 已 Codable），**别字符串插值**——避免 App 路径含 XML/JSON 元字符时注入 launchd 键。shell 层的 `shellQuote` 已正确，保留。
2. **路径与签名同源**（`main.swift` `extractClientIdentity`）：可执行路径从**签名用的同一** `SecStaticCode` 取（`SecCodeCopyPath` / 由 audit token 的 static code），别再单独 `proc_pidpath(裸 LOCAL_PEERPID)`，消除裸 PID 往返。别丢弃 `SecRequirementCreateWithString` 返回值（失败要按拒绝处理）。
3. **CMSG 手写解析健壮化**（`main.swift` `recvBodyAndFD`）：控制缓冲 `allocate` 后**清零**；进入 `SCM_RIGHTS` 分支前校验 `msg_controllen >= dataOffset + sizeof(Int32)` 且检查 `msg_flags & MSG_CTRUNC`；无有效 fd 明确置 -1，别读未初始化内存当 fd。

---

## 交付与验收（维护者复审要点）

- [ ] `swift build` + `swift test` 全绿；为可测的新逻辑补单测：C.2 的 cdhash 钉死判定（纯函数）、C.3 的安装位置校验、A 的权限值。
- [ ] A：真机（用户点安装后）App 能连上 helper，`status` 通，TUN 启停零弹窗（这步由用户真机验；实现只需保证权限值正确）。
- [ ] B：构造/说明大配置（数百 KB）路径不死锁。
- [ ] C：helper 只跑 root-only helper + cdhash 钉死 sing-box；换掉 bundle 内 sing-box 后 helper 拒绝启动（可写测试或说明验证方式）。
- [ ] D：plist/trust.json 由序列化生成；路径与签名同源；CMSG 清零+校验。
- [ ] 无 secret/配置明文落盘（保持）。
- **维护者会重跑一遍独立安全审查**，过了才合并 main。

## 提醒
- 继续在 `feat/tun-passwordless-helper` 分支提交，每条修复单独 commit。
- 别碰侧栏相关文件（另一分支在改）。
- 拿不准的安全取舍宁可更严（拒绝），并在交接里标出来。
