# 项目交接

- 已完成：M4 Task 2；DNS 旧设置兼容、离线持久化、system/TUN 在线事务与回滚、诊断配置更新，以及原生 DNS 高级设置界面。
- 修改文件：`Sources/kongshan/AppState.swift`、`MainWindowView.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、M4 计划与全部记录。
- 测试结果：RED 因 `dnsSettings/applyDNSSettings` 缺失；GREEN 为 DNS AppState 5/5、全量 99/99；release arm64 组装、严格 codesign 与 diff check 通过。
- 当前状态：Task 2 完成；统一 config helper 确保启动/分流/TUN/DNS 四条路径都使用当前 DNS，在线失败恢复旧内核配置与旧设置。
- 风险/注意事项：system 模式 UI 已明确不接管 macOS 全局 DNS；真实 DNS 泄漏和 DoH 连通仍未冒充通过。设置落盘发生磁盘级故障的极端事务需在最终故障注入审视。
- 下一步：M4 Task 3 实现 Clash API WebSocket 流模型与 version API。
- 接手方式：从 M4 计划 Task 3 Step 1 写 stream factory fake 测试；必须证明消费取消会关闭底层 WebSocket。
