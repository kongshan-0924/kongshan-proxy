# 真机 TUN「网页打不开」深度排查交接

> 状态：**部分已修**（gvisor 修好 TCP、fakeip 修好 DNS-over-TUN，App 自己的国外请求已通），
> 但**浏览器仍打不开网页**（国内外都打不开）。已在 `fix/tun-real-machine-browsing` 分支。
> 给接手 agent：先读本文件，再按「接下要排查」动手。**不能用主机 `curl` 测连通性**——
> 除非显式走隔离的本地 socks，否则会被系统代理/其它工具污染。

## 1. 现象（当前）

- **kongshan 系统代理模式：完全正常。**（这是铁证：节点、订阅转换、代理逻辑都没问题。）
- **kongshan TUN 模式：浏览器打不开任何网页（国内 + 国外）。** 但同一时刻：
  - 仪表盘「出口 IP 检测」**成功**，显示 `69.63.217.24 / Los Angeles / DMIT`、「DNS 未发现明显泄漏」→ **App 自己（URLSession）的国外 HTTPS 请求经节点是通的**。
  - 连接页里**飞书（Feishu）的 TCP 连接有真实流量**（direct，13KB/15KB）→ 其它 App 的国内流量也通。
  - 内核内存 9.4MB、活跃连接 6、运行正常。
- **结论：kongshan 内核 + 节点 + 路由基本工作，唯独「浏览器」这个来源的流量打不开** → **强烈指向浏览器特定问题**（见 §5 关键线索）。

## 2. 用户环境（关键，非常特殊）

- macOS（Apple Silicon）、kongshan 0.1.25（build 125，含本轮修复）。
- **多默认网关（这是所有 TUN 问题的温床）**：**同时有两条 default 路由**
  - `en5`（USB 10/100/1000 LAN）：`172.16.42.111` → 网关 `172.16.42.254`（**primary**，服务序 #1，sing-box 认它为 default interface）
  - `en0`（Wi-Fi）：`172.16.15.118` → 网关 `172.16.15.254`（服务序 #4）
  - **两块网卡都能独立上网**（实测 `curl --interface en5/en0 baidu` 都 200）。
- 企业网 `172.16.0.0/12` 网段；物理 DNS `172.16.16.7`（DHCP）+ `114.114.114.114`。
- **无全局 IPv6**（en0/en5 仅 `fe80::` 链路本地）——已有 IPv6 剥离修复（`stripIPv6`）。
- 之前一直用 **Stash（mihomo 内核，系统代理 7890）** 当工作代理；排查时已彻底退出。
- 生效节点：**Dmit 洛杉矶 H2**（Hysteria2，`69.63.217.24:45724`，`tls.insecure=true`、SNI=IP、无 obfs、密码是 36 位 UUID）。**节点本身已被隔离测试证明完全可用**（curl 经它 baidu/google 均 200、出口 IP 正确）。

## 3. 已经做的修复（本轮，已提交在 main / 本分支基点 `254f91f`）

改的是 `Sources/KongshanCore/ConfigGenerator.swift`：

1. **强制 gvisor 栈**（原来 `input.tunSettings.stack.rawValue`，默认 mixed）。
   - 根因：**mixed/system 栈的 TCP 转发在这台多网关机器上失效**——TUN 下只有 UDP/ICMP 通、TCP（网页）全挂。隔离测试确认：mixed 栈 curl 全 000、日志里从没有 TCP `inbound connection` 成功；换 gvisor 后 TCP `inbound connection` 立刻成功。
2. **fakeip DNS**（`useFakeIP = input.usesTun && input.outboundMode != .direct`）：加 `{type:fakeip, inet4_range:198.18.0.0/15}` 服务器 + `{query_type:[A,AAAA] → dns-fakeip}` 规则 + `independent_cache:true`。国内域名仍走 dns-cn 拿真实 IP 直连。
   - 根因：**real-ip 模式「DNS 经 TUN 去上游解析再回来」在多网关网络超时**——`dig` TUN-DNS 超时、域名解析不了。fakeip 立刻返回假 IP、真实解析交给代理出口。
   - 仅 IPv4 段（避免与 `route_exclude_address` 的 `fc00::/7` 冲突）。系统代理模式不加 fakeip（走 socket、DNS 不经 TUN）。

**验证**：`swift test` 258 通过（+1 fakeip 门控测试 `testTunRuleModeDNSUsesFakeIPButSystemProxyDoesNot`）；生成的 TUN+rule 配置过 `sing-box check`。真机 0.1.25 确认 config.json 已是 `stack:gvisor` + `fakeip:True`、utun 172.19.0.1 起、系统 DNS 172.19.0.2 接管。

**对照 Stash（能用的那个）**：Stash 用 mihomo 内核，`cache.db` 里有 `fakeip` → **mihomo 默认 gvisor + fakeip**，这正是我们补齐的两项。

## 4. 已排查/已排除

- ✅ 节点 & 订阅转换：好的（隔离 socks 测试出口 IP 正确；HY2 密码 36 位 UUID 正确——注意 `config.json` 是**脱敏诊断快照**，password 是 `<redacted>` 占位符，别拿它去测）。
- ✅ 系统代理模式：好的（用户日常在用）。
- ✅ 多网卡：两块网卡都能上网、sing-box 绑的 en5 是通的、到节点路由走 en5 → **不是「绑错网卡」**。
- ✅ auto_route：完整（0-255 全网段拆分路由 → utun，排除私网），路由接管正常（`ping 223.5.5.5` 经 TUN 通）。
- ✅ TCP 转发：gvisor 修好后，TCP `inbound connection` 成功（隔离测试 curl baidu/google 200）。
- ✅ DNS-over-TUN：fakeip 修好后，`dig @8.8.8.8 google` 返回 `198.18.x` 假 IP，日志有 `dns: exchanged`。
- ✅ **隔离测试（fakeip+gvisor，最小配置）：curl baidu 200、curl google 200、出口 IP=节点。**（脚本 `/tmp/tuntest2.sh` + `/tmp/ktun-fix.json`，用 `networksetup` 临时把系统 DNS 指到 8.8.8.8 模拟真实接管。）
- ❌ **真机 App 0.1.25（fakeip+gvisor，完整配置）：App 自己的出口检测通了，但浏览器打不开。**

## 5. ★最关键的线索★（缩小到浏览器）

**隔离最小配置 curl 全通，但真机 App 完整配置下浏览器不通、而 App 自己/飞书通。** 两者差异：

| 维度 | 隔离测试（通） | 真机 App（浏览器不通） |
|---|---|---|
| DNS 服务器 | 明文 UDP `223.5.5.5` | **DoH**（dns-cn/dns-remote，`type:https`） |
| 路由规则 | 3 条（private→direct、google-suffix→node） | **138 条**（geoip-cn/geosite-cn/**process_name** 等） |
| 进程匹配 | 无 | **有**（日志满屏 `router: found process path`，来自分应用路由） |
| 流量来源 | curl（系统解析器 + HTTP） | 浏览器（**可能自带 DoH / QUIC**） |

**因为 App 自己的 URLSession 请求通、飞书通、只有浏览器不通**，最可能的两类根因：

- **A. 浏览器自带 Secure DNS（DoH）绕过 fakeip**：Chrome 默认开「安全 DNS」，用自己的 DoH（如 dns.google）解析 → 拿到**真实 IP**（不是 fakeip 的 198.18.x）→ 直接连真实国外 IP（QUIC/UDP 443）。这条路：① Chrome 的 DoH 连接本身可能连不上（DoH 服务器在国外、需代理，但握手时机/环回有问题）；② 拿到真实 IP 后走的是 geoip 按 IP 路由（fakeip 配置下 geoip 对真实外网 IP 仍应 → node，但**QUIC/HTTP3 + TUN + 多网关**可能有问题）。**这是头号嫌疑。**
- **B. 完整路由/DoH/进程匹配的某一项在浏览器高并发下拖垮**：`found process path` 风暴（每连接查进程）+ DoH 解析 + 138 规则，浏览器一次开几十个连接时可能超时；而 App/飞书连接少、不触发。

## 6. 接下要排查（给接手 agent，按顺序）

**第一优先——分离「浏览器」变量（最快出结论）：**
1. **换 Safari 测**（Safari 用系统解析器、不自带 DoH）。若 Safari 通、Chrome 不通 → **坐实 A（浏览器 DoH/QUIC）**，修法见 §7-A。
2. **Chrome 关「安全 DNS」**（`chrome://settings/security` → 使用安全 DNS 关闭）+ **关 QUIC**（`chrome://flags` → Experimental QUIC protocol → Disabled），重启 Chrome 测。若变通 → 坐实 A。
3. 让用户 `dscacheutil -flushcache` + 重启浏览器（排除浏览器缓存了之前坏状态）。

**第二优先——把「真机完整配置」搬进隔离测试台，二分定位（若不是浏览器问题）：**
4. 拿到 **App 真实生成的完整配置**（不是脱敏快照）。办法：在 `AppState` 写 config 的地方临时也 dump 一份**不脱敏**的到 `/tmp/kongshan-real-tun.json`（仅调试，勿提交），或用 `ConfigGenerator.generate` 在一个一次性 debug 可执行里生成。
5. 用 `/tmp/tuntest2.sh` 的方式（`networksetup` 接管系统 DNS）跑这份**完整配置**，curl baidu/google。
   - 若**完整配置也不通** → 在隔离台里二分：先删 `process_name` 相关路由规则 → 再把 DoH 换成明文 UDP DNS → 再简化 route 到最小。哪一步一改就通，哪一步就是元凶。
   - 若**完整配置通** → 问题只在浏览器（回到第一优先）或 App 运行期与裸 sing-box 的差异（系统 DNS 接管方式、进程环境）。

**第三优先——多网关/gvisor 深水区（前两项都排除后）：**
6. `auto_detect_interface` 在双 default 网关下是否稳定？试在 tun inbound 显式 `bind_interface`/`inet4_route_exclude_address` 或 `route_exclude_address` 增加另一网关网段。
7. gvisor + 9000 MTU 在浏览器大流量下是否需要降到 1500（隔离测试 mtu 9000 gvisor 是通的，但浏览器负载不同）。

## 7. 候选修复

- **A（浏览器 DoH/QUIC，最可能）**：
  - 路由层**劫持/阻断已知 DoH**：加规则把 `dns.google`/`cloudflare-dns.com`/`223.5.5.5:853` 等 DoH 端点 `hijack-dns` 或 reject，逼浏览器回退系统解析器（走 fakeip）。sing-box 有 `sniff`+`hijack-dns`，但对 DoH-over-HTTPS(443) 需按域名/IP 规则处理。
  - **阻断 QUIC 走代理外**：很多客户端对国外域名 `reject` UDP/443（QUIC），逼浏览器回退 TCP/HTTP2（fakeip 路径已验证通）。加 route 规则：`{protocol: quic / port 443 udp, 对 fakeip 段或国外, action: reject}`（mihomo 常见做法）。**这条很可能直接治好。**
  - 用户侧临时办法：Chrome 关安全 DNS + 关 QUIC。
- **B（完整配置某项）**：按 §6-5 二分结果，去掉/修正元凶（多半是 `process_name` 规则或 DoH bootstrap）。

## 8. 注意事项 / 铁律

- **别用主机 curl 直接测连通**（会走系统代理/其它工具）；要测就用隔离 socks + `curl -x socks5h://127.0.0.1:PORT` 或 `--interface`。
- `config.json` 是**脱敏诊断快照**（password=`<redacted>`、可能与运行态不完全同步）；真实密码只从 `subscriptions/*.yaml` 临时读取，严禁写入测试、文档或提交。
- 真机测 TUN 会断网，用自动恢复脚本（起→测→杀→还原 DNS，见 `/tmp/tuntest2.sh` 思路）。
- 已知 UI 小问题（非本次重点）：设置里「TUN 协议栈」下拉仍显示 mixed，但生成配置已**强制 gvisor**（该下拉现已失效，后续可从 UI 移除或改为只读说明）。
- 系统代理模式不受本问题影响、随时可用——用户日常可先用系统代理。

---

# 第二轮（0.1.26 QUIC reject）结果 + 网上搜索发现（2026-07-23）

## 9. 0.1.26 加了 QUIC reject 后的真机结果——**没修好，还有回归**

改动（commit 332890a，已在本分支）：TUN prefixRules 加 `{port_range:"443:443", network:"udp", action:"route", outbound:"reject"}`。维护者复审时修了它漏更新的一个索引断言测试（commit 后）。

真机 0.1.26 日志实测：
- **QUIC reject 确实生效**：`outbound/block[reject]: blocked packet connection to <IP>:443`。
- **但每条都跟一个错**：`ERROR connection: listen packet connection using outbound/block[reject]: operation not permitted`。这是 sing-box 在 macOS 用 `block`/`reject` **出站**拒 UDP 的已知毛病（尝试 listen packet 失败）。**应改用路由规则 action `{"action":"reject"}`（可带 `method:"drop"`），而不是路由到 block 出站 `{"outbound":"reject"}`。**
- **核心问题没解决**：日志里**全是国内 IP 走 direct、没有任何国外连接、没有 198.18.x（fakeip）**——浏览器/出口检测的国外流量**根本没进 kongshan TUN**。国内 TCP 直连正常。
- **回归**：出口 IP 检测在 0.1.25 是通的（显示 69.63.217.24），0.1.26 变「获取失败」。QUIC reject 可能把 App 自己 URLSession 的某条路径也挡了/拖慢了。

**结论**：QUIC reject 是对症的方向之一，但①实现要改 `action:reject` 去掉报错；②它不是核心根因——核心是**国外流量在真机完整配置下不通**（而隔离最小配置 fakeip+gvisor 是通的，见 §4）。

## 10. 网上搜索发现（关键参考）

- **sing-box #2643《The tun + hijack-dns + fakeip cause DNS resolve loopback》**：TUN+hijack-dns+fakeip 会 DNS 环回——**高度怀疑就是这台机器上国外域名解析不出来的原因**。
- **sing-box 1.12+ 变更（changelog）**：「**默认 DNS 服务器不能再是 fakeip**」「**所有内部 DNS 查询跳过 server type=fakeip 的规则**」。我们的 `dns.final=dns-remote`（不是 fakeip，OK），但内部查询（解析 DoH 服务器域名、节点域名）跳过 fakeip 的行为要核对是否影响。
- **sing-box #3586《Dual VPN routing issue（macOS 多默认网关/双 VPN）》**：**正是本机环境（en5+en0 双默认网关）**——macOS 下多网关 + auto_route 的路由/接口绑定是已知难题。
- **sing-box #1496**：tun+fakeip 一段时间后连接堆积不释放。
- fakeip 官方文档：1.12+ 新版写法 `{type:"fakeip", tag, inet4_range, inet6_range}` 作为 DNS server（我们用的就是这个，写法本身对）。

## 11. ★精修后的头号方向★——用「能用的 mihomo」当参照物

**Stash（mihomo，gvisor+fakeip）在这台机器上完全正常。它的有效配置就是标准答案。**

- **最高优先**：把 Stash/mihomo 的**有效运行配置**dump 出来（mihomo 的 external-controller 在 `:9090`，可 `curl http://127.0.0.1:9090/configs` 或看它的 DNS/tun 段），和 kongshan 生成的完整配置**逐字段对比 DNS + tun + route**。mihomo 能用 → 差异处就是 kongshan 的 bug。重点看：mihomo 的 fakeip 是全量还是只国外、DNS 用不用 DoH、有没有 `fake-ip-filter`、tun 的 `auto-redirect`/`endpoint-independent-nat`/`strict-route`、DNS 的 `respect-rules`/`prefer-h3`。
- **次高**：把 kongshan **真实完整配置**（不是脱敏快照，临时 dump 一份不脱敏到 /tmp 调试）搬进隔离测试台（`networksetup` 接管系统 DNS，起 sing-box→curl→杀→还原，见 §6/§8），**二分**：完整配置若不通 → ①先把 DoH（dns-cn/dns-remote type:https）换成明文 UDP（隔离测试通的那版就是明文 UDP）→ ②删 `process_name` 路由规则（`found process path` 风暴）→ ③简化 route。哪步一改就通，就是元凶。**头号嫌疑：DoH（隔离通的是明文 UDP，App 用 DoH）→ 可能触发 #2643 的 fakeip+DoH 环回。**

## 12. 修复方向（待验证后择一/组合）

1. **DNS 用明文 UDP 而非 DoH**（至少 TUN+fakeip 时）——隔离测试通的就是明文 UDP `223.5.5.5`/`8.8.8.8`；DoH+fakeip 可能环回（#2643）。改 `ConfigGenerator.dns()`。
2. **QUIC reject 改 `action:"reject"`**（去掉 `operation not permitted` 报错），或先整条回退（它没解决核心问题、还回归了出口检测）。
3. **多网关**：TUN inbound 显式处理双 default（`route_exclude_address` 加另一网关网段、或指定 `bind_interface`）——参考 #3586。
4. **对齐 mihomo 的 DNS/tun 关键项**（§11 对比结果）。

## 13. 复现/验证的铁律（再次强调）
- 别用主机 curl 直接测连通（走系统代理/其它工具）。用隔离 socks + `curl -x` 或 `--interface`。
- 真机测 TUN 会断网，用自恢复脚本（起→测→杀→还原 DNS）。
- 改配置生成后 `swift test` + 生成的 TUN 配置过 `sing-box check`。
- 用户日常用系统代理模式（正常）。分支 `fix/tun-real-machine-browsing`，别合 main，交回维护者复审。

---

# 第三轮：完整配置根因与最小修复（2026-07-23）

## 14. 根因：订阅 DIRECT 规则截获 Fake-IP

对真实完整配置逐条检查后发现：

- TUN 的 Fake-IP 地址池是 `198.18.0.0/15`。
- 当前订阅首段 IP 规则包含 `198.18.0.0/16 → DIRECT`。
- 该订阅规则位于普通业务路由中；国外域名拿到 `198.18.x` 后，会先命中 DIRECT，而不是落到最终代理出站。

这同时解释了全部观测：

- 最小 fakeip+gvisor 配置没有订阅规则，所以国内外 `curl` 均通。
- App 完整配置加入订阅规则后，一半 Fake-IP 被送往 RFC 2544 保留测试网段，国外流量不进代理。
- 系统代理模式不使用 Fake-IP，所以完全正常。
- QUIC reject 只处理传输层表象，无法修正错误出站，还引入 `operation not permitted` 和出口检测回归。

Stash 的磁盘 Core 配置不含运行时注入的 TUN/DNS；未启用 TUN 时 `/configs` 返回 `tun:null`、`dns:null`。其二进制可见默认 Fake-IP 段 `198.18.16.0/20`，说明 mihomo 会对 Fake-IP 做独立优先处理，不能把它当普通目标 CIDR 交给订阅规则。

## 15. 修复

在 TUN 且非直连模式下，紧跟 `hijack-dns` 前置：

```json
{
  "ip_cidr": ["198.18.0.0/15"],
  "action": "route",
  "outbound": "<当前主代理出站>"
}
```

顺序为：`sniff → hijack-dns → Fake-IP 主代理 → 用户/订阅/内置规则`。国内域名在 DNS 层已由 `geosite-cn → dns-cn` 返回真实 IP，不会命中该规则；只有使用 Fake-IP 的查询被固定送回代理路径。

同时整条删除 QUIC UDP/443 全局拒绝，不再保留无效补丁。

## 16. 自动化验证

- 回归测试先在旧代码失败：找不到 Fake-IP 优先规则。
- 修复后回归测试验证 `198.18.0.0/15` 的代理规则早于冲突的 `198.18.0.0/16 → DIRECT`，并确认不存在 UDP/443 全局拒绝。
- 测试生成的 HY2+TUN+冲突订阅配置通过内置 sing-box check。
- 全量 `swift test`：259 通过、1 跳过、0 失败。

仍需真机最终验收：TUN 下 Safari/Chrome 国内外网页、隔离出口 IP、关闭 TUN 后网络自动恢复。

## 17. 第四轮真机发现：旧 Fake-IP 在内核重启后失效

0.1.27 真机 TUN 已证明第 15 节的优先路由有效，但浏览器仍打不开。逐地址对照后得到更精确的证据：

- 当前内核新分配的 `198.18.0.2`：`curl --resolve` 经 TUN 进入 `inbound/tun`，还原为 `google.com`，HY2 出站成功并返回 204。
- macOS DNS 缓存中的 `www.google.com → 198.18.0.28`：立即 `connection refused`。
- Safari、Chrome 与普通系统解析仍使用 `198.18.0.28`；该地址来自上一次 sing-box 内核，当前内核没有对应的域名映射。

因此“普通浏览器连接没有进入 TUN”是失效 Fake-IP 的结果，不是 macOS 源地址选择、HY2 节点、QUIC 或当前路由表本身的问题。此前最小配置每次新起内核并立即查询，不会留下跨内核的旧浏览器缓存，所以没有暴露这一层。

## 18. 最小修复：持久化 Fake-IP 映射

按 sing-box 1.13.14 官方 `experimental.cache_file` 配置，在 TUN+非直连模式启用：

```json
{
  "cache_file": {
    "enabled": true,
    "path": "<应用支持目录>/fakeip-cache.db",
    "store_fakeip": true
  }
}
```

这使域名与 Fake-IP 的对应关系跨内核重启复用。系统代理/直连模式不生成该缓存项；诊断快照保留 `enabled/store_fakeip` 但移除绝对路径，避免泄露本机用户名。

自动化结果：定向 2 项通过；全量 `swift test` 259 通过、1 跳过、0 失败；HY2+TUN+冲突订阅配置继续通过内置 sing-box check。0.1.28 已构建并通过深度签名与 hardened runtime 校验。待真机做一次旧 DNS 清理后，必须验证两次 TUN 内核进程之间同一域名 Fake-IP 不变。

## 19. 最终根因：系统 DNS 指向了没有 TUN 本地路由的“下一跳”

0.1.28 证明 `store_fakeip` 正常创建并持久化数据库，但浏览器仍不通。继续从 DNS 数据包入口检查，得到决定性差异：

```text
route get 172.19.0.2
  gateway: 192.168.2.101
  interface: en0

route get 172.19.0.1
  interface: utun7
  flags: <UP,HOST,DONE,LOCAL>
```

应用此前从 `172.19.0.1/30` 推导系统 DNS 时把末段 `+1`，设置成 `172.19.0.2`。这个假设不适用于 macOS 的 sing-box 原生 point-to-point TUN：

- TUN 为接口自身 `172.19.0.1` 建立本地 host route。
- `172.19.0.2` 没有对应本地路由，且命中 TUN 的 `route_exclude_address: 172.16.0.0/12`。
- 因此 DNS 流量从物理 `en0` 发往默认网关。企业网下表现为解析超时；当前家庭网关会劫持 DNS 并返回它自己的 `198.18.x` Fake-IP，造成更隐蔽的跨内核映射错配。

现场对照：

```text
dig @172.19.0.2 fresh.example A  -> 198.18.x（物理网关生成）
dig @172.19.0.1 fresh.example A  -> 240.0.0.2（kongshan 生成）
```

后者同时在 sing-box 日志出现 `inbound/tun ... to 172.19.0.1:53`。因此此前关于 DoH、QUIC、浏览器 Secure DNS、单纯持久化和“macOS 拒绝 198.18/15”的判断都不是最终根因；它们是 DNS 根本没有进入 kongshan 后产生的次生现象或保护性改进。

最小代码修复在 `TunSettings.dnsServerAddress`：返回第一个有效 IPv4 接口地址本身，不再计算下一跳。默认值由 `172.19.0.2` 改为 `172.19.0.1`。

## 20. 0.1.30 两轮真机终验

保留并组合此前已经有价值的修复：

- gvisor TUN 栈；
- TUN Fake-IP 业务规则优先于订阅规则；
- 删除无效且报 `operation not permitted` 的 QUIC block 出站；
- `cache_file.store_fakeip`；
- Fake-IP 段改为 `240.0.0.0/4`，缓存文件使用 `fakeip-cache-v2.db`，避免继续使用物理网关和旧缓存的 `198.18.x`。

自动验证：

- `SystemDNSManagerTests.testTunSettingsDeriveDNSServerAddressInsideTunSubnet` 通过；
- 全量 `swift test`：259 通过、1 跳过、0 失败；
- TUN 回归测试生成的配置通过 sing-box 1.13.14 check；
- 0.1.30/build 130 通过 `codesign --verify --deep --strict`，带 hardened runtime。

真机两轮：

| 项目 | 第一轮 | 第二轮 |
| --- | --- | --- |
| sing-box PID | 36946 | 37470 |
| 系统 DNS | 172.19.0.1 | 172.19.0.1 |
| Google Fake-IP | 240.0.0.4 | 240.0.0.4 |
| Google / 百度 / GitHub | 204 / 200 / 200 | 204 / 200 / 200 |
| 出口 IP | 69.63.217.24 | 69.63.217.24 |
| Chrome | Google、百度正常 | Google、百度正常 |
| Safari | Google、百度正常 | Google、百度正常 |

隔离命令绑定 TUN 源地址 `172.19.0.1`，避免系统代理污染；不能绑定 `en0` 后再用 Fake-IP 判断 TUN，因为绑定物理网卡会主动绕开 TUN。日志确认 Google/GitHub 的 `240.x` 被还原成域名并经当前 HY2 节点出站，百度真实 IP 走 direct。

0.1.30 已安装到 `/Applications/kongshan.app`，TUN 保持开启供用户验收。当前网络是单默认网关；代码根因能解释企业网现象，但回原企业多默认网关后仍建议做一次最终复验。分支继续保留 `fix/tun-real-machine-browsing`，不合 main。

## 判据：所在网络是否有"透明代理"（会让任何代理客户端的节点连不上）

排查节点连不通时，先排除环境。满足任一条即可判定当前网络在本地终结/改写出境连接，
**此环境下无法验证任何代理客户端的节点连通性**，继续调 App 是浪费时间：

1. **TCP 握手 RTT 远低于物理下限**：到美国 IP 若只有 3~5ms（正常 150ms+），
   说明连接被本地设备终结。用 `python3 -c "import socket,time;..."` 测三次取最小值。
2. **任意 SNI 都能拿到匹配的证书**：
   `openssl s_client -connect <节点IP>:443 -servername example.com`
   若返回 `CN=example.com`，说明有设备在按 SNI 把你转发到真实目标——
   真 Reality 服务器对未认证握手只会回退到它配置的 dest，证书永远是那个 dest 的。
3. **国内/国外 IP 查询给出不同出口**：`myip.ipip.net` 与 `api.ipify.org` 结果不一致，
   说明路由器在做分流代理。

典型症状：VLESS/Reality 报 `reality verification failed`（ClientHello 没到节点），
Hysteria2 报 `timeout: no recent network activity`（QUIC/UDP 被透明代理破坏）。

解法：把节点服务器 IP 加进路由器代理的**直连/绕过**列表，或换一个没有透明代理的网络
（手机热点最省事）再验。
