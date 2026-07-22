# 下一步

## ✅ 合并已完成（2026-07-22）— main 升到 0.1.23

`fix/tun-ipv6-no-route`（超集）已 **ff-only 合并进 main 并推送 origin**（origin/main = `14ee357`）。一次带进：侧栏固定按钮修复 + 全部 network-obs 新功能 + TUN IPv6 修复 + 合并前 2 条审核修复。已删除被完全包含的 `fix/sidebar-toggle`、`codex/network-observability-batch`、`fix/tun-ipv6-no-route` 三条本地分支，并移除其 worktree（`.worktrees/` 已清）。

**现在只剩两条分支**：
- `main` 0.1.23（已推 origin，`14ee357`）
- `feat/tun-passwordless-helper`（独立，TUN 免密码助手，第三轮未完，见下）

**合并前审核（我负责）结论**：独立对抗式 subagent 复审整份 Sources/ diff + 亲自精读 IPv6 修复 → **无阻塞问题**（无崩溃/数据竞争/备份回滚破损/明文 secret；IPv6 修复内存安全、fe80::/10 分类正确）。合并前修掉 2 个 medium（提交 `14ee357`）：
1. 出口诊断 `onAppear` 无条件触发：代理关时会用真实 IP 直连 `am.i.mullvad.net` + 3 次 DNS。改为仅 `state.isOn` 时自动检测（手动「检测」按钮、start() 成功、切主节点三条路径保留/本就已门控）。
2. `NodeNameMetadata.parsedMultiplier` 每次现编译 2 条正则、在节点列表逐节点每帧调用（测速时高频）→ 命中项目历史 O(n²)/CPU 雷区。改 `static let` 缓存编译，行为不变。
另有 4 个 low 记为非阻塞待办（见文末「可选」）。

**⚠️ 已合并但尚未构建成 App**：`dist/kongshan-0.1.23.dmg` 是旧产物，**不含** IPv6 修复及其后合并的 2 条审核修复。要在真机跑需重新 `scripts/build_app.sh`（会自增版本，如 0.1.24）。

### 剩余工作（按优先级）
1. **真机重打包验证**（见下方「真机重打包验证 TUN IPv6 修复」）——这份新 build 同时含 IPv6 修复 + 2 条审核修复 + 全部 0.1.23 功能与七类界面。
2. **TUN 免密码助手第三轮**（`feat/tun-passwordless-helper`，见下）：做完 3 条修复 + 重跑安全审查 → 合 main。**届时会与已进 main 的 network-obs 在 `Sources/kongshan/AppState.swift` + `Sources/kongshan/MainWindowView.swift` 冲突，需手动解**。

## 🔴 TUN 免密码助手 —— 第三轮 3 条修复未完（在 `feat/tun-passwordless-helper` 分支）

> 所有设计/威胁模型/实现/三轮修复清单在 **`feat/tun-passwordless-helper` 分支** 的 `docs/design/tun-passwordless-helper*.md`（**本分支没有这些文件**，别以为丢了）。功能 ~95% 完成，两轮独立安全审查已做。用户已选"由接手方实现第三轮修复(不再交 Codex)"。

**第三轮 3 条（做完 + 重跑安全审查过了即可合并）**：
1. **C① [阻断·root 提权] sing-box verify→exec TOCTOU**：helper 已迁 root-only，但 sing-box 仍在 bundle(管理员组对 /Applications 可写)。`startSingBox`(KongshanHelper/main.swift)先按路径校验 cdhash、之后按**同一路径** posix_spawn，可被原子替换 → root 执行任意码。**修法：安装时把 sing-box 也拷到 `stateDirectory`(root:wheel 0755，与 helper 同构)，`trust.singBoxExecutablePath` 指向该拷贝** → 路径不可写、TOCTOU 消失。改 `PrivilegedHelperInstaller`(加 sing-box 拷贝) + trust 字段。
2. **C② [低危] fail-closed**：`computeCDHashHex` 返回 nil 现静默写 null=不钉；`install()` 加 `guard let … else { throw }`。
3. **N1 [可靠性]**：`startSingBox` 失败(cdhash 不匹配等)不关 `configFD` → 泄漏 + 卡死 App 后台写线程；顶部 `defer { close(configFD) }` / `defer { close(logFD) }`。

**做完后**：`swift build`/`test` 全绿 → **重跑独立对抗式安全审查(重点 C① 是否真消除 TOCTOU)** → 合并。真机验收：设置→隧道→「安装免密码助手」授权一次 → 开 TUN 应零弹窗。

---

## 当前最高优先级：真机重打包验证 TUN IPv6 修复（fix/tun-ipv6-no-route）

1. 在 `fix/tun-ipv6-no-route` 分支跑 `scripts/build_app.sh` 重打包，安装到 /Applications。
2. 开 TUN，确认：
   - `~/Library/Application Support/kongshan/logs/sing-box-tun.log` **不再有** `outbound/direct[direct]: ... no route to host` 针对 240e:... 的错误。
   - 中国网站正常打开（不再因 IPv6 直连失败卡住）。
   - 国外网站经代理正常（ChatGPT/Google 等）。
   - `config.json` 的 TUN inbound `address` 只有 `172.19.0.1/30`，没有 `fdfe:dcba:9876::1/126`。
3. 通过后合并 `fix/tun-ipv6-no-route` → main（或先合进 `codex/network-observability-batch` 再统一合 main，因为本分支就基于 codex）。
4. 注意：切到有 IPv6 的网络时，探测会自动返回 true，TUN 自动恢复 IPv6 地址，无需手动改设置。

## 验收 0.1.23 网络可观测与控制增强

1. 打开已运行的 `/Applications/kongshan.app`（0.1.23/build 123），仪表盘点“检测”，确认出口 IP、地区/运营商和 DNS 三态结果符合当前节点。
2. 在“代理”页检查旗帜/倍率，点“测速并选最快”；开启代理后到“连接”页确认每条速率、总速率和排序，并检查托盘速率。
3. 在“规则”页小范围验收一条分应用规则；在“设置 → 更多”导出一份备份，仅在代理停止后测试导入。备份含凭据，不要上传或外传。
4. 继续检查侧边栏展开/折叠时唯一按钮固定在左上角。
5. 用户明确“验收通过”后，再把 `codex/network-observability-batch` 合并 main；此前保留分支和 worktree。

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
