# 下一步

## 当前最高优先级：维护者重跑安全审查 → 合并 feat/tun-passwordless-helper → main

第三轮 4 条修复（C①/C②/N1/N2）已实现并提交在 `feat/tun-passwordless-helper`（@276dacf，未推）。
`swift build` + `swift test` 全绿（225 通过 1 跳过 0 失败，+9 新单测）。
**下一步 = 维护者重跑独立对抗式安全审查（重点验 C① 是否真消除 TOCTOU），过了才合 main。**

### 维护者复审要点
- C①：`/Library/Application Support/kongshan/helper/sing-box` 存在且 root:wheel 755；trust.json 里 `singBoxExecutablePath` 指向它（不是 bundle）；bundle 内 sing-box 被换/被 TOCTOU 交换都无法以 root 执行（root-only 路径不可写）。
- C②：算不出 cdhash 拒绝安装（`failClosedCDHash(nil)` 抛 authorizationFailed）。
- N1：startSingBox 各抛出路径均关 configFD（defer 兜底）。
- 合并时手动解 AppState.swift / MainWindowView.swift 冲突（main 已升 0.1.23，本分支未 merge/rebase main）。

### 现状
- 里程碑 2b–5（Codex）+ 第二轮修复 A/B/C/D1/D2/D3（Codex）已完成。`swift build`/`swift test` **216 通过 1 跳过**。未碰侧栏文件、无凭据落盘。
- **两轮独立安全审查（general-purpose subagent，prompt 见 SESSION_LOG）**：
  - 第一轮：无严重提权洞；提出 2 功能阻断(socket 权限/大配置死锁)+中危(bundle 可写)+低危 → 已被第二轮修复。
  - 第二轮复审：**A/B/D1/D2/D3 确认闭合**；**C 仍留一个真实(竞态门槛) root 提权面** → 第三轮必修。

### 第三轮必修（详见 `docs/design/tun-passwordless-helper-fixes.md` 末尾「第三轮」）
1. **C① [阻断·root 提权] sing-box verify→exec TOCTOU**：helper 已迁 root-only，但 sing-box 仍在 bundle(管理员组对 /Applications 可写)。`startSingBox` 先按路径校验 cdhash、之后按**同一路径** `posix_spawn`，攻击者可在两步间原子替换 → root 执行任意码。**修法：安装时把 sing-box 也拷到 `stateDirectory`(root:wheel 0755，与 helper 拷贝完全同构)，`trust.singBoxExecutablePath` 指向该 root-only 拷贝** → 路径不可写、TOCTOU 消失。改 `PrivilegedHelperInstaller`(加 sing-box 拷贝) + trust 字段。
2. **C② [低危] fail-closed**：`computeCDHashHex` 返回 nil 时现在静默写 null=不钉；`install()` 加 `guard let … else { throw }`。
3. **N1 [可靠性]**：`startSingBox`(helper) 失败(cdhash 不匹配等)不关 `configFD` → 泄漏 + 卡死 App 后台写线程；顶部 `defer { close(configFD) }` / `defer { close(logFD) }`，删 spawn 后显式 close。
4. （可选 N2：`PrivilegedHelperClient.start` 早抛泄漏 pipe，加 defer。）

### 做完后
- `swift build`+`test` 全绿；**重跑独立对抗式安全审查**（重点 C① 是否真消除 TOCTOU + 无新洞）；过了 **合并 feat→main**。
- **用户真机验收**：设置→隧道→「安装免密码助手」授权一次 → 开 TUN 应零弹窗。

### 接手提示
- **别重造**：功能已在分支上，只做上面 3 条。设计/威胁模型 `docs/design/tun-passwordless-helper.md`；三轮修复清单 `…-fixes.md`；实现任务书 `…-tasks.md`。铁律 §1.1–1.6 不变。别碰侧栏文件（`fix/sidebar-toggle` 在改）。
- 另有并行分支：`fix/sidebar-toggle`（双侧栏按钮修复，待审查合并）、`codex/network-observability-batch`（网络可观测，0.1.23，待了解）。`main`=0.1.20 已发布、领先 origin 2 未推。

## 审查范围明细（参考·下方原文）

1. 维护者独立安全审查 `feat/tun-passwordless-helper` 分支 11 个提交（2b-5 里程碑 4 条 + 修复 A/B/C/D1/D2/D3 6 条 + 补单测 1 条），重点：
   - **C 的 cdhash 钉死链路**：installer 算 bundle 内 sing-box cdhash 写 trust.json → helper exec 前用 `HelperSingBoxTrust.isCDHashMatched` 校验目标 cdhash == 钉死值。ad-hoc 签名零成本可伪造，光验"签名有效"挡不住替换。
   - **C 的安装位置校验**：`HelperInstallLocation.isAllowed` 拒绝 App bundle 在 $HOME 下（家目录可写=bundle 可被替换）。前缀带 `/` 边界防 `kaysen2` 误匹配 `kaysen/`，空 home 拒绝。
   - **C 的 helper 拷 root-only**：plist ProgramArguments 指向 stateDirectory/KongshanHelper（root:wheel 0755）不指 bundle；sing-box 路径从 trust.json 读（helper 被拷走后相对关系已变）。
   - **D2 路径同源**：对端可执行路径从签名校验用的同一 `SecStaticCode` 经 `SecCodeCopyPath` 取，消除裸 PID 往返；`SecRequirementCreateWithString` 返回值检查（失败按拒绝）。
   - **D3 CMSG 解析**：memset 清零 + MSG_CTRUNC + 长度校验，防读到未初始化内存当 fd。
   - **A 权限值**：目录 0711 / socket 0666 共享常量 helper 与 installer 同步。
   - §5.1 身份校验链路（audit_token → SecCode → identifier+path）/ §1.3 FD 不落盘 / §1.4 只杀自起 / §1.2 trust 缺失损坏一律拒。
2. 审查通过后合并 `feat/tun-passwordless-helper` → `main`（别推 main，由维护者合）。
3. 用户真机：重打包（`scripts/build_app.sh`，注意 plist 模板已删、改结构化生成）→ **装 /Applications**（安装位置校验要求不在 $HOME）→ 设置→隧道点「安装免密码助手」（osascript 一次授权，会拷 helper 到 root-only + 算 cdhash 钉死 + 写 trust.json）→ 开 TUN 验证零弹窗。

## TUN 免密码助手修复 A/B/C/D（feat/tun-passwordless-helper 分支，2026-07-22 完成）

- 6 条修复 + 补单测已全部完成并单独提交（7 条 commit：a08103f/b231631/c2fee14/0ee5928/e6e8d37/97ffaeb/ac28853）。
- `swift test` **216 通过 1 跳过 0 失败**（199+17 新）。
- 未碰侧栏文件（git 核对 7 个提交无 sidebar/MainWindowView/RoutingView）；未在自动化里真安装 daemon（铁律 §1.5）。
- 修复任务书见 `docs/design/tun-passwordless-helper-fixes.md`，验收要求已满足（swift build+test 全绿、补单测、无 secret 落盘、每条单独提交、未碰侧栏、拿不准宁可更严）。
- 详见 `docs/HANDOFF.md` 顶部「TUN 免密码助手安全审查修复 A/B/C/D」段与 `docs/progress/SESSION_LOG.md` 2026-07-22 修复段。

## 修复双侧栏按钮（另一分支 fix/sidebar-toggle）

1. 按 `docs/superpowers/specs/2026-07-22-single-sidebar-toggle-design.md` 删除自定义紧凑侧栏和时序性系统按钮清理。
2. 先增加真实窗口回归测试并确认 RED，再修改产品代码转 GREEN。
3. 全量测试、构建、重打包并人工核对仪表盘/设置页只有一个按钮。

## 🔴🔴 真凶已修（0.1.18）：SS 缺 obfs 插件 → 能测速却打不开网站
- 机场 342 节点全是 `ss + plugin:obfs`，旧转换器没解析 plugin → 生成裸 SS → 服务器要 obfs 混淆 → 裸连 TCP 通(测速有值)但传不了数据 → 全部国外站不可达。0.1.18 已解析 obfs→sing-box `obfs-local`。
- **⚠️ 诊断教训**：用户在国内、跟 Claude 对话得开另一个工作代理；**用 Bash 实测连通性会经那个代理、不反映 kongshan**。App 连通卡走 kongshan 自己内核，才是可信信号（它一直报不可达＝对的）。以后测 kongshan 连通性别用主机 curl，除非确认已隔离。
- **用户验证**：重开 0.1.18 → **刷新订阅一次** → TAGSS 挑节点 → 关掉工作代理只开 kongshan → 打开国外网站。应通。

## （历史）0.1.16/0.1.17 的连通性排查

### A. 开代理是否生效（0.1.17：只用机场策略组，待确认）
- **重要**：0.1.16 时用户报"不可达"实为**误报**——内核日志证明代理是通的(claude.ai/github 都经所选节点成功建连)。那张卡片测 `www.google.com/generate_204`(常被拦)且测的节点未必同步。0.1.17 已把探测改为测**主组**(真实路径) + 换稳定端点 `gstatic/generate_204`。
- 0.1.17 按用户意愿**去掉了内置手动/自动选择，只显示机场自带策略组**；主组(TAGSS)默认指向真实节点、final/DNS 走主组。
- **用户操作**：关掉旧实例 → 重开 0.1.17 → 代理页应只剩机场策略组(TAGSS/国外媒体/微软…) → 在 **TAGSS** 里挑节点 → 开系统代理 → 出口连通性应「可达」。
- 注意：旧 groupSelections["🙂 TAGSS"]=台湾02 会成为主组默认；想换在 TAGSS 里重挑即可。
- 若某端点仍不可达：多半是该出口节点确实到不了该站(换节点/测速)，不再是路由问题。

### B. 🔴 TUN「一直弹密码框 / 起不来」——待用户用 0.1.16 复现取证
- 现状：**无法从静态产物复现**。运行态干净（无残留 sing-box、无 tun-recovery.json、runtime 空）；日志证明 16:53 TUN 曾正常接管(utun4、路由 Chrome)。
- 机制：`AppState.start(modes:)` 开 TUN 走 `privilegedLauncher.start`(弹 1 次密码)；若其后 `healthVerifier`(loopback ping Clash API, ~6s)或 `processMatches` 失败 → catch 里 `privilegedLauncher.stop()` 杀刚起的 root 内核**会再弹 1 次密码**（内核已自行退出时不弹）。故一次失败可能弹 2 次，用户重试就"一直弹"。
- **要用户提供**：用 0.1.16 点一次 TUN，记下①App 顶部/提示条报的错，②`~/Library/Application Support/kongshan/logs/sing-box-tun.log` 新增尾部（找 FATAL/panic/EOF/permission/bad tun）。有这两样才能定位是提权失败、进程校验失败、还是内核起后即退。
- 可选加固（待定位后）：失败 teardown 时若内核已退出就别再走提权 stop（已是现状）；可给 TUN 失败一个更明确的错误文案，减少用户盲目重试。

## 真机回归（本会话大量改动，务必过一遍）
1. **系统代理**：点一下应"又快又不卡"（之前是托盘菜单 100% CPU 拖累，已修）。开启后提示条会显示"启动耗时 → …"，正常零点几秒。
2. **TUN**：点 TUN→输密码→秒级接管；`~/Library/Application Support/kongshan/logs/sing-box-tun.log` 应有 `inbound/tun` 正常路由，无 `EOF`/`bad tun name`。
3. **配置切换 / 节点增删**：运行中热重载 <2s，不卡。
4. **托盘菜单**：每个策略子菜单最多 40 项，超出显示"在代理页选择全部（N 个）…"。
5. 空闲 CPU 应为 0%，RSS <150MB（实测 141MB）。

## 环境备注
- 早前有一次 `~/Library/Application Support/kongshan` 数据与 `.app` 丢失，**经用户确认是那次手动删除**，并非 CleanMyMac 后台反复清理（此前交接文档把一次性事件误判为"反复删除"，已更正）。2026-07-21 实测：数据目录自当天 11:28 导入订阅后稳定留存到 16:57，app 完整（54MB）。**无需特意在 CleanMyMac 排除**，除非日后真的再次自动消失。
- 用户是**笔记本(主屏,菜单栏) + 上方大外接屏**的多显示器；窗口已强制居中到主屏。

## 可选（非阻塞）
- 订阅级自定义 UA / base64 格式回退；`profile-update-interval` 头。
- 一次性特权 helper（SMAppService+XPC）替代每次 TUN 提权弹窗。
- 策略组还原订阅成员的嵌套引用；被丢弃订阅规则的可见提示。
- 托盘实时速率、外部访问（需破红线，待用户拍板）。
- 启动时那一次性 ~2s CPU 峰值（首建菜单+载配置）可再优化，但已可接受。
- 清理 start() 里的临时计时提示（"启动耗时 → …"每次开代理都进 warnings，确认没问题后可去掉或只在慢时显示）。
