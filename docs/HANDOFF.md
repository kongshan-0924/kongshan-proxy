# 项目交接

- 已完成：需求已固化，应用身份确定为 `kongshan / com.kaysen.kongshan`，设计稿已获确认；实时核验 sing-box stable 为 1.13.14。
- 修改文件：扩展 `SingBoxProcess.restart` 与 `AppState`，新增规则加载/持久化、规则集启动链、原运行时快速重启和内核/bypass 双重回滚；新增 6 个 AppState 场景及 restart 测试。
- 测试结果：AppState 定向 7/7、全量 `swift test` 59/59 通过；真实 sing-box/Clash API 快速重启实测 0.270651417 秒，mixed/clash port 与 secret 复用，系统代理只启用一次。
- 当前状态：M2 Task 5 已完成，准备执行 Task 6 原生规则编辑器与 bypass 界面。
- 风险/注意事项：自动测试的 sing-box/Clash API 为真实内核，但 system proxy 仍是命令记录器；真实节点与真实网络切换尚未验收。
- 下一步：实现“规则”侧栏、自定义规则编辑/拖拽、两类 bypass、恢复默认和广告开关，全部提交到同一 AppState 事务。
- 接手方式：先读本文件、设计稿、M1 计划与会话日志，再从首个未勾选步骤继续。
