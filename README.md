# kongshan

kongshan 是一款面向 Apple Silicon Mac 的原生 sing-box 图形客户端。它使用 SwiftUI/AppKit 构建菜单栏与主窗口，打包官方 sing-box 1.13.14，不自研代理协议或加密实现。

当前实现覆盖系统代理与 TUN 两种互斥模式、Clash YAML 订阅、手动 Hysteria2、节点切换与测速、规则分流、双 DoH、Dashboard、实时日志、订阅定时更新、开机自启和内核崩溃自愈。

## 系统要求

- Apple Silicon Mac（arm64）
- macOS 14 或更高版本
- Xcode Command Line Tools / Swift 6 工具链
- 构建时可访问 GitHub，用于下载固定版本 sing-box 与当前官方规则集

## 构建与验证

```bash
cd /Users/kaysen/workspace/mac/代理软件
zsh scripts/build_app.sh
open dist/kongshan.app
```

完整自动验收：

```bash
zsh scripts/verify_m4.sh
```

成功时最后一行为 `M4 automated verification passed`。脚本运行全量测试、构建并校验 arm64 App/签名/内核/规则集，再在隔离的临时数据目录启动无节点 App，检查 CPU、RSS、TCP socket、子进程和恢复残留。脚本不会设置真实系统代理、注册登录项、请求 TUN 管理员授权或发送真实通知。

产物 `dist/kongshan.app` 使用 ad-hoc 签名，未做 Developer ID 签名、公证或自动更新。建议移动到 `/Applications` 后通过 Finder 首次打开；若 macOS 阻止运行，请在“系统设置 → 隐私与安全性”中按系统提示确认，不要绕过系统安全机制。

## 使用说明

1. 在“节点”页导入 Clash YAML 订阅，或手动添加 Hysteria2 节点。
2. 选择节点和代理模式。系统代理模式管理当前活动网络服务的 HTTP/HTTPS/SOCKS 设置；TUN 模式每次启动/停止都可能出现明确的管理员授权弹窗。
3. 在“规则”页维护自定义规则、绕过域名/CIDR 与广告拦截。
4. Dashboard 和日志仅在对应页面可见且代理运行时建立 Clash API WebSocket，离开页面会取消连接。
5. 订阅自动更新默认 24 小时，可设为 1–168 小时。App 未运行期间不会后台唤醒；下次启动时，已到期订阅会立即安排更新。
6. “登录时启动 kongshan”只在用户主动切换时调用 `SMAppService.mainApp`。若显示“等待系统批准”，请打开系统登录项设置批准后返回刷新状态。

## 权限与恢复

- 系统代理：开启前保存每个活动网络服务的原始代理快照；正常关闭时精确恢复。App 异常结束后重新打开，会先尝试恢复遗留快照。
- TUN：配置通过 0600 FIFO 传给经管理员授权启动的 root sing-box；磁盘恢复记录只含 PID、内核路径和启动时间。重启 App 时会核对进程身份，再执行恢复。
- 崩溃自愈：普通/TUN 内核都按精确 PID 监听退出事件；10 秒滚动窗口内最多自动重启 3 次，第 4 次停止接管并尝试发送本地通知。TUN 自动重启仍会显示管理员授权。
- 如果自动恢复失败，不要盲删恢复文件或按不明 PID 杀进程。先退出 kongshan，在“系统设置 → 网络 → 当前网络 → 详细信息 → 代理”核对代理开关；TUN 问题先用活动监视器或 `ps` 核对进程命令确为 App 内置 sing-box，再按界面提示重试恢复。

## 数据与日志

默认数据目录为 `~/Library/Application Support/kongshan/`：

- `subscriptions.json`、`subscriptions/*.yaml`：订阅元数据与成功缓存
- `manual-nodes.json`、`settings.json`、`rules.json`：本地节点与设置
- `rule-sets/*.srs`：验证后的官方规则集缓存
- `config.json`：去除 Clash controller/secret 的诊断快照
- `logs/sing-box*.log`：普通/TUN 内核当前日志与单份轮转，单文件上限 5 MiB
- `proxy-recovery.json`、`tun-recovery.json`：仅在接管期间存在的恢复记录

Clash API 的随机端口与 secret 只保存在内存，不写入设置、日志或诊断配置。日志导出只读取已知日志文件，不导出订阅 URL、配置或凭据。

## 已知限制与人工验收

- 系统代理模式只影响进入本地 mixed 代理的请求解析，不等同于接管 macOS 全局 DNS；真实 DNS 泄漏需在 TUN/真实网络下人工验证。
- 默认兼容性优先，不启用 fake-ip。strict_route 可能影响局域网、虚拟机、容器或其他 VPN。
- ad-hoc 构建下的登录项批准、通知权限与 TUN 授权行为受 macOS 系统策略影响，需要在最终安装路径人工确认。
- 自动测试不能代替真实机场订阅、节点可用性、Google/国内站点、出口 IP、DNS leak、强杀 App 恢复、24 小时 Instruments Leaks/Allocations 与 Activity Monitor Energy Impact 验收。

四阶段自动/人工边界分别记录在 `docs/acceptance/M1.md`、`M2.md`、`M3.md` 和 `M4.md`。
