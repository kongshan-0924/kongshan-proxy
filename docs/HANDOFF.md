# 项目交接

- 已完成：M4 Task 4；实现 Dashboard 可见会话、实时上下行/连接/内存/版本/运行时长以及 Swift Charts 60 秒曲线。
- 修改文件：`Sources/kongshan/AppState.swift`、`Sources/kongshan/DashboardView.swift`、`Sources/kongshan/MainWindowView.swift`、`Tests/KongshanAppTests/AppStateTests.swift`、M4 计划及全部记录。
- 测试结果：RED 为 Dashboard 状态/API 缺失；GREEN 为 Dashboard 3/3、全量 107/107，debug/release 构建、arm64 与 codesign strict 通过。
- 当前状态：仅当页面可见且代理开启时消费两条 WebSocket；重复 appear 幂等，disappear、stop 和 config reload 会取消，断流只记 warning 不擅自关代理。
- 风险/注意事项：未用真实节点验证指标推送；无节点 release 启动稳定且无内核/接管，当前工具无法附着菜单栏 UIElement 生成视觉截图。
- 下一步：M4 Task 5 实现日志有界存储、实时页、等级切换和安全导出。
- 接手方式：从 M4 计划 Task 5 Step 1 开始；先写 KernelLogStore 测试，确保内存 2000 行、磁盘有限转、导出不含敏感运行值。
