# 下一步

1. 执行 M4 Task 9：先运行缺失的 `scripts/verify_m4.sh`，记录预期失败，再实现一键完整自动验收。
2. 无节点 Release App 启动稳定后多次采样 CPU/RSS，验证 RSS <150 MB、无持续 CPU 活跃、无 WebSocket/内核/recovery/FIFO 残留，并确保脚本主动终止 App。
3. 完成 README、`docs/acceptance/M4.md` 与第三方声明，写清构建、权限、数据目录、恢复方法和限制。
4. 真实订阅/节点、系统代理、TUN、DNS leak、登录项批准、崩溃通知、24h Instruments 与 Energy Impact 必须继续标为人工验收。
