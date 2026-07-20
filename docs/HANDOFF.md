# 项目交接

- 已完成：M3 Task 3 特权 TUN 生命周期；启动后复核 PID 命令行，原子写入最小恢复记录，停止时再次复核并在 root shell 中二次防护。
- 修改文件：扩展 `Sources/KongshanCore/PrivilegedLauncher.swift` 与 `Tests/KongshanCoreTests/PrivilegedLauncherTests.swift`，并更新 M3 计划与记录。
- 测试结果：PrivilegedLauncher 定向 13/13、全量 `swift test` 77/77 通过；授权取消/超时/非零退出、坏 PID、错进程、停止失败保留记录、重启恢复和敏感值不落盘均通过。
- 当前状态：M3 Task 3 已完成，准备执行 Task 4 AppState 模式持久化与互斥切换。
- 风险/注意事项：仍未执行真实管理员授权或 TUN；MVP 依赖每次固定 AppleScript 授权，未来应迁移至 SMAppService helper 或 Network Extension。
- 下一步：按 TDD 为 AppState 注入可测特权 launcher，贯通初始恢复、system↔TUN 切换与退出。
- 接手方式：先读本文件、M3 计划与最新 SESSION_LOG，从 Task 4 Step 1 开始；保持两种接管方式不同时活动。
