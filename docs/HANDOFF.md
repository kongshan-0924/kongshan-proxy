# 项目交接

- 已完成：M4 Task 5；实现普通/TUN 有界磁盘日志、2000 行实时缓冲、日志页、等级切换与已知文件安全导出。
- 修改文件：新增 `KernelLogStore.swift`、`LogsView.swift`、`KernelLogStoreTests.swift`；修改 SingBoxProcess、PrivilegedLauncher、AppState、MainWindowView 与相关测试/记录。
- 测试结果：多轮 RED 证明 store/process/AppState API 缺失；GREEN 为全量 119/119，debug/release、arm64、codesign strict、diff check 与无节点启动通过。
- 当前状态：实时 `/logs` 仅页面可见+代理开启时存在；普通日志 actor 串行写，TUN 日志授权前以 0600 预创建并用写事件触发轮转，不使用 Timer/轮询。
- 风险/注意事项：未用真实节点或真实 root TUN 验证日志页/导出；自动测试全部使用 fake 边界，没有请求管理员权限。
- 下一步：M4 Task 6 实现订阅定时更新与非阻塞本地通知。
- 接手方式：从 M4 计划 Task 6 Step 1 开始；用可注入 clock/sleeper 证明只安排一次 sleep，通知只用 fake sender。
