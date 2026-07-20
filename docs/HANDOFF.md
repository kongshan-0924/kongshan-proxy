# 项目交接

- 已完成：M3 Task 4 模式状态机；持久化 preferredMode/tunSettings，记录 activeMode，实现 system proxy 与 TUN 先停旧、后启新的互斥切换。
- 修改文件：扩展 `Sources/KongshanCore/PrivilegedLauncher.swift`、`Sources/kongshan/AppState.swift`、`Tests/KongshanAppTests/AppStateTests.swift`，并更新 M3 计划与记录。
- 测试结果：AppState 定向 12/12、全量 `swift test` 82/82 通过；fake marker/事件断言 system↔TUN 全程无同时活动。
- 当前状态：M3 Task 4 已完成，旧 settings 缺少新字段时默认 system/strict false；初始化与退出均接入 TUN 恢复。
- 风险/注意事项：自动测试的 TUN 为 fake launcher，未触发管理员授权；运行中 TUN 分流更新尚未分支，由 Task 5 完成。
- 下一步：按 activeMode 将 applyRoutingSettings/rollback 分为普通内核与特权 launcher 两条事务。
- 接手方式：先读本文件、M3 计划与最新 SESSION_LOG，从 Task 5 Step 1 开始；TUN 分支不得调用 networksetup。
