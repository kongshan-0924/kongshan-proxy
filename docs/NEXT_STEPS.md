# 下一步

1. 修复人工双击/重新打开时显式创建并激活主窗口，同时让 `SMAppService` 登录项启动保持菜单栏静默；重打包后人工验证三条窗口路径。
2. 在 Bartender 6 中把 kongshan 状态项设为始终显示或移动到主菜单栏；应用只负责注册状态项，不使用私有 API 指定坐标。
3. 准备真实奶昔/Nexitally 订阅和自建 Hysteria2，在可接受短时网络中断的环境按 `docs/acceptance/M4.md` 第 1–7 项验证系统代理/TUN/分流/DNS/恢复。
4. 将 `dist/kongshan.app` 移至 `/Applications`，人工验证登录项批准、下次登录启动、本地通知允许/拒绝和崩溃通知。
5. 使用真实节点核对 Dashboard/日志，并在关闭页面/窗口后用系统工具确认没有 Clash WebSocket。
6. 最后执行 24h Instruments Leaks/Allocations 与 Activity Monitor Energy Impact 观察；逐项把时间、环境、命令和结果追加到 M4 acceptance 与 SESSION_LOG。
