# 下一步

1. 执行 M4 Task 3：先为 `/traffic`、`/connections`、`/logs` 的 URL、Bearer、payload、坏消息和取消清理写失败测试。
2. 实现可注入的 URLSessionWebSocketTask → AsyncThrowingStream 桥接，不做 Timer/REST 轮询或无限自动重连。
3. Clash REST 增加 version 返回值并保持现有 health/选择/测速 API 兼容。
4. 真实管理员授权/TUN 与 DNS 泄漏验收继续按 acceptance 人工边界保留。
