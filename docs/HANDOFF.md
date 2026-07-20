# 项目交接

- 已完成：M4 Task 7；实现 `SMAppService.mainApp` 四状态映射、用户控制的开机自启和待批准系统设置入口。
- 修改文件：新增 `LoginItemManager.swift`；修改 AppState、MainWindowView、AppStateTests 与相关计划/记录。
- 测试结果：RED 证明 login manager/status/AppState API 缺失；GREEN 为全量 131/131，release arm64、codesign strict、diff check 与无节点冷启动通过。
- 当前状态：App 初始化只读实际登录项状态，绝不自动注册；requiresApproval 不重试注册，用户可打开系统设置后手动刷新。
- 风险/注意事项：未真实改变本机登录项；自动测试只用 fake manager，非 `.app` 测试宿主不会访问 SMAppService。
- 下一步：M4 Task 8 实现普通/TUN 内核崩溃自愈。
- 接手方式：从 M4 计划 Task 8 Step 1 开始；先实现滚动窗口 limiter 和 PID 退出 monitor 测试，主动停止/重载不能计为崩溃。
