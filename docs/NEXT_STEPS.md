# 下一步

1. 执行 M4 Task 5：先写 `KernelLogStore` 有界内存、日志轮转、导出合并与敏感值隔离测试。
2. 普通 sing-box stdout/stderr 仅追加到既定日志文件，转写失败只记 warning，不影响代理生命周期。
3. 新增实时日志页：可见时订阅 `/logs`，等级切换取消旧流，离开页面立即断开，内存最多 2000 行。
4. 真实节点 Dashboard、管理员授权/TUN 与 DNS 泄漏验收继续按 acceptance 人工边界保留。
