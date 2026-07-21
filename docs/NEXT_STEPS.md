# 下一步

## 🔴 立即验证（0.1.16 刚修，等用户真机确认）

### A. 开代理是否生效 / 手动选择是否管用（已修，待确认）
- 0.1.16 已把机场主组(TAGSS)与 final、DNS 都接到「手动选择」。**用户操作**：打开 0.1.16 → 代理页「手动选择」挑一个日本/香港节点 → 开系统代理 → 看仪表盘出口连通性 Google/GitHub 应变「可达」。
- 若仍不可达：先确认所选节点本身可用（换一个节点/测速），再抓 `config.json` 看 `outbounds` 里 TAGSS 的 `default` 是否＝手动选择、`route.final` 是否＝手动选择。
- 出站 IP 跳动应一并消失（final 不再是 urltest）。

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
