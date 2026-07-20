# 项目交接

- 已完成：M4 Task 1；加入可校验 DNSSettings、默认/自定义双 DoH、CN DNS rule-set、无环 bootstrap、route default resolver，以及仅 TUN 的 sniff/DNS hijack。
- 修改文件：`Sources/KongshanCore/DNSSettings.swift`、`ConfigGenerator.swift`、`Tests/KongshanCoreTests/DNSConfigTests.swift`、M4 计划及全部记录。
- 测试结果：首个 RED 为 DNS API 缺失；运行期 RED 捕获显式 direct detour 被 1.13.14 拒绝；修复后 DNS 6/6、全量 94/94、`swift build` 与 `git diff --check` 通过。
- 当前状态：Task 1 完成；system/TUN、默认/域名自定义 DoH 四份配置 check 通过，另有真实启动并访问 Clash `/version` 的运行期测试。
- 风险/注意事项：新格式 domestic DoH 省略 detour 才表示直连，不能显式 detour 到空 direct outbound；system 模式仍不代表操作系统全局 DNS 被接管。
- 下一步：M4 Task 2 持久化 DNS，接入 system/TUN 在线事务与高级设置 UI。
- 接手方式：从 M4 计划 Task 2 Step 1 写 AppState RED；每条生成路径都必须传当前 `dnsSettings`，失败必须保留旧设置。
