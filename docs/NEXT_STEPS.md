# 下一步

1. 执行 M4 Task 4：先写 Dashboard 60 点有界缓冲、可见时启动、离开时取消和流错误 warning 测试。
2. AppState 只在代理已开启且 Dashboard 可见时消费 traffic/connections 两条流，并在 stop/reload 时取消。
3. 抽出 `DashboardView.swift`，使用 Swift Charts 展示最近 60 秒上下行曲线和连接/内存/版本/运行时长。
4. 真实管理员授权/TUN 与 DNS 泄漏验收继续按 acceptance 人工边界保留。
