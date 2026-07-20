# 项目交接

- 已完成：M3 Task 5 TUN 在线分流事务；复用原 runtime，用特权 launcher 停/启新配置，失败时回启旧 root 配置，双重失败则关闭。
- 修改文件：`Sources/kongshan/AppState.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、`Tests/KongshanCoreTests/PrivilegedLauncherTests.swift` 与 M3 计划/记录。
- 测试结果：TUN routing 定向 3/3、AppState 15/15、全量 `swift test` 85/85 通过；FIFO 读取夹具的偶发 waitUntilExit 阻塞已改为有界完成标记。
- 当前状态：M3 Task 5 已完成；TUN 规则更新不会调用 networksetup，新旧 config 的 Clash controller/secret 保持一致。
- 风险/注意事项：AppState RED 测试使用只消费 stdin 的安全假内核，避免错误实现尝试真实 TUN；未执行管理员授权。
- 下一步：实现原生 system/TUN segmented picker、strict_route 开关、精确说明与菜单栏模式状态。
- 接手方式：先读本文件、M3 计划与最新 SESSION_LOG，从 Task 6 Step 1 开始；编译/冒烟不得点击 TUN 或触发授权。
