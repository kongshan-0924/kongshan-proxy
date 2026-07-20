# 项目交接

- 已完成：M1–M4 代码与自动交付；M4 包含 Dashboard、日志、双 DoH、订阅自动更新、SMAppService、崩溃自愈和一键性能/残留验收。
- 修改文件：最终新增 `verify_m4.sh`、README、M4 acceptance，并更新第三方声明、计划和全部接力记录；功能代码基线为 `46fe328`。
- 测试结果：`zsh scripts/verify_m4.sh` 覆盖 137/137、release arm64、ad-hoc strict 签名、官方规则集和 M4 门禁；5 次 CPU 0.0%、平均 0.000%、最大 RSS 73,984 KB，最终标记通过。
- 当前状态：可双击产物为 `dist/kongshan.app`（约 51 MB）；主程序 SHA-256 `92bb53aa…a723`，内核 SHA-256 `813d8eff…84d`。自动验收后无进程、socket、recovery、FIFO 或临时目录残留。
- 风险/注意事项：真实订阅/节点、浏览/出口、root TUN、DNS leak、登录项批准、通知 UI、强杀 App 和 24h Instruments/Energy Impact 均待人工，不得称为原始清单全部通过。
- 下一步：按 `docs/acceptance/M4.md` 完成人工验收并追加证据。
- 接手方式：先读 `README.md` 和四份 acceptance；任何真实系统代理/TUN 操作前确认恢复路径，遇到 recovery 文件先核对进程身份，不盲删/盲杀。
