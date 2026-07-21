# 下一步

## 优先真机验证本轮

1. **TUN**：点 TUN → 输密码 → 应成功接管（`bad tun name` 已修）。`curl ifconfig.me` 应为代理出口；`ifconfig | grep utun` 能看到新 utun 口。若仍失败，看 `~/Library/Application Support/kongshan/logs/sing-box-tun.log` 的 FATAL 行。
2. **测速**：设置-网络默认 TCP 握手，节点页/代理页「测速全部」应快速出延迟（不需要先开代理）。慢/不准可切 URL 测速对比。
3. **配置切换**：配置页两个配置单选切换，代理页策略、规则页规则、可选节点应整套替换；生效配置的节点才参与生成。
4. **代理页**：左列策略来自当前配置；给不同策略选不同节点/子组，开代理后验证分流按策略走。
5. **设置-隧道**：绕过域名/IP/跳过TUN 三个列表可增删，点「应用绕过设置」后校验生效于三处。

## M4 真实网络人工验收（仍未完成）
- 浏览器经系统代理访问 Google、DNS leak 粗验、绕过命中、强杀自愈、24h Instruments。

## 可选（非阻塞，按价值）
- Clash 的 GEOSITE/GEOIP/RULE-SET 规则转换成 sing-box rule-set（目前只转 DOMAIN*/IP-CIDR/PROCESS，其余靠内置兜底；规则页因此只列可解析规则）。
- 订阅级自定义 UA、拉取失败降级 `clash` UA 重试、base64/JSON 订阅格式回退。
- `profile-update-interval` 头按订阅覆盖更新间隔；HEAD 轻量刷新配额。
- 一次安装特权 helper（SMAppService daemon + XPC）替代每次 TUN 提权弹窗。
- 托盘实时速率、外部访问（固定端口/LAN/API key）——都要破当初红线，需你拍板。
- 自建节点的逐个删除入口（当前本地配置只能整体删除）。

## 已完成（本分支）
- 手动选择不再显示 UUID；托盘菜单宽度优化。
