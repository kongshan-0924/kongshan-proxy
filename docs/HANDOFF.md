# 项目交接

- 已完成：M3 全部 7 个 Task；实现 TUN 配置、固定提权命令面、0600 FIFO、PID/recovery、自愈、system/TUN 互斥状态机、在线路由/strict 回滚和原生模式界面，并完成自动验收。
- 修改文件：M3 产品与测试文件、`scripts/verify_m3.sh`、`docs/acceptance/M3.md`、M3 计划及全部项目记录；功能基线提交为 `ba36fc6`。
- 测试结果：`zsh scripts/verify_m3.sh` 最终输出 `M3 automated verification passed`；88/88 测试通过，strict 关/开 TUN fixture、三个官方规则集、release arm64、plist 与 ad-hoc codesign 严格验证全部通过。
- 当前状态：M3 自动交付完成；产物为 `dist/kongshan.app`（约 51 MB），本轮未触发管理员授权、未启动真实 TUN，也未留下 TUN recovery/FIFO 文件。
- 风险/注意事项：真实授权弹窗、utun、出口 IP、域名直连、关闭恢复、strict 对 LAN/虚拟化影响及强杀自愈仍待人工；macOS DNS 防泄漏属于 M4，当前不可宣称通过。
- 下一步：按原始需求编写并执行 M4 打磨计划；或由用户在可接受网络中断时按 `docs/acceptance/M3.md` 做真实 TUN 人工验收。
- 接手方式：先读本文件、三份阶段验收、原始需求与最新 SESSION_LOG；继续 M4 时先核对范围并写计划，人工 TUN 前先确认恢复路径。
