# 项目交接

- 已完成：M3 Task 6 原生模式 UI；Dashboard/设置提供 segmented picker，strict_route 可离线保存或在线事务更新，菜单栏区分关闭/system/TUN。
- 修改文件：`Sources/kongshan/AppState.swift`、`Sources/kongshan/MainWindowView.swift`、`Sources/kongshan/MenuBarView.swift`、`Tests/KongshanAppTests/AppStateTests.swift` 与 M3 计划/记录。
- 测试结果：strict 定向 3/3、AppState 18/18、全量 88/88；debug/release 编译、arm64、ad-hoc codesign 严格验证通过。
- 当前状态：M3 Task 6 已完成，`dist/kongshan.app` 已更新；空节点无授权冒烟进程正常，无 proxy/TUN recovery 文件。
- 风险/注意事项：冒烟 2 秒采样为 RSS 75968 KB、CPU 0.7%（启动期，非稳态性能结论）；本机状态栏管理环境仍无法稳定执行自动视觉点击。
- 下一步：实现 `verify_m3.sh`，执行完整自动验收并固化 M3 人工边界。
- 接手方式：先读本文件、M3 计划与最新 SESSION_LOG，从 Task 7 Step 1 开始；验证脚本严禁运行提权 osascript 或启动 TUN。
