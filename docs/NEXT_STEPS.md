# 下一步

1. 执行 M4 Task 2：先写旧 settings DNS 兼容、离线保存、system/TUN 在线应用与失败回滚测试。
2. 将 DNS 参数接入 AppState 全部配置生成路径，避免 start/routing/TUN 更新遗漏或回退默认值。
3. 增加 DNS 高级设置原生 UI，明确 system 模式不等于全局 DNS 接管且默认不使用 fake-ip。
4. 真实管理员授权/TUN 与 M1/M2 网络验收继续按三份 acceptance 文档保留。
