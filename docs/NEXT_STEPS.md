# 下一步

## 当前无阻塞项

v0.1.58 已合并、已推送、已发 Release，本机已装。下面按价值排序。

## 值得做

1. **热重载优化**。现在改任何设置（规则 / DNS / TUN 参数）都会重启内核 = 掐断所有连接，
   长对话或下载会断。可区分"能通过 Clash API 热更的变更"与"必须重启内核的变更"。
   改动不小，但对日常体验提升最明显。
2. **内网 DNS 在换网时重新探测**。目前只在启动时探测一次；TUN 运行中从公司网切到家里，
   内网域名仍会被送去已不可达的内网 DNS。难点是接管期间 `scutil --dns` 只剩内核自己的
   地址，探不到东西——需要在还原 DNS 的瞬间抓一次，或改用 SystemConfiguration 的
   动态存储订阅。
3. **DoH 陈旧连接的健康探测**。0.1.47 只把**节点域名**的解析挪到了 UDP，国内网站仍走 DoH，
   仍可能撞上被 NAT 回收的连接而失败一次（表现为"个别国内站偶尔要刷一次"）。

## 需要用户参与才能推进

- **睡眠唤醒的隧道自动重建**：合盖休眠 → 唤醒，看是否自动恢复；没恢复时关掉再开也应正常。
- **经代理的出口 IP**：需换一个没有透明代理的网络（手机热点最省事）。当前家庭网络在做
  透明代理 + SNI 分流，判据见 `docs/design/tun-real-machine-debug.md`。

## 想彻底消掉「App 更新后要重装助手」

只有两条路，都需要付费 Apple Developer 账号：改用 NetworkExtension（Surge/Stash 的做法），
或用 Developer ID 签名把助手的认人方式换成签名 requirement（ClashX 的做法）。
**不要**为省这一次弹窗放宽 cdhash 校验——ad-hoc 的 identifier 谁都能伪造。
详见 `docs/design/tun-authorization-approaches.md`。

## 暂不扩张

- 不加 TUIC / WireGuard，除非真实订阅出现需求（内核已支持，缺的只是转换分支）。
- 不引入 Sparkle；private 仓库没有可安全匿名访问的更新源。
- 不为拆文件而重写 `AppState`；只随真实功能按领域拆 extension。
