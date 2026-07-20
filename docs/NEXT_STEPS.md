# 下一步

1. 执行 M4 Task 8：先写 10 秒滚动窗口、主动停止不重启、system/TUN 重启和第 4 次终止通知测试。
2. 用 `DispatchSourceProcess(.exit)` 监听精确 PID；主动 stop、模式切换、规则/DNS reload 前先取消 monitor。
3. system 崩溃重启不得重复写系统代理；TUN 自动测试只用 fake launcher/monitor，真实重启仍会明确请求管理员授权。
4. 真实节点 Dashboard/日志、管理员授权/TUN 与 DNS 泄漏验收继续按 acceptance 人工边界保留。
