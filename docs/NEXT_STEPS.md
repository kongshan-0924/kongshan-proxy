# 下一步

## 0.1.40 已装本机（当前版本）

1. 点 TUN（App 重建过，会弹一次密码重装助手；上一个假死内核会被新的升级信号杀掉）。
2. 起来后**合盖休眠再唤醒**，重点看：
   - 唤醒后 TUN 是否自动恢复（网卡没了会提示"正在重建隧道"并自动重建）；
   - 若没恢复，关掉再开应能**正常起来**，不再卡在 `kernel already running`。
3. 顺带验：拔插网线/切 Wi-Fi 后代理仍在、退出 App 后无残留 root 内核
   （`pgrep -lf sing-box` 为空）。

验证通过后：提交 → squash 合并 `main` → 推送 → 发布 v0.1.40。

## 0.1.39 已装本机（当前版本）

**点一次 TUN 即可**。App 重建过（cdhash 变），流程会是：
弹一次密码重装助手 → 自动清掉上一次遗留的内核 → 起新内核 → TUN 上线。
之后关掉再开应**零弹窗**。

出口 IP 想验准，需要在**没有透明代理的网络**下测（手机热点最省事）——
家里路由器在做 SNI 分流代理，会把发给节点的握手改写掉，判据见
`docs/design/tun-real-machine-debug.md`。

验证通过后：提交 → squash 合并 `main` → 推送 → 发布 v0.1.39。

## 0.1.38 已装本机（当前版本）

1. **先关掉 Stash 的 TUN**（它占着 utun4=198.18.0.1）。
2. 打开 kongshan → 点 TUN。App 重建过所以 cdhash 变了，会**弹一次密码重装助手**，
   之后这次启动就走助手；再关掉重开应**零弹窗**。
3. 起来后确认：仪表盘出口 IP 是节点所在地、网页能打开。
4. 若还失败，先看内核日志有没有内容：
   `tail -40 "/Library/Application Support/kongshan/helper/sing-box-tun.log"`
   —— 有内容说明配置已送达（问题在配置本身），0 字节说明还是卡在喂配置。
5. 需要手动清残留内核：`sudo pkill -f '/Library/Application Support/kongshan/helper/sing-box'`

## 0.1.37 已装本机（当前版本）

助手已经是「已安装」状态，这版修的是最后一环（配置 FD 传不过去 → `missing config fd`）。

1. **先关掉 Stash 的 TUN**（它占着 utun4=198.18.0.1，两个 TUN 会抢默认路由）。
2. 点 kongshan 的 TUN：助手已装 → 预期**一次密码都不弹**直接起来；
   若 App 又重建过（cdhash 变）则弹一次装助手，之后零弹窗。
3. 起来后确认：仪表盘出口 IP 是节点所在地、能正常上网。
4. 关掉再开一次，确认零弹窗且没有残留：`pgrep -lf sing-box` 应为空。

仍有问题的话，把顶部提示条的完整文字发我。

## 0.1.36 已装本机（当前版本）

**验收前先关掉 Stash 的 TUN**（它现在占着 utun4=198.18.0.1；两个 TUN 会抢默认路由）。

1. 点 kongshan 的 TUN → **应只弹一次密码**（装助手）→ 之后关掉再开，**零弹窗**。
   如果仍弹两次，把顶部错误条的完整文字发我。
2. 设置 → 隧道 → 免密码助手：状态应是「已安装」。
3. TUN 开着时，那三个助手按钮应全灰 + 橙字提示。
4. 残留内核清理：TUN 运行中执行
   `sudo launchctl kickstart -k system/com.kaysen.kongshan.helper`，
   再从 App 关 TUN，应能正常停掉且 `pgrep -lf sing-box` 为空。

全部通过后：提交 → squash 合并 `main` → 推送 → 发布 v0.1.36。

## 0.1.35 已装本机（当前版本）

**第一件事：点一次「重新安装」助手。** 设置 → 隧道 → 免密码助手 → 「重新安装」→ 输密码。
机器上现存的是旧助手（trust v2，身份校验对不上），必然显示"需重装"，这是预期。
装完状态应从「需重装」变成「已安装」；若仍是「需重装」，把设置页那条橙色提示发我。

装好后依次验：

1. 连续开关 TUN 两次 → 除装助手那次外应**零弹窗**。
2. TUN 开着时，设置 → 隧道的安装/卸载/重装按钮应全灰 + 橙字提示。
3. 残留内核清理：TUN 运行中执行 `sudo launchctl kickstart -k system/com.kaysen.kongshan.helper`
   杀并重启助手，再从 App 关 TUN，应能正常停掉且 `pgrep -lf sing-box` 为空。
4. 换一个不拦节点的网络，开系统代理 → 仪表盘出口 IP 应变成节点所在地。
   当前网络把订阅里两个节点都拦了（TCP 3ms 假握手、TLS 零响应），在这里测不出来。

全部通过后：提交 → squash 合并 `main` → 推送 → 发布 v0.1.35。

## 0.1.34 已装本机（当前版本）

已安装 `/Applications/kongshan.app` 0.1.34（build 134）。自动化能测的都测了（285 单测 + 真机端到端，见 SESSION_LOG 2026-07-27 00:30）。**剩下两项必须由用户实测**：

1. **换一个不拦节点的网络**再验收：开系统代理 → 仪表盘出口 IP 应变成节点所在地。当前网络把订阅里两个节点都拦了（TCP 3ms 假握手、TLS 零响应），在这里测不出来。
2. **TUN 模式**（需要 root 密码，自动化测不了）：
   - 首次开 TUN 弹一次密码装助手，之后连续开关两次应零弹窗；
   - TUN 开着时 设置 → 隧道 的安装/卸载/重装助手按钮应全灰 + 橙字提示；
   - 残留内核清理：TUN 运行中 `sudo launchctl kickstart -k system/com.kaysen.kongshan.helper` 杀并重启助手，再从 App 关 TUN，应能正常停掉、`pgrep -lf sing-box` 为空。

验收通过后：提交 → squash 合并 `main` → 推送 → 发布 v0.1.34（DMG 已在 `dist/`）。

## 0.1.33 已装本机，等真机验收

已安装 `/Applications/kongshan.app` 0.1.33（build 133）。下面这几条是这版**新改动**的针对性验收，通过后才提交合并：

1. 首次开 TUN 会弹一次密码自动装/重装助手（App 重建后 cdhash 变，旧助手必然被拒）；之后连续开关 TUN 两次应零弹窗。
2. **TUN 开着时**进 设置 → 隧道：安装/卸载/重装助手按钮应全部灰掉，并显示橙色说明；关掉 TUN 后恢复可点。
3. 残留内核清理（P1 核心）：TUN 运行中在终端 `sudo launchctl kickstart -k system/com.kaysen.kongshan.helper` 杀掉并重启助手，helper 应认领原内核 —— 此时 App 里关 TUN 应能正常停掉、不留 root sing-box（`pgrep -lf sing-box` 为空）。日志：`log show --predicate 'process == "KongshanHelper"' --last 10m`。
4. 关 TUN 时若代理/DNS 还原失败，顶部应显示红色错误 + 「系统设置 → 网络 → 详细信息 → DNS」指引，而不是「可忽略」。
5. 菜单栏速率应是紧凑的 `900B` / `1.5K` / `5.0M` 形式、0 时显示 `—`，宽度不乱跳。
6. 订阅列表里刚导入、还没跑流量的配置，用量应显示 `— / 100 GB` 而不是「 / 100 GB」。
7. 其余照旧：TUN 下国内外网页 + 出口 IP、运行中切节点/配置/规则、VLESS 订阅、脱敏诊断导出。

验收通过后：提交本次改动 → squash 合并 `main` → 推送 → 发布 v0.1.33（DMG 已在 `dist/kongshan-0.1.33.dmg`）。

## 已修复（2026-07-25 复审 P1~P6，记录留档）

按优先级；完整依据见 `docs/progress/SESSION_LOG.md` 2026-07-25 21:10 条。

1. P1 `PrivilegedHelperInstaller.uninstall/install` 不先停内核，且设置页 卸载/重装 按钮没按 TUN 是否在跑禁用 → 可能留下 App 无法清理的 root sing-box。最小修：按钮加 `state.activeModes.contains(.tun)` 禁用；彻底修：helper 落 `stateDirectory/kernel.pid` + 启动时 reconcile，卸载脚本先停内核。
2. P2 `AppState.stop()` 中 DNS/代理还原失败的「可忽略，下次启动自动清理」文案改成 errorMessage + 手工恢复指引（不阻塞退出这点保持）。
3. P3 `MainWindowView.swift:341`、`DashboardView.swift:343` 改用 `Theme.bytesOrDash` 或 0 兜底。
4. P4 菜单栏 `MenuRateFormatter.compact` 恢复手写 1 字母紧凑格式，只保留 0 → 空串行为。
5. P5 白名单回归测试补 `[.tun,.systemProxy]` 与 TUN+直连两种组合；注释写清未覆盖 `dns`/`route`/outbound 非 type 字段。
6. P6 高位端口范围收进 `HelperConstants` 单一来源。

## 0.1.32 自动验证已完成

- `swift test`：282 通过、1 跳过、0 失败；VLESS 配置通过内置 sing-box check。
- 10 张离屏界面快照生成成功，规则页已人工检查。
- 0.1.32/build 132 为 arm64；主 App、KongshanHelper 深度签名及 hardened runtime 通过。
- sing-box 1.13.14、DMG 与 M4 自动验证通过；空闲 CPU 平均 0%，最大 RSS 124032 KB。
- 成品：`dist/kongshan-0.1.32.dmg`；SHA-256 `ec255233febb71d6152719d592bcef970084dca6018069a587b72cce3180f00c`。
- 旧 0.1.31 DMG 已移入废纸篓，dist 只保留当前版本。

## 用户真机验收

1. 安装 0.1.32；设置 → 隧道重新安装免密码助手一次，连续开关 TUN 两次应只首次授权。
2. TUN 下打开国内外网页并检查出口 IP；运行中切节点、配置和规则后关闭，确认没有残留 root sing-box。
3. 验证系统代理和 DNS 在网络服务/配置切换后恢复；失败应显示消息并保留 recovery 文件。
4. 刷新含 VLESS 的订阅，确认 VLESS 节点不再被跳过，TLS/WS/gRPC/Reality 节点可连接。
5. 检查订阅兼容性消息、规则页“选择已安装 App”、设置页“导出脱敏诊断”、应用更新入口、内核更新文案。
6. 检查侧栏唯一按钮、消息/内核日志、托盘与连接速率、GB/TB 和缓存大小。
7. 用户明确验收通过后，维护者复审并决定 squash 合并 `main`、推送和发布 v0.1.32。

## 暂不扩张

- 不加入 TUIC/WireGuard，除非真实订阅出现需求。
- 不引入 Sparkle；private 仓库没有可安全匿名访问的更新源。
- 不为拆文件而重写 `AppState`；后续只随真实功能按领域拆 extension。
