# 项目进度

## 当前版本

- [x] **0.1.32 统一功能版**：TUN 设置收口、IPv6-only 保护、VLESS、订阅兼容性统计、脱敏诊断、选择已安装 App、应用更新入口均已完成并构建。
- [x] 维护者代码复审（2026-07-25）：构建 0 警告、282 测试通过；核心设计判定可合，另列 6 项待修（P1~P6）。
- [x] **0.1.33 修复版**：P1~P6 全修，285 测试通过。
- [x] **0.1.34 全面审计版**（当前）：全量源码审计再修 10 项（含 ProcessRunner 数据竞争、Reality 凭据未脱敏、SIGPIPE 杀进程）；285 单测 + 真机端到端全跑通；已装 `/Applications`。
- [x] **0.1.35**：修复免密码助手身份校验硬伤（助手此前从未生效）；模块巡检（实时流/退出监控/规则集/日志）全通过。
- [x] **0.1.36**：修复 launchd 装载竞态（`Bootstrap failed: 5: EIO`）——助手装不上、开 TUN 要输两次密码的直接原因。
- [x] 新网络下代理功能验收通过：系统代理 + TUN 双开，出口 IP 为节点所在地，DNS 无泄漏。
- [ ] 用户实测：关掉 Stash 的 TUN → 点一次 kongshan TUN → 只弹一次密码 → 之后启停零弹窗。
- [ ] 验收通过后提交、squash 合并 `main`、推送并发布 v0.1.36。

成品：`dist/kongshan-0.1.36.dmg`（已装 `/Applications`）。全量测试 291 通过、2 跳过、0 失败；0 编译警告；arm64、deep/strict 签名、hardened runtime 通过。

## 已完成能力

- [x] macOS 原生菜单栏与主窗口，单一固定侧栏按钮，多显示器窗口恢复。
- [x] Clash YAML 订阅、自动更新、用量/到期信息、配置切换与缓存兜底。
- [x] SS、Trojan、VMess、Hysteria2、AnyTLS、VLESS 节点转换与 sing-box 配置生成。
- [x] 机场策略组、订阅规则、自定义规则、分应用代理、直连/规则/全局模式。
- [x] 系统代理与 TUN 可独立/同时启用；gVisor、Fake-IP、IPv4/IPv6 网络适配。
- [x] 免密码 TUN helper、代码签名/CDHash 钉死、配置白名单、崩溃自愈。
- [x] 系统代理/DNS 快照、失败回滚、启动恢复与网络变化补挂。
- [x] 出口 IP/地区/运营商、DNS 泄漏检测、实时连接速率、托盘速率。
- [x] 节点旗帜/倍率、搜索排序、测速并自动选最快。
- [x] 消息中心、实时内核日志、脱敏配置与诊断导出。
- [x] 配置/设置备份恢复、缓存管理、登录启动、规则集与内核更新检查。
- [x] arm64 App/DMG 自动构建、版本递增、hardened runtime 与签名验证。

## 历史

完整逐阶段记录保留在 `docs/progress/SESSION_LOG.md`；TUN 真机根因与证据保留在 `docs/design/tun-real-machine-debug.md`。
