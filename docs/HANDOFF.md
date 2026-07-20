# 项目交接

- 已完成：M4 Task 8；实现普通/TUN 精确 PID 退出监控、10 秒最多 3 次自动重启、超限/失败清理和通知。
- 修改文件：新增 `CrashRestartLimiter.swift`、`ProcessExitMonitor.swift`、`CrashRestartTests.swift`；修改 SingBoxProcess、AppState、NotificationService 与相关测试/计划/记录。
- 测试结果：RED 证明 limiter/monitor/currentPID/AppState API 缺失；竞态回归修复后全量 137/137，release arm64、codesign strict、diff check 与无节点冒烟通过。
- 当前状态：真实普通用户 sing-box SIGKILL 可新 PID 恢复且不重复 networksetup；主动 stop/DNS/分流/TUN 重载不会计入崩溃，TUN fake 第 4 次会清理并通知。
- 风险/注意事项：未真实启动 root TUN 或触发管理员授权/通知；真实 TUN 崩溃重启与 root PID 监听仍属人工验收。
- 下一步：M4 Task 9 完成性能和一键自动验收、README、M4 验收记录。
- 接手方式：从 M4 计划 Task 9 Step 1 开始；先让缺失 `verify_m4.sh` 失败，再实现无节点 CPU/RSS/残留检查，保持真实网络项为人工边界。
