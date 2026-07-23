# 下一步

## ✅ 真机 TUN 已修复 + 已合并 main + 发布 GitHub release v0.1.30（2026-07-23）

### 已完成
- 根因定案：系统 DNS 错指 `172.19.0.2`，该地址从 `en0` 去物理网关而非进入 TUN；正确地址是有 `utun LOCAL` 路由的接口自身 `172.19.0.1`。
- `TunSettings.dnsServerAddress` 已改为接口 IPv4；TUN Fake-IP 改为 `240/4` 并持久化到 `fakeip-cache-v2.db`，避开订阅/物理网关的 `198.18` 冲突。
- 全量 `swift test`：259 通过、1 跳过、0 失败；HY2+TUN 配置通过 sing-box check；0.1.30 构建、深度签名和 hardened runtime 均通过。
- 两轮真机内核 PID 36946 → 37470，Google Fake-IP 均为 `240.0.0.4`；Google 204、百度 200、GitHub 200，出口 IP `69.63.217.24`。
- Chrome 与 Safari 两轮均正常打开 Google/百度；系统 DNS 两轮都由应用自动设为 `172.19.0.1`。0.1.30 已安装，TUN 当前开启。

### 已发布（维护者本会话完成）
- 审核 Codex 修复（正确）→ **squash 合并 main**（安全捕获：含节点真实密码的中间提交未推 origin，squash 丢弃、确认主历史 0 密码）→ 构建 DMG → **GitHub release v0.1.30（Latest）** 含 DMG（SHA-256 `86ad8e0009c811ecd4e447b852bb5c601927fdee4269352c634e42d487c8c353`）。**仅剩 main 一条分支。**

### ⚠️ 唯一待办：一次 force-push（清远程的密码片段）
- 我的 docs 记录里误留了密码前 8 位片段（**非可用完整密码**），已在**本地 amend 干净**（`3beda05`），但 **origin 上那个提交（`42a9d3c`）还含片段** → 本地与 origin 分叉（领先1/落后1）。
- **运行这条完成收尾**（force-push 被自动分类器拦、需用户手动执行）：
  ```
  cd /Users/kaysen/workspace/mac/代理软件 && git push --force-with-lease origin main
  ```
- 跑完 origin 全历史 0 密码片段、本地与 origin 一致。**在此之前别在 main 上新提交后普通 push**（会因分叉失败）。

### 可选 / 后续
1. 有条件回企业**双默认网关**网络再开一次 TUN 复验（本次修复在 en0 单网关下验证通过）。
2. 「设置 → 隧道」安装免密码助手，TUN 启停免密（不影响连通）。
3. UI 小项：设置里「TUN 协议栈」下拉已失效（生成配置强制 gvisor），可从 UI 移除或改只读说明。

### 接手
读 `docs/design/tun-real-machine-debug.md` §19-20 + `docs/HANDOFF.md` 顶部最新段。不要再从节点、QUIC、DoH 或 Fake-IP 缓存开始；先核对系统 DNS 是否为 TUN 接口自身地址及其路由是否 `LOCAL`。

---

## ✅ 免密码 TUN 助手已加固 + 合并 + 交付 0.1.24（2026-07-23）

免密码 TUN 特权助手（`feat/tun-passwordless-helper`）经两轮独立对抗式安全审查 + 加固后**已合并进 main**（merge `64c2b00`）。代码三方自动合并（AppState/MainWindowView 无冲突），合并后 `swift test` **257 通过**。已构建交付 **0.1.24**，装到 /Applications、打了 DMG、清理到只剩一个最新版。

**当前状态**：
- `main` = 0.1.24（本地领先 origin 若干提交，**待推**）。仅剩一条待清理分支 `feat/tun-passwordless-helper`（已完全并入，可删）。
- 成品：`/Applications/kongshan.app` 0.1.24（已装、启动测试通过）；`dist/kongshan-0.1.24.dmg`（SHA-256 `7fd707cc0a6e059d83add13bbb6622b40c291355c4b4aad81d5f8212acee5f4e`）。旧 0.1.23 产物已删。
- 硬化签名已验证：主可执行 + KongshanHelper 均 `flags=0x10002(adhoc,runtime)`，`--deep --strict` 校验有效。

**安全审查（我负责，两轮对抗式）结论**：第三轮（C①/C②/N1/N2）复核正确（C① 实测消除 TOCTOU）。首轮 re-audit 揪出并实证 2 个 BLOCKER → 加固闭合：
1. **配置从没送达**：stock sing-box `run` 无视 stdin（缺 `-c /dev/stdin`）→ TUN 经助手从未真正起来过。改 argv `run -c /dev/stdin` + spawn 存活探测。
2. **§5.1 客户端可被同用户伪造 → root**：identifier 可重签 + 客户端 cdhash 未钉 + ad-hoc 可写 + 无 hardened runtime。加固：安装钉客户端 cdhash（fail-closed）+ build `--options runtime`（实测 ad-hoc 也强制、挡 DYLD 注入）。二轮 re-audit：**无同用户→root 提权链**；逐向量（替换重签/DYLD/task/插件/配置武器化）均被挡，铁律 §1.1–1.6 保持。

**⚠️ 用户真机唯一待办 —— 验证零弹窗 TUN**：
1. 打开 0.1.24 → **设置 → 隧道 → 「安装免密码助手」**，授权**一次**（osascript 弹密码，仅这一次）。
2. 开 TUN，应**零弹窗**接管；关掉再开也不再弹。日志 `~/Library/Application Support/kongshan/logs/sing-box-tun.log` 应有 `inbound/tun` 正常路由（这是免密码 TUN 第一次真机端到端跑通——此前因 BLOCKER① 从未成功过）。
3. 若「安装免密码助手」后仍每次弹密码：多半是 helper 不可达（`isReachable()` false），回退了 osascript 兜底（§1.6，功能正常只是没免密）。查 `/Library/Application Support/kongshan/helper/` 下 helper/sing-box/trust.json 是否 root:wheel、socket 是否建起。
4. 顺带验 TUN IPv6 修复：中国站 + 国外站都通、无 `no route to host`。

**剩余非阻塞待办**（记入「可选」）：helper 侧配置内容白名单（纵深，当前生成 schema 已无 root 写/执行落点）；trust.json 加版本号（防旧配置无 pin 静默降级，新装必钉故仅迁移期）。

**收尾（我做）**：推 main + 删已并入的 `feat/tun-passwordless-helper` 分支。

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
