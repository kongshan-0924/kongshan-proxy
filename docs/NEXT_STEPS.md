# 下一步

1. 执行 M4 Task 7：先写 `SMAppService.mainApp` 状态映射、用户开关、拒绝/待批准和初始化不自动注册测试。
2. `AppState.initialize()` 只读取实际登录项状态；仅设置页用户主动操作才能调用 register/unregister。
3. `requiresApproval` 显示可读状态并提供打开系统“登录项”设置入口，不重复尝试注册。
4. 真实节点 Dashboard/日志、管理员授权/TUN 与 DNS 泄漏验收继续按 acceptance 人工边界保留。
