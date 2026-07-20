# 项目交接

- 已完成：M3 Task 2 安全提权传输；只暴露固定的 TUN 启动/停止 AppleScript，校验 PID，通过 0600 FIFO 向特权进程传送内存配置。
- 修改文件：新增 `Sources/KongshanCore/PrivilegedLauncher.swift`、`Tests/KongshanCoreTests/PrivilegedLauncherTests.swift`，并更新 M3 计划与记录。
- 测试结果：PrivilegedLauncher 定向 6/6、全量 `swift test` 70/70 通过；AppleScript 仅编译验证，262144 字节 FIFO 完整一致并清理。
- 当前状态：M3 Task 2 已完成，准备执行 Task 3 特权 TUN 生命周期与崩溃恢复。
- 风险/注意事项：自动测试没有运行 `osascript` 授权或创建真实 TUN；当前仅是安全构造和 transport，还未持久化恢复记录。
- 下一步：按 TDD 注入 Authorizer/ProcessInspector，实现 PID 命令身份复核、原子恢复记录和安全停止。
- 接手方式：先读本文件、M3 计划与最新 SESSION_LOG，从 Task 3 Step 1 开始；不得在自动测试中触发管理员授权。
