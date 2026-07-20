# 项目交接

- 已完成：M4 Task 6；实现默认 24h、可设置 1–168 小时的订阅自动更新、一次性调度、缓存保留告警、本地通知和设置 UI。
- 修改文件：新增 `SubscriptionUpdateScheduler.swift`、`NotificationService.swift`、`SubscriptionUpdateSchedulerTests.swift`；修改 AppState、MainWindowView、AppStateTests 与相关计划/记录。
- 测试结果：RED 证明 scheduler/settings/notification API 缺失；GREEN 为全量 126/126，release arm64、codesign strict、diff check 与无节点冷启动通过。
- 当前状态：自动更新按最早到期订阅安排单个可取消 sleep，完成后重排；失败保持旧节点/缓存，通知权限拒绝不影响代理。
- 风险/注意事项：未请求真实通知权限或刷新真实订阅；自动测试只用 fake sleeper/sender。无节点启动没有内核、系统代理/TUN 恢复文件。
- 下一步：M4 Task 7 实现 `SMAppService.mainApp` 开机自启。
- 接手方式：从 M4 计划 Task 7 Step 1 开始；初始化只读取登录项状态，只有用户主动开关才能 register/unregister，测试必须使用 fake manager。
