# 项目交接

- 已完成：需求已固化，应用身份确定为 `kongshan / com.kaysen.kongshan`，设计稿已获确认；实时核验 sing-box stable 为 1.13.14。
- 修改文件：新增 `ProxyMode.swift`、`TunConfigTests.swift` 并扩展 `ConfigGenerator`，支持 mixed/tun 互斥 inbound、strict_route、CIDR 排除和回环保护。
- 测试结果：TunConfig 定向 5/5、全量 `swift test` 64/64 通过；strict 关/开两份含本地 `.srs` 的 TUN 配置均通过内置 sing-box 1.13.14 `check`。
- 当前状态：M3 Task 1 已完成，准备执行 Task 2 安全提权命令与内存 FIFO。
- 风险/注意事项：域名无法写入 IP route exclude，仍由 route direct 保证；真实 TUN 未启动，自动测试禁止授权。
- 下一步：按 TDD 实现只允许固定 start/stop 的 AppleScript 构造器和 POSIX FIFO transport。
- 接手方式：先读本文件、设计稿、M1 计划与会话日志，再从首个未勾选步骤继续。
