# 项目交接

## 当前状态：v0.1.82 源码完成（DNS 引导 + 旧 Release 清理 + 阈值验证）（2026-08-23）

未结事项一/二/三均已落地：

- **① DNS 上游共享（用户裁决）**：新增可配置的引导解析器字段，隐私意图与抗抖动都保留。
  `DNSSettings.bootstrapResolver` 留空 = 跟随国内 DoH 的 IP；填入 IPv4/IPv6 =
  与国内 DoH 解耦。旧 settings.json 缺字段兼容解码；设置 → DNS 高级设置新增输入项。
  已提交 `60ac192`，全量 493/2 跳过/0 失败，release 构建通过。
- **② 旧 Release 清理（用户确认）**：v0.1.80/79/77/73 的 Release 与标签已删除，
  远端只保留 v0.1.81（Latest）与基线标签。
- **③ 节点失败率阈值**：用真实内核日志离线回放验证，首版阈值（600s、≥20 尝试、
  ≥5 失败、≥10%）不误报不漏报，无需回调；保留真实使用观察项。
- **边界**：本地 `main` 领先 `origin/main` 2 个提交（`60ac192` 功能 + `377d40a` 文档），
  未推送、未构建 DMG、未安装；走既有 `release.sh prepare|install|publish` 门禁。
- 详情见 `docs/progress/SESSION_LOG.md` 2026-08-23 17:00/17:20/17:40 条。

## 历史状态：v0.1.81 已发布并安装（2026-08-23）

v0.1.80 连续运行 2 天验证通过：**生命周期平均 CPU 0.64%**（燃烧修复前为 18.2% / 40.5%），
2 天仅 1 条自诊断告警且为内核重启期间的 93 秒短爆发；端口 3 分钟零增长，证实 mach port
修复有效；DNS 超时从 41 次/5 小时降到 2 次/24 小时；0 崩溃。

v0.1.81 修掉两处**可观测性**缺口：

- **失败事件此前不记原因**：13 处 error/warning 事件只记「失败了」，而错误对象就在作用域内
  （只进了 `errorMessage` 这个一闪而过的横幅）。真机后果是 08-21 两条「配置应用失败，已回滚」
  两天后无法归因。现已全部补齐，`stop()` 也带上触发方，并有源码守卫防退化。
- **节点故障无处可见**：当时选中的主节点建连失败率 5.8%（8,198 次尝试失败 476 次，
  单小时最高 251 次），用户只能靠翻内核日志发现。新增 `OutboundFailureDetector`，
  超阈值时在消息页给出节点名、失败比例与主要原因。两个误报坑（规则拒绝、重载取消）
  均已排除并有回归。

另新增消息页「只看问题」筛选；内核停止时清空两个检测器的窗口。

## 历史状态：v0.1.80 资源纪律修复（2026-08-21）

深度资源排查（`leaks`、端口、FD、线程、逐模块释放路径复核）发现两处真问题并修复：

- **自诊断采样器泄漏 mach port 引用**（v0.1.78 引入）：`task_threads` 的线程 send right
  未逐一归还。短期端口表不涨（right 合并只涨 urefs），约 11 天后溢出使线程数指标静默
  失效，线程池短命线程还会留死名字。已修复，回归测试带反向验证（去掉修复精确失败）。
- **删除订阅不删缓存 YAML**（历史缺陷）：真机积累 5 个孤儿共 27.2 MB，且缓存含节点
  凭据。已修复删除路径并加启动孤儿清理（只动 UUID.yaml 形态、大小写不敏感、记运行事件）。

其余全部健康：堆泄漏仅 14.4 KB（系统框架、恒为 3 处不累积）；v0.1.79 装后零 CPU 告警，
平均 0.46%、RSS 64 MB；KernelLogStore/ClashAPIClient/LocalTCPRelay 释放路径逐一复核通过。

v0.1.80 已发布 GitHub（Latest）并安装；孤儿清理首启端到端验证通过（28 MB → 932 KB）。
本机已收敛到一版：单实例、单副本、`dist` 只留最新、配置备份 3 份，用户数据 54 MB → 12 MB。

**远端仍有 v0.1.73 / v0.1.77 / v0.1.79 三个旧 Release**：本轮有意保留。v0.1.79/v0.1.80
在本机仅运行约 1.5 小时，而 CPU 燃烧问题需数小时才显形，确认窗口未到；删除 Release
不可逆，等真实使用确认后再按「只保留最新」清理（v0.1.77 已知有缺陷且未过门禁，优先清）。

CHANGELOG 断档已补（0.1.74~0.1.80）。

## 历史状态：v0.1.79 已发布并安装，修复 CPU 燃烧根因（2026-08-20）

自诊断上线两天后捕获了完整证据并定位根因，v0.1.79 已修复：

- **根因**：`MenuBarController` 缓存的 popover `NSHostingController` 永不释放，持续观察
  `@Observable` AppState；叠加 Dashboard/Popover 四处把 `.contentTransition(.numericText())
  + .animation(.smooth)` 挂在每 1~2 秒变化的速率/连接数/内存上——弹簧动画在下一次采样
  到来时仍未收敛，SwiftUI 按屏幕刷新率持续插值字形。真机代价：一段爆发平均 57.4%、
  峰值 103.5%，连烧 8.25 小时、17,051 CPU 秒（4.7 核·小时）、峰值内存 602 MB。
- **证据链**：自诊断事件「主线程 99% + user 97% + 窗口可见 否」+ 现场 `sample` 栈
  （`stepIdle → CA::Transaction::commit → CGDrawingLayer.draw → RB::DisplayList` 字形绘制、
  `RBInterpolatedDisplayListContents` 动画插值、`NSHostingView` 反复布局）。
  版本相关性：popover 是 v0.1.74（未过门禁的四轮界面改动之首）引入的，v0.1.73 没有。
- **修复**：popover 关闭即释放（含快速重开与 show 未成功两个边界）；摘掉四处高频值动画；
  另有源码守卫禁止这两个文件再挂 `.animation(`/`.contentTransition(`/`TimelineView`。
- **额外优化**：CPU 中途报告指数退避（10 分钟固定节律在 8 小时爆发中产出 182 条告警
  占满 200 条事件环，退避后同时长只产出 5~6 条）；诊断详情改读 `activeConnectionCount`
  （原读连接页明细列表，页面不开恒为 0，丢归因线索）。
- **两处上轮结论更正**已记入 SESSION_LOG：runtime-events 时间戳是 UTC（上轮当本地时间
  读，差 8 小时，「与代理开关无关」撤回）；`ps -M` 在本进程上枚举不全线程（「排除
  SwiftUI」撤回，进程内 `thread_info` 的读数才可信）。

## 历史状态：v0.1.78 已安装运行，含运行期自诊断（2026-08-18）

- **安装与线上均为 v0.1.77/build 177**，GitHub Release 发布于 `2026-08-14T16:50:18Z`，
  唯一资产 `kongshan-0.1.77.dmg`。此前 `HANDOFF`/`PROGRESS`/`NEXT_STEPS` 三份文档都停在
  v0.1.73 且写着“尚未安装到本机”，与实际相差四个版本，本轮已补齐（补记依据见 SESSION_LOG）。
- v0.1.74–0.1.77 是四次纯界面轮次（菜单栏迷你仪表盘 popover、紧凑密度、自适应布局、
  规则页可折叠）。四次都只走了 trial build，**没有走 `release.sh prepare` 的提交绑定门禁，
  也没有 M4 验收与真机走查记录**。这是当前最大的一处流程欠账。
- 本轮只读诊断结论：运行 3 天 13 小时，近 7 天 0 崩溃，CLOSE_WAIT 为 0、无 FD 泄漏，
  relay 架构工作正常（公开 `36815`、内核内部 `21338`），空闲 CPU 1.66% 与 v0.1.72 基线一致。
- **三个未结事项**见下面三节：DNS 上游共享（待用户裁决）、CPU 异常（已缩小到后台线程、
  当天复发过一次）、v0.1.77 从未走过 M4 门禁（因此保留 v0.1.73 作为回滚点）。
- 本轮新增运行期自诊断并升版到 **v0.1.78**：全量 468 执行 / 1 跳过 / 0 失败，M4 门禁通过
  （平均 CPU 0.820%、最大 RSS 109,120 KB），`release.sh prepare` 已生成提交绑定的候选。
  **已安装并打开 v0.1.78/build 178**，单实例、0.47% CPU、RSS 85 MB，三类系统代理保持关闭、
  直连 200；旧版可恢复备份在废纸篓。配置备份 SHA-256
  `cb4fe83127e58787a8428a73c19e13f730d56dd9533e511d736e3528147b1e00`。
  **`publish` 尚未执行**（被环境权限分类器拦截，未绕过），验证戳已绑定提交，
  可直接运行 `scripts/release.sh publish`。App cdhash 已变，助手会提示需重装一次。
- v0.1.78 同时把 v0.1.74–0.1.77 四个未过门禁的界面提交一并纳入了完整验收。

### 未结一：dns-bootstrap 与 dns-cn 共享同一台上游（待用户裁决）

生成的配置里两者都指向 `223.5.5.5`，只是传输不同（UDP 53 / DoH 443）。一台上游抖动会同时
打掉「节点自身域名解析」与「国内域名解析」，前者会让整条代理停摆。2026-08-18 当天 41 次
10 秒超时中 7 次属前者，07:04~07:33 劣化约半小时后靠内核重启恢复。

已用 bundled 内核逐字段验证：**sing-box 1.13 无法表达 DNS 故障转移**——`dns.servers[].server`
只接受单个字符串，`dns.rules[].server` 同样不接受数组，`timeout` 与 `fallback` 都是
unknown field。因此只能在选址上解耦。

**但解耦与一个刻意的设计决定冲突**（`Tests/KongshanCoreTests/DNSConfigTests.swift:72`）：
引导地址跟随用户配置的国内 DoH，是为了避免用户换掉阿里之后，节点域名仍被送去阿里。
解耦会重新引入该泄漏。这是隐私意图与抗抖动之间的取舍，**已回滚改动，等用户决定**；
第三条路是新增一个可配置的引导解析器字段，代价是多一处设置项与 UI。

### 未结二：CPU 异常当天复发，已缩小到后台线程但未定位

`ps` 累计 929 分钟 CPU / 85 小时 = 平均 18.2%，但当场实测三项都解释不了：空闲 1.66%、
仪表盘可见 3.89%（峰值 11.4%，门禁内）、relay 转发 0.013 s/MB（烧掉 929 分钟需约 3.7 TB）。
线程级 USER 846 分钟对 SYSTEM 52 分钟（约 16:1）指向纯计算而非转发 I/O；并已实测确认
`ps TIME` 不含已回收子进程，所以这确是 App 自身消耗。

**同一轮内又复发一次**：13:47→23:10 的 9 小时 23 分里消耗 8,430 秒 CPU，扣掉 `pmset`
记录的睡眠后清醒期平均约 **29%**，而代理从 14:35 起就是关闭的 ⇒ **与代理开关无关**。

已排除的两项（当场实测，不是推断）：

- **不是窗口可见导致的空转**：窗口关闭 0.53%、窗口打开 0.67%，都正常。
- **不是 SwiftUI/主线程**：进程累计 1070 分钟，**主线程只有约 8.5 秒**，现存 13 条线程合计
  98.5 秒 ⇒ 烧 CPU 的是已被回收的后台并发/派发工作线程。这条把历史上一直怀疑的
  「仪表盘/图表渲染」正式排除。

当前画像：**后台并发线程上的突发重计算**（user:system ≈ 16:1），小时级持续但采样时已结束。
**没有写推测结论。** 本轮改为增加留证能力：见下。

### 本轮改动：运行期自诊断

- `ProcessResourceSampler`：`getrusage(RUSAGE_SELF)` 取 user/system CPU（**必须分开保留**，
  这是排除 relay 嫌疑的第一判据）、mach `MACH_TASK_BASIC_INFO` 取当前 RSS、`task_threads`
  取线程数并显式释放。
- `CPUAnomalyDetector`：把连续采样折叠成异常时段，输出平均/峰值/user 占比/消耗秒数/
  峰值 RSS 与线程数。**带 `.ongoing` 中途相位**——只在结束时报告的检测器，遇到一直烧到
  用户退出的异常会一条都不产出，这正是这次无法归因的原因。
- `DNSStallDetector`：按时间窗聚合解析超时；用与协议措辞无关的结构判据（被 lookup 的名字
  是否等于连接目标）区分节点自身域名与普通目标；带上窗口内物理网卡字节增量，作为
  「解析器故障」与「整机断网」的区分依据。
- 接线在 `AppState`：15 秒采样、**全程运行不跟随代理开关**、退出前落盘仍开着的异常段。
- `mainThreadSeconds` / `mainThreadShare`：用 `thread_info(mach_thread_self())` 采主线程 CPU
  并写进事件详情。这正是本轮排除 SwiftUI 的那条判据；没有它，下次仍只能靠人工 `ps -M` 比对。
- 脱敏：**不记录任何被解析的域名**，只记数量与路径分布；有 Mirror 递归的隐私守卫测试。

### 未结三：v0.1.77 从未走过 M4 门禁

v0.1.74–0.1.77 都是 trial build。**v0.1.73 是最后一个走完完整提交绑定门禁的版本**
（450 项、M4 平均 CPU 0.080%、最大 RSS 118,048 KB），而 CPU 异常正是在 v0.1.77 上观测到的
——异常有可能就是那四个未门禁的界面提交引入的。

因此本轮**没有**按惯例删除 v0.1.73 的 Release 与标签：在异常定位前，它是唯一经过验收的
回滚点与对照组。等异常定位、v0.1.77 或后继版本补跑门禁后再清理。


## 当前状态：v0.1.73 已发布 GitHub（2026-08-14）

- SSH 指定目标走代理已随 **v0.1.73** 发布：提交 `70c21c9`（功能）、`88c0517`（测试修复）、
  `9ac0e79`（版本）。没有复用 v0.1.72 版本号——v0.1.72 已先行发布到 GitHub，同一版本号下
  替换已发布二进制会破坏校验，故升级为 v0.1.73。
- 发布前审计中发现并修复两个既有测试的负载相关偶发：
  `testDashboardMonitoringKeepsSixtyPointsAndIsIdempotent` 只等 60 点不等流尾，
  断言与缓冲样本消费赛跑（xctest 单独重跑稳定复现），已改为等到最后一个样本；
  `testTUNRestartsThreeTimesThenFourthCrashCleansUpAndNotifies` 依赖 10 秒限流窗口的
  wall-clock，高负载下偶发超时，空闲复跑通过，未改动。
- 发布结果：XCTest 450 项执行、1 跳过、0 失败；M4 平均 CPU 0.080%、最大 RSS 118,048 KB。
  DMG SHA-256 `650db2d17c4d234be6d5017a600ff526c5487c202cddb4695466bdb709ade7fc`，
  与 GitHub Release 资产 digest 一致；App CDHash `94b469bfe4723c26d93534e55a8e3fd268b8ab5f`。
  远端只剩 v0.1.73 一个 Release（v0.1.72 Release 与标签已按惯例清理），`dist` 只有最新 DMG。
- 当前边界：**未安装** v0.1.73 到 `/Applications`，未修改真实 `~/.ssh/config`；
  当前安装版仍是 v0.1.72/build 172。安装走 `scripts/release.sh install`（正常退出旧版、
  确认网络恢复、备份配置、原子替换）。App 更新后 cdhash 变化，TUN 助手会提示重装一次。

## 历史：指定 IP + SSH 端口走代理已完成源码与回归（2026-08-13）

- 规则页新增“SSH 走代理”，按精确 `IP + TCP 端口` 保存；支持 IPv4/IPv6、同 IP 多端口，拒绝 CIDR、
  回环地址和非法端口。`118.69.52.186:22235` 可配置，端口 22 等同 IP 其他连接不受影响。
- OpenSSH 通过 `ProxyCommand` 连接空山稳定 SOCKS5 relay。只管理 `~/.ssh/config` 顶部带标记的
  `Include ~/.ssh/kongshan-proxy.conf` 和独立托管文件，不读取用户名、密码、私钥或用户现有 Host 块。
- 托管文件原子写入且权限为 0600，`.ssh` 为 0700；不完整标记、`.ssh/config`、托管文件或父目录为
  符号链接时 fail-closed。删除最后一条规则会移除 Include 与托管文件。
- 规则离线时只持久化，不留下指向空 relay 的 ProxyCommand；代理健康启动后自动挂接，停止、退出、
  启动失败或崩溃终止时撤下。TUN 停止失败会恢复仍可用的 SSH 配置。
- 系统代理、纯 TUN、系统代理+TUN均支持；sing-box 生成 `IP + port + tcp` 的优先规则，直连模式下
  该 SSH 目标仍走当前代理出站，同时不会改变相同 IP 其他 TUN 流量的 route exclusion 语义。
- 修复了审计中发现的 TUN 回滚所有权错误：SSH 配置写入失败等后置失败在 TUN 模式下由 helper
  回滚旧特权内核，不会再错误启动第二个用户态 sing-box。系统代理路径继续使用普通进程回滚。
- 新鲜验证：定向回归 14/14；最终 XCTest 449 项执行、1 项按预期跳过、0 失败；`swift build` 与
  `git diff --check` 通过。临时 OpenSSH `ssh -G` 验证 22235 命中 ProxyCommand、22 不命中。
- 已随 v0.1.73 提交、构建 DMG 并发布；未安装到本机、未修改真实 `~/.ssh/config`。

## 当前状态：v0.1.72 已安装并完成稳定端口真机验收（2026-08-09）

- v0.1.71 把监听端口移出 macOS 临时端口池，只降低了普通源端口抢占概率，并未解决真机切换故障。
  独立 socket 复现确认 `CLOSE_WAIT`、`FIN_WAIT_2`、`TIME_WAIT` 都不会阻塞同端口立即重绑；真正的
  阻塞来自仍被活跃 FD 持有的 `BOUND/CLOSED` PCB。XNU 对具体 `127.0.0.1` 地址还会在检查
  `SO_REUSEPORT` 前拒绝不同 UID 绑定，所以 root TUN 内核与普通用户内核不能可靠交接同一端口。
- v0.1.72 改为 App 常驻的用户态 TCP relay 持有稳定公开端口，系统 HTTP/HTTPS/SOCKS 始终指向它；
  root/user sing-box 每代使用随机内部 mixed 端口，模式切换只原子更换 relay 后端。relay 只监听回环、
  只转发原始 TCP 字节，支持双向背压和 half-close，不解析协议，也不启用 `SO_REUSEPORT`。
- 持久化新增 `proxyRelayPort`；旧 `mixedPort` 只用于兼容解码且不再写入。公开端口与内部端口隔离、后端
  切换、空目标、并发竞态、端口释放和 AppState 系统代理参数均有自动回归覆盖。
- 新鲜 XCTest：435 项执行、1 项按预期跳过、0 失败。最终候选 M4：五次 CPU 0.4/0.0/0.4/0.0/0.4%，
  平均 0.240%，最大 RSS 115,712 KB；v0.1.72/build 172、arm64、deep+strict、sing-box 1.13.14、
  候选启动与无 socket/子进程/FIFO/recovery 残留均通过。
- 当前安装版为 v0.1.72/build 172，App CDHash
  `e7b01bddd3b54b76d41900367165f6db637dc090`。旧 v0.1.71 仅正常 Quit；恢复门禁、配置备份和原子安装
  均完成，未强杀。备份归档 SHA-256 为
  `c2d9c2098c8671aacde3f8b80a3a28af91b4736054a675b264735491df8d1d13`，配置白名单哈希逐项不变。
- 真机矩阵已覆盖系统代理、系统代理+TUN、仅 TUN及多轮往返：系统公开端口全程固定为 `36815`，由
  App 监听；root/user sing-box 内部 mixed 分别随机变化。TUN 关闭后 root core 消失、DNS 恢复
  `192.168.2.1`，HTTP/SOCKS5/直连均返回 200，未出现端口漂移警告。
- helper 已重新授权并显示“已安装”。最终状态已恢复“奶昔”配置、`Japan 03` 节点和仅系统代理；
  `settings.json` 只写 `proxyRelayPort: 36815`，不再写 `mixedPort`。
- 真实运行 40 秒采样中 App CPU 平均 1.745%、峰值 5.2%、RSS 154.3~156.0 MB；core 平均 0.050%、
  RSS 49.5 MB。样本期约 8~9 组空闲 relay 连接且流量增量为 0；调用栈绝大部分处于等待，没有 relay
  自旋或持续 UI 忙循环。短时 1%~4% 峰值保留观察，不作为阻塞发布的问题。
- 当前边界：真机验收记录尚需提交并重新执行提交绑定 `prepare`；随后推送 v0.1.72、创建 GitHub Release、
  核对远端资产 digest，并删除 v0.1.67 Release/标签。不要为记录收口再次切换当前代理模式。

## 历史：v0.1.70 轻量交互、规则诊断与发布门禁

- 轻量仪表盘：内核流保持 1 秒精度，但连接数/内存/会话流量每 2 秒合并发布，图表每 4 秒追加一点；
  主窗口不可见时暂停图表写入。状态栏整机速度仍每 2 秒刷新，持久化菜单不重建。
- 测速：代理页和菜单栏显示完成数/总数，可随时取消；取消后不再派发新节点并保留已有结果。URL 测速
  临时拉起的“仅内核”会在完成或取消后停止，TCP/URL 有界并发仍为 32/16。
- 规则与连接：强制代理支持空格、逗号、分号、换行批量输入，整批校验后只重载一次；连续规则操作
  latest-wins 合并。新增域名/IP/进程规则命中测试器，连接页右键可强制代理、始终直连、按 App 分流、
  复制目标和查看完整链路。
- 诊断：新增持久化的 15 分钟诊断模式，临时把 sing-box 日志从 `info` 提升到 `debug`，到期自动恢复；
  启停通过受控重载并保留原有脱敏导出边界。
- 工程：新增 `scripts/release.sh`，把提交绑定的 M4/DMG 验证、安全退出旧版、代理/DNS/网络恢复、
  配置白名单备份、原子替换与 GitHub 发布串成门禁；M2/M3 使用本地编译的最小规则集，不再依赖
  GitHub 下载。M4 候选只能使用 `/tmp/kongshan-verify-*/support`，不会读取真实用户配置。
- 候选验证：完整 M4 执行 431 项、1 项按预期跳过、0 失败；Release/arm64/deep+strict/sing-box
  1.13.14/规则集配置均通过。五次空闲 CPU 0.4/0.0/0.3/0.0/0.4%，平均 0.220%，最大 RSS
  123,360 KB；无 TCP socket、子进程、FIFO 或 recovery 残留。
- 安装与真机验收已完成；但 TUN 切回系统代理暴露出临时端口池冲突，发布被阻止并升级到 v0.1.71 修复。

## 历史：v0.1.68 已本地安装，尚未发布 GitHub（2026-08-07）

- `RoutingView` 新增紧凑的“强制代理”分区，支持域名、IPv4/IPv6 和 CIDR；单 IP 保存时补主机前缀，
  已添加项可删除，非法 URL/端口/路径和回环目标就地报错。
- 持久化继续复用 `rules.json` 中的 `customRules`，不新增迁移字段。规则优先级为用户自定义规则在前；
  旧策略组在新配置中不存在时由 `ConfigGenerator` 回落当前主代理出站。
- 系统代理模式会过滤与强制域名/IP 冲突的 bypass；TUN 规则模式会过滤重叠的 route exclude。全局/直连
  模式保留原排除列表，`127.0.0.1`、`localhost`、`::1` 与 TUN 回环排除不可移除。
- 验证：13 条定向回归通过；规则页 740x640 有/无订阅规则离屏快照无裁切；Impeccable detector 零告警；
  最终全量 422 通过、1 跳过、0 失败。隔离 M4 平均 CPU 0.260%、最大 RSS 122,896 KB。
- 成品：`VERSION` 为 0.1.68，`/Applications/kongshan.app` 为 v0.1.68/build 168，arm64、deep/strict
  签名和 sing-box 1.13.14 均通过。`dist` 只保留 `kongshan-0.1.68.dmg`，镜像校验有效，SHA-256
  `009fdf679a767a245491ed48280071d0d39f32be353f1b8de2ae466021e78d78`；主程序 SHA-256
  `fcd062936f9c732fe4b3bcf2753184f1b3d4eed9d2cc1502550531fdbaf625c1`。
- 安装：旧版通过 `Command-Q` 正常退出；退出后 App/core、系统代理和 recovery 均为空，直连 HTTPS 200。
  配置白名单备份到 `~/Library/Application Support/kongshan-backups/kongshan-config-0.1.68-20260807-112825.tar.gz`，
  SHA-256 `7d1b17fc5e783371d6bf8a2908de60a965d0e9d3dcc84e56904d10bf2c676df2`。安装后设置、规则与订阅
  元数据哈希均与备份一致，UI 仍为“奶昔”/`Taiwan 01`，代理保持关闭。
- 运行验收：安装版 5 秒空闲平均 CPU 0.08%、最大 RSS 108,656 KB；无 sing-box、系统代理或 recovery，
  直连 HTTPS 200。规则页已显示“强制代理”的域名与 IP/CIDR 控件。
- 剩余边界：免密码助手因主程序 cdhash 更新显示“需重装”，本轮未触发管理员授权；重装前 TUN 仍可用，
  但每次会请求密码。代码、标签和 GitHub Release 尚未推送，线上最新版仍是 v0.1.67。

## 历史：v0.1.67 已安装并发布（2026-08-04）

`VERSION` 与 `/Applications/kongshan.app` 均为 v0.1.67/build 167。正式成品只保留
`dist/kongshan-0.1.67.dmg`，SHA-256
`0524eeac9e4149fa95ecf734136fd6fbcc18b02ba62bbab8672110201d068854`；主程序 SHA-256
`e25a6ab7fd234bbd25c12778ac3de938fc730608671980bd8ef566b26a37580b`。全量测试 414 通过、
2 跳过、0 失败；deep/strict 签名、DMG CRC、主程序与内核 arm64、M4 性能门禁均通过。

`main` 与 `v0.1.67` 标签已推送；GitHub Release 已发布并上传唯一 DMG：
`https://github.com/kongshan-0924/kongshan-proxy/releases/tag/v0.1.67`。GitHub 返回的资产 digest 与本地
SHA-256 一致。旧 Release 和旧版本标签已清理，远端只保留历史基线标签与 v0.1.67。

### 2026-08-04 16:50 发布后运行复查

- 安装版 v0.1.67/build 167 正在以系统代理模式运行；App/core PID 47578/51711，HTTP、HTTPS、SOCKS
  均指向 `127.0.0.1:65495`，内核只在该回环地址监听。经代理访问 GitHub 返回 200，约 0.40 秒。
- 10 次、每两秒一次的健康采样通过：App 平均/峰值 CPU 0.190%/0.9%，最大 RSS 62,400 KB，FD 85；
  core FD 最大 136、ESTABLISHED 最大 102、CLOSE_WAIT 0。当前没有资源失控或连接泄漏证据。
- 最近 24 小时统一日志无 ERROR/FAULT，近 7 天无 App/core 崩溃报告。运行事件累计 61 info/1 error；
  唯一 error 仍是 8 月 3 日 00:44 的历史启动失败，之后的换网重载、启动和配置应用均成功。
- 16:34 连续三次配置应用产生两条 `context canceled`，时间与旧内核被新内核替换完全重合，之后数据面
  正常，不是持续节点或 DNS 故障。若以后单次点击也稳定触发多次重载，再按交互去重问题调查。
- 当前配置为“奶昔”，四个订阅的 `autoUpdate` 均为 false；先前 TAG 每 15 分钟重试的待办已自然关闭。
  用户数据约 27 MB，其中日志约 26 MB，停用的 `sing-box-tun.log` 约 15.7 MB，可按需从 UI 清理。
- 本地 `main` 与 `origin/main` 同步且检查前工作区干净；`dist` 只有 v0.1.67 DMG。线上 Release 非草稿、
  非预发布，唯一资产 uploaded，线上 digest 仍与本地 DMG SHA-256 一致。

### 2026-08-04 v0.1.67 发布与单副本收口

- 发布前界面确认系统代理开启；只发送 `Command-Q` 正常退出，未使用 TERM/KILL。退出后 App/core
  消失、两类 recovery 文件清除，直连 Apple HTTPS 200/约 48 ms，才开始备份和替换。
- 配置备份位于 `~/Library/Application Support/kongshan-backups/`，文件名
  `kongshan-config-0.1.67-20260804-154816.tar.gz`，权限 0600，SHA-256
  `0ed99fe951da6299237c9ada05ca1de7bea746501657031ccf8be75369ab76da`。保留设置、规则、订阅元数据和
  订阅 YAML；只排除可再生 Fake-IP 缓存、日志、临时运行目录和 recovery 文件，不进入 Git/Release。
- 构建脚本改为把可运行 App 放在已忽略的 `.build`；`dist` 只输出最新 DMG。`make_dmg.sh` 在新 DMG
  成功后清理旧 DMG 和历史 `dist/kongshan.app`，避免 LaunchServices/程序坞识别第二份 App。
- 发布 M4：414 通过、2 跳过、0 失败；五次 CPU 0.5/0.0/0.5/0.0/0.9%，平均 0.380%，最大 RSS
  116,128 KB。release、arm64、deep/strict、sing-box 1.13.14、规则集和残留检查均通过。
- 正式 App 经 `/Applications` 暂存验签后原子替换；安装版为 v0.1.67/build 167，签名和主程序哈希
  与候选一致。已删除 `.build` 临时 App 和 `/private/tmp` 中 v0.1.60-v0.1.67 的旧 App 备份。
- 最终只存在 `/Applications/kongshan.app`；程序坞持久项也只指向该路径，`dist` 只剩最新 DMG。
- 助手真机身份探针确认 bundle 路径和 cdhash 都匹配，`isTrusted = true`，无需重装 TUN 助手。

### 2026-08-04 v0.1.67 安全替换

- v0.1.66 退出前已确认接管关闭、无 sing-box/recovery，三类系统代理为 off、直连 HTTPS 200；只通过
  App 的 `Command-Q` 正常退出，未发送 TERM/KILL。退出后再次确认 App/core 消失且网络正常。
- 旧版退出后完整 M4 通过：7 条定向测试无失败；CPU 0.6/0.0/1.1/0.0/0.6%，平均 0.460%，
  最大 RSS 113,952 KB；签名、arm64、Info.plist、无残留子进程/连接/恢复文件均通过。
- v0.1.67 采用暂存验签后原子切换，安装版 deep/strict 签名通过；旧 App 备份已在本次“只保留最新版”
  收口中删除，旧版本不再提供本地 App 回滚。
- 新版 PID 40968，UI 显示“已关闭”和 v0.1.67 (167)；启动后 6 次 CPU 0.0%~0.2%，RSS 97 MB 左右，
  无 sing-box、代理或 recovery，直连 HTTPS 200。未自动恢复旧接管。
- 后续真机身份探针确认当前安装版与助手记录的 bundle 路径、cdhash 均一致，`isTrusted = true`；此前
  页面短暂显示“需重装”已不再是当前发布阻塞，未放宽任何助手校验。

### 2026-08-03 v0.1.67 无订阅规则配置的规则页

- 根因：`useSubscriptionRules` 是跨配置保留的全局偏好，默认值为开启；规则页未判断当前配置的
  `subscriptionRules` 是否为空，导致空配置仍显示“应用订阅规则”已开启，页面语义矛盾。
- 修复：规则页只取一次当前配置规则；规则为空时隐藏无效的订阅规则开关，页头改为“当前配置未提供
  订阅规则；仍可管理内置分流和分应用代理”。不重置已保存的偏好，因此切回带规则的配置仍沿用用户选择。
  广告拦截和分应用代理在无订阅规则配置中继续可用。
- 验证：新增 `routing-no-subscription-rules.png` 离屏快照，确认空状态页不再出现该开关；全量测试通过。
- 本节修复已随 v0.1.67 安装；无规则页离屏快照已验证。最终真机切换到 `vmiss` 的视觉复核仍可后续进行，
  但不需要为此改变当前生效配置。

### 2026-08-04 最新运行审计

- App PID 42138，10 次样本 CPU 0.0%~0.1%，RSS 46,544~58,112 KB，FD 98；无监听端口、无 sing-box。
  系统内存可用 37%，用户数据目录 27 MB，近 7 天无 kongshan/sing-box 崩溃报告。
- `scutil --proxy` 为空、无 recovery 文件，默认路由 `en0`；直连 Apple HTTPS 返回 200，总耗时约 52 ms。
- 24 小时统一日志 0 ERROR/FAULT、0 WARN。运行事件共 55 条 info、1 条 error；唯一错误是 8 月 3 日
  00:44 的一次内核启动失败，13 秒后 TUN 成功启动，之后多次换网均成功重载，未再复发；8 月 4 日
  13:04 内核正常停止。
- 当前生效配置是“奶昔”，其单订阅自动更新关闭，时间不变化符合设置。只有 TAG 开启自动更新，但最后
  成功更新时间仍为 7 月 29 日；消息页显示 HTTP 401、TLS、离线后继续使用缓存，并有通知权限未开启。
  结合调度逻辑，失败后会每 15 分钟重试；应更新 TAG 的订阅凭据/地址，或不再使用时关闭其自动更新。
- 代理关闭时 App 保留 1 条稳定 HTTPS 连接且 10 秒内没有增长，无监听端口；结合 TAG 重试状态，当前
  不像泄漏。旧 `sing-box-tun.log` 约 15 MB、已停用，可由 UI 的缓存清理按需删除，不自动处理。

## 历史状态：v0.1.66 已安装并安全替换完成（2026-08-02）

`VERSION`、`dist/kongshan.app` 与 `/Applications/kongshan.app` 均为 v0.1.66/build 166；
DMG 为 `dist/kongshan-0.1.66.dmg`，SHA-256
`67a2e713fee550610e49d8b8634245ef84ac971eae1a66d14c7b6541a649bd1d`，主程序 SHA-256
`1a5e53f7f51af1b94996b84420ed57b1dde4172c0d4a4d3833569f0aa1afd46c`。

全量测试：**414 通过 / 2 跳过 / 0 失败**。release 构建、arm64、deep/strict 签名、
hardened runtime、DMG 校验与隔离 M4 均通过；最终 M4 平均 CPU 0.620%，最大 RSS 129,984 KB。

### 2026-08-02 v0.1.66 代理页、测速与交互性能

- 策略组按用途使用不同 SF Symbol 与颜色；紧凑窗口下两个测速按钮完整显示。代理页一次渲染只计算
  一次策略、选中项、节点元数据和延迟快照，避免节点卡片重复解析与查询。
- 批量 TCP 测速并发提高到 32；URL 测速为 16 个有界并发、单节点 3 秒超时，并按 24 条结果合并
  发布到 Observation。141 节点真机样本由约 30 秒降到约 17.3 秒，App 峰值 CPU 45.6% 降到
  16.8%；最终安装版受当时网络响应波动影响约 26.1 秒完成，操作期间仍可交互。
- “测速并选最快”只测当前策略候选，不再扫完整配置。配置切换热重载失败会回滚配置 ID、组选择、
  当前节点、延迟和落盘设置；诊断快照或设置落盘失败只告警，不再错误回滚已经健康运行的代理。
- 真机审计发现 URL 测速启动的“仅内核”状态在正常退出时会残留 sing-box；根因是退出流程只判断
  `activeModes`。现同时判断 `runtime` 并复用统一 `stop()`，新增真实测试内核回归，最终成品复测已确认
  App/core 一起退出、无恢复文件、系统代理关闭、DNS 回到 `192.168.2.1`、直连 HTTPS 200。
- 最终安装版 PID 42138，重新打开后保持“已关闭”，没有自动接管或启动内核。被替换候选备份在
  `/private/tmp/kongshan-0.1.66-pre-lifecycle-fix-retired-20260802-234725.app`。

### 2026-08-02 v0.1.65 原生状态栏实时速度与稳定菜单

- 用 AppKit `NSStatusItem + NSMenu` 取代 SwiftUI `MenuBarExtra`；状态栏按钮每 2 秒独立更新固定宽度
  速度图，`NSMenu` 从启动到退出保持同一个对象，速度刷新不再打断菜单跟踪。
- 整机速度直接复用 `NetworkThroughput.physicalCounters()` 与 `ThroughputRateCalculator`，只统计
  `en*` 物理网卡；没有把高频字段重新放进 `AppState` 或 SwiftUI Observation 图。
- 菜单只在 `menuWillOpen` 时根据 `AppState` 构建一次，展开期间冻结内容；出站模式、代理开关、
  节点、测速、刷新订阅、开机启动、面板和退出均改用原生 `NSMenuItem` target/action。
- 5 条菜单定向回归通过，覆盖菜单身份不变、相同速度不重复换图、固定图宽、原生面板动作和
  AppKit 架构守卫；全量 410 通过/1 跳过/0 失败。
- 隔离 M4 五次 CPU 0.2/0.0/0.4/0.0/0.4%，平均 0.200%，最大 RSS 121,184 KB；真实安装版
  主窗口可见且状态栏刷新时平均 CPU 0.630%、峰值 4.2%，最大 RSS 127,712 KB。
- 安全替换：旧 v0.1.64 只收到 Apple 正常退出事件，未发 TERM/KILL；确认 App/core 消失、
  三类系统代理关闭、恢复文件清除、直连 HTTPS 200 后才跑 M4、安装并打开 v0.1.65。
- 当前安装版 PID 7659；系统代理保持关闭，无 sing-box/恢复文件，直连 HTTPS 200；Computer Use
  已确认主窗口正常。最终状态栏速度显示、节点子菜单保持和节点选择需用户用鼠标确认。
- 旧版备份和退役副本：`/private/tmp/kongshan-0.1.64-{backup,retired}-20260802-133855.app`。

### 2026-08-02 v0.1.64 菜单稳定性根治与面板入口修复

- v0.1.63 的修复只删除了菜单正文的代理速率，判断不完整：`MenuBarExtra` 的 label 仍读取
  `nicUploadText/nicDownloadText`，每 2 秒替换一次 `NSImage`，仍会打断同一 Scene 的原生菜单跟踪。
- v0.1.64 状态项只读取低频的图标样式与接管状态，彻底删除整机网速采样、格式化与速率合成图；
  实时代理速率仍在仪表盘显示。这样菜单展开期间没有周期性 label 更新。
- “打开仪表盘”此前用 `(NSApp.delegate as? KongshanAppDelegate)?`，强转失败会静默无操作；现改为
  App 入口直接把 `appDelegate.showMainWindow` 注入 `MenuBarView`，并有源码守卫测试。
- 安全替换：旧 v0.1.63 只收到 Apple 正常退出事件，未发 TERM/KILL；确认 App/core 退出、
  三类系统代理关闭、恢复文件清除、直连 HTTPS 200 后才安装并打开 v0.1.64。
- 当前状态：安装版 PID 92135，系统代理保持关闭，无 sing-box/恢复文件，直连 HTTPS 200；
  Computer Use 已确认主窗口正常渲染。旧版备份和退役副本在
  `/private/tmp/kongshan-0.1.63-{backup,retired}-20260802-1151.app`。
- 验证边界：Computer Use 可读界面，但本机未批准对 kongshan 的点击/按键操作，无法自动关闭窗口后
  再从状态项点击打开。源码依赖和入口已覆盖，最终菜单悬停、节点选择、重新打开窗口需用户手动确认。

### 2026-08-02 状态栏实时速度恢复方案（已由 v0.1.65 实施）

- 若要同时保留实时速度和稳定菜单，不应再让周期性速度进入 SwiftUI `MenuBarExtra` 的 label；固定宽度、
  降低刷新频率或 `TimelineView` 仍可能使同一 Scene 的原生菜单在跟踪期间被重建。
- 推荐只迁移托盘层到 AppKit `NSStatusItem + NSMenu`：状态栏按钮独立更新速度图，持久化 `NSMenu`
  不随速度刷新替换；菜单仅在 `menuWillOpen` 时按 `AppState` 构建一次，展开期间保持内容稳定。
- 仪表盘和其余界面继续使用 SwiftUI；节点选择、代理开关和“打开仪表盘”改用 `NSMenuItem`
  target/action 调用现有 `AppState` 与 `KongshanAppDelegate.showMainWindow()`。
- 上述方案已在 v0.1.65 完成，保留本节作为设计取舍记录。

### 2026-08-02 v0.1.63 菜单节点选择闪烁修复（历史，未完全解决）

- 根因：`MenuBarView` 的下拉菜单正文直接读取每秒变化的 `state.uploadRate/downloadRate`；
  SwiftUI 在菜单展开时持续重建 `NSMenu`，节点子菜单会闪退、重开或丢失鼠标选择。
- 修复：删除下拉菜单里重复的实时速率行；菜单栏图标仍照常显示上下行速率，没有减少主要信息。
  新增源码守卫测试，禁止菜单正文重新订阅这两个高频状态。
- 安全替换：旧 v0.1.62 仅收到 Apple 正常退出事件，未发送 TERM/KILL；确认 App 和 sing-box
  均退出、恢复文件清除、Wi-Fi 三类系统代理关闭、直连 HTTPS 返回 200 后才安装并打开新版。
- 安装后首次复核：v0.1.63 PID 73775，系统代理关闭，无 sing-box、无恢复文件，默认接口 `en0`，
  直连 HTTPS 返回 200；这证明替换过程没有自动恢复旧接管。
- 最终复核时系统代理已开启（本轮没有执行代理开关操作），新版 sing-box PID 74228 在
  `127.0.0.1:65495` 监听，恢复快照存在，代理 HTTPS 返回 200。App/core 单点 CPU 2.7%/0.9%，
  RSS 203,952/45,456 KB，接管链路正常。
- 旧版备份：`/private/tmp/kongshan-0.1.62-backup-20260802-0005.app` 和
  `/private/tmp/kongshan-0.1.62-retired-20260802-0005.app`。
- 验证边界：macOS 拒绝当前自动化进程向 `System Events` 发送 Apple Event（-1743），因此未能
  自动持续悬停节点子菜单；根因依赖已切断且有回归测试，仍建议用户手动展开菜单确认一次交互。

### 2026-08-01 v0.1.62 安全替换与运行结论（历史）

`VERSION`、`dist/kongshan.app` 与 `/Applications/kongshan.app` 均为 v0.1.62/build 162；
DMG 为 `dist/kongshan-0.1.62.dmg`，SHA-256
`d047e6f75c082ff7aadbb6bc895418935a2db84f8405d656b8f641ea5c3bd8d7`，主程序 SHA-256
`4dd045a2efd0b8d949ece1f336bd4bad3e837bda37e3c4eaa95a48356ae82f77`。

全量 `swift test`：**410 通过 / 1 跳过 / 0 失败（共 411）**。`swift build`、release 构建、
arm64、deep/strict 签名、hardened runtime、sing-box 1.13.14、DMG 校验与隔离 M4 均通过；
M4 平均 CPU 0.940%，最大 RSS 132,016 KB。真实安装版可见仪表盘平均 CPU 0.180%，
最大 RSS 123,440 KB。

- 旧 v0.1.61 App/core PID 为 34001/45932。只发送 Apple 正常退出事件，未发送 TERM/KILL。
- 确认两个 PID 均消失、HTTP/HTTPS/SOCKS 全部关闭、恢复文件清除且直连 HTTPS 返回 200 后，
  才替换安装包并打开新版。
- 旧 App 可恢复备份在 `/private/tmp/kongshan-0.1.61-backup-20260801-2316.app`。
- 新版已打开（PID 68610），系统代理保持关闭，没有 sing-box 或恢复文件，直连 HTTPS 返回 200。
- 新增长期资源门禁短验通过：App 平均/峰值 CPU 1.533%/2.3%、RSS 219,280 KB、FD 111；
  core FD 211、174 ESTABLISHED、0 CLOSE_WAIT。该样本取自替换前仍有真实流量的 v0.1.61，
  用于验证脚本与既有运行基线，不应误写成 v0.1.62 长期运行结论。

### 2026-08-01 v0.1.61 安全替换与运行结论（历史基线）

- 旧 v0.1.60 退出前 PID 23969，子 sing-box PID 23979，系统 HTTP/HTTPS/SOCKS 指向
  `127.0.0.1:65495`。仅发送 Apple 正常退出事件，1.89 秒返回；未发送 TERM/KILL。
- 退出后两个 PID 均消失，三类系统代理全部关闭，`proxy-recovery.json` 清除；不经过代理的
  Apple HTTPS 返回 200。满足硬门槛后才安装新版。
- 旧 App 可恢复备份在 `/private/tmp/kongshan-0.1.60-backup-20260801-100438.app`；新版主程序
  SHA-256 为 `62fb0380bd8e4dfa68e4527490fe811ccd59d5d1f0fd38fe8e0b942a0b0cd142`。
- 新版已打开（PID 34001），按设计没有自动恢复接管，也没有启动 sing-box 或留下恢复文件；
  直连网络正常。代理关闭、窗口可见时 10 次平均 CPU 0.100%，最高 0.3%，最大 RSS 150,512 KB。
- 用户已通过 App 开启系统代理；HTTP/HTTPS/SOCKS 均为 `127.0.0.1:65495`，真实流量曲线、
  20 条连接与 3,479 条规则下完成全页面采样。仪表盘平均 CPU 2.78%、峰值 4.9%；再次复测
  平均 1.45%、峰值 2.5%，相比旧版 26%~33% 下降约九成且通过 10%/20% 性能门禁。
- 最高负载是未聚合日志持续流入：平均 CPU 6.36%、峰值 15.9%；开启按连接聚合后同类突发
  平均 3.13%、峰值 8.6%。静态/实时页面平均均低于 2%，菜单栏后台稳定平均 0.57%。
- 页面 RSS 约 136~190 MB，日志页峰值后能回落，不是单向泄漏；系统内存仍有 61% 可用。
  测试后 App/core FD 98/81，对应 46 ESTABLISHED + 2 LISTEN，无 CLOSE_WAIT、无新崩溃，
  日志末 2,000 行 0 ERROR/0 WARN，最终代理 HTTPS 返回 200。

### 2026-08-01 21:44~21:50 运行复查

- App PID 34001 已连续运行约 11 小时 45 分；sing-box PID 45932 已连续运行约 8 小时 15 分，
  helper PID 10543 已运行超过一天。系统 HTTP/HTTPS/SOCKS 仍为 `127.0.0.1:65495`。
- 连接突发期 App 20 秒平均 CPU 4.51%、峰值 7.5%，RSS 189~191 MB；安静期 11 个有效样本
  平均 3.76%、峰值 5.7%，RSS 回落并稳定在 184 MB。sing-box 安静期平均 0.36%、峰值 0.9%、30 MB。
- 突发来自系统 CloudTelemetry 高频创建 `gateway.icloud.com` 连接；core FD 随后从约 94 回落到
  73~75，ESTABLISHED 从 60 回落到 39~41，连续 10 秒 0 CLOSE_WAIT；App FD 固定 108。
- 13:11 与 13:34 的核心重建分别贴合订阅、规则和生成配置文件的修改时间，无崩溃报告；
  现有证据更符合受控配置重载，而不是异常自愈，但日志没有记录具体 UI 发起动作。
- 当前日志 15:36 后共 25 条 ERROR、0 WARN；最后两条为 21:23 的 `block[reject]` 预期拒绝。
  最近真实异常停在 17:06 的默认接口丢失/换网簇，之后未继续。最终代理 HTTPS 返回 200。

历史审计中旧版有流量、仪表盘可见时约 26%~33% CPU / 221 MB，热点明确在
`NSWindow layoutIfNeeded` -> SwiftUI ViewGraph -> Dashboard/Charts；sing-box 仅 0.4%~0.7% / 31 MB。
本轮已把速率标题、会话累计量和 Chart 拆成独立 Observation 节点，并新增真实窗口性能门禁。

**接手先读这三份**：`README.md`（软件现状）、`docs/PROGRESS.md`（能力清单）、
`docs/NEXT_STEPS.md`（下一步）。本文件往下是逐版本的根因记录，按需检索。

### 别改回去的设计点

这些都是踩过真机坑之后定下来的，每条都有对应的回归测试：

1. **TUN 固定 gVisor + Fake-IP(`240.0.0.0/4`) + 系统 DNS 指向 TUN 接口自身地址**。
   三者任一改动都会在多网关/企业网下让网页全打不开。
2. **会话累计流量只能取 `/connections` 的 `uploadTotal`/`downloadTotal`**。
   速率乘采样间隔会漏掉两次采样之间开完又关的连接；累加活跃连接的字节漏掉短命连接。
3. **`route.default_domain_resolver` 必须是无连接的 UDP**。它负责解析出站节点自己的域名，
   用 DoH 的话长连接被 NAT 回收后整个代理停摆 10 秒。
4. **内网 DNS 探测必须在接管系统 DNS 之前**。接管后 `scutil --dns` 只剩内核自己的地址。
5. **菜单栏图标必须是模板图标**，状态只能靠形状与不透明度表达（菜单栏会染成单色）。
   整块 label 要自绘成图——SwiftUI 排版在 MenuBarExtra 里控不住。
6. **菜单栏网速只累计 `en*`**，不是所有接口相加：TUN 开着时一份流量会在 `utun`（明文）
   与 `en0`（密文）各记一遍。
7. **助手不得使用 `DispatchSource`/`DispatchQueue`**。`main.swift` 顶层代码在 Swift 6 下是
   `@MainActor` 隔离的，交给 dispatch 队列的闭包一碰顶层状态就 SIGTRAP，编译期零提示。
   有源码层守卫测试。
8. **不得为省一次密码弹窗放宽 cdhash 校验**——ad-hoc 的 identifier 谁都能伪造。
9. **测试与文档严禁写入真实订阅密码或用户的内网域名**；`subscriptions/*.yaml` 不得提交。

### 环境笔记（真机驱动会用到）

- System Events 的 `click at` **点不动 SwiftUI 侧栏的 List 行**（内容区的按钮可以点）。
  可行做法：先点侧栏取得焦点，再用 `key code 125/126` 方向键移动选择。
- 本机 AX 树对本应用**恒返回 0 个按钮**（屏幕醒着也一样），只能靠截图 + 坐标定位。
- 窗口可能被移到另一块屏（position y 为负），`screencapture` 只抓主屏——截图前先查窗口位置。
- `osascript ... to quit` 可能挂满 2 分钟（AppleScript 等事件回复的默认超时），
  应用本身 1 秒多就退干净了。测退出耗时要独立轮询进程。

## 2026-07-30 v0.1.54 成品化打磨 + 全流程走查（当前版本）

上一轮（0.1.52）改完只跑了自动化测试。本轮补做**自审 + 真机逐页走查**，
发现 11 处问题并全部修完（5 处是上一轮自己引入的），明细见 SESSION_LOG
「全流程真机走查 + 自审」条。要点：

- 文案：仪表盘版本号前缀加错（真机上 coreVersion 已含 `sing-box`）；
  「关于 → 内核」有既有的重复前缀 bug。
- 位置：「外观」段插进了「隧道」页，应在「通用」。
- 性能：日志行每次渲染重新解析、规则分组算两遍、连接列表 filter+sort 算四遍，均已提取。
- 噪音：规则组内重复显示目标策略；连接链路显示原始 `node-<uuid>` 而非节点名。
- 测试：我写的一条断言是偶发失败的（ISO8601 往返丢精度），已改容差。
- 环境：System Events 点不动 SwiftUI 侧栏 List 行，要用方向键；本机 AX 树对本应用恒为空。

真机验证通过：会话流量实时累加、3479 条规则归 9 组、16 行日志聚 4 组、
连接累计与速率一致、菜单栏图标清晰、外观段就位。

## 2026-07-30 v0.1.52 成品化打磨

用户提的 11 项打磨要求：**8 项完成，2 项部分完成**。完整机理与取舍见
`docs/progress/SESSION_LOG.md` 2026-07-30「成品化打磨」条。

| 项 | 状态 |
|---|---|
| App 图标（空山） | ✅ `scripts/make_icons.swift` 可重生成 |
| 菜单栏图标 3 样式 × 3 状态 | ✅ 设置 → 外观 可切换 |
| 本次会话流量统计 | ✅ 仪表盘「网络流量」格内 |
| 自建节点粘贴分享链接解析 | ✅ 6 种协议，可批量 |
| 规则页降噪（按目标策略分组） | ✅ 不再静默截断到 200 |
| 连接统计修正 | ✅ 首帧速率不再恒为 `—` |
| 内核日志改造 | ✅ 只看问题 / 按连接聚合 / 按主机搜 |
| 内存与性能审查 | ✅ 本来就干净，补了观察者注销 |
| 代理模块 UI 美化 | ⚠️ **未做**（`PolicyGroupsView` 未动） |
| 设置模块逐字段梳理 | ⚠️ **部分**（新增外观段，未逐条通读 14 个 Section） |

- 测试：`swift test` **381 通过 / 1 跳过 / 0 失败**，`swift build` 0 警告。
- 成品：`dist/kongshan-0.1.52.dmg`，SHA-256
  `dd78d8c58b5873101650b85562d06b2f62791d5ec4ea743a4f08562b78107876`；已装 `/Applications`。

### 三个别改回去的设计点

1. **会话累计流量只能取 `/connections` 的 `uploadTotal`/`downloadTotal`**。
   速率乘采样间隔会漏掉两次采样之间开完又关的连接；累加活跃连接的字节则漏掉短命连接。
   内核重启计数器归零，靠"检测回退即结转基线"跨过去（`SessionTrafficAccumulator`）。
2. **菜单栏图标必须是模板图标**，状态只能靠形状与不透明度表达。菜单栏把图像染成单色，
   任何配色方案都会失效——所以"开启"是线稿变实心，不是变绿。
3. **`@MainActor` 类的 `deinit` 在 Swift 6 里是 nonisolated 的**，碰不到隔离且非 Sendable
   的属性。要在析构时清理这类资源，得像 `NotificationObserverBag` 那样交给独立持有者。

## 2026-07-30 0.1.51 内网 DNS 分流（当前版本）

### 解决的问题

TUN 模式下用 Windows App 连内网设备"一直在加载"。

**根因不是劫持，是 Fake-IP 把内网域名吞了。** 内网 AD 域是个 `.com`，既不命中
`geosite-cn`，也就必然掉进 `dns-fakeip`；fakeip 不校验域名是否存在，任何名字都给
`240.0.0.0/4` 的假 IP，而假 IP 整段被路由进代理出口 → 流量被发去国外节点连办公室的机器。

**路由层完全没问题**（这点先排除了）：`route_exclude_address` 生效得很干净，
`route get 172.16.16.7` 走 en0，TUN 开着时 TCP 3389/389/135/445/53 实测全通。

### 修法

- `dns.servers` 加 `{tag: dns-lan, type: udp, server: <内网DNS>, port: 53}`，**无 detour**。
- `dns.rules` **首位**插内网后缀规则——必须排在 geosite-cn 与 fakeip 之前。
- 路由把内网后缀并进直连规则（内网域名可能解析到 DMZ 公网 IP，按 IP 判定会落空）。
- 系统代理模式另加 bypass（该模式 DNS 归 OS 管，内核只从 CONNECT 拿域名）。
- 探测**必须在接管系统 DNS 之前**：接管后 `scutil --dns` 只剩内核自己的地址。

### 关键难点：企业网不下发搜索域

真机 `scutil --dns` 只有 nameserver、**没有 search domain**。纯靠搜索域探测一个域名都
找不到。加了 **PTR 推断**，用 AD 的固有结构：`PTR(内网DNS)` → `AD1.<AD域>` → 候选域，
再要求**该域在同一台服务器上解析到私有 IP** 才接受。第二步是防误判的关键
（`114.114.114.114` → `public1.114dns.com`，但 `114dns.com` 解析出公网地址会被拒）。

### 真机验证（系统代理模式，零配置）

- `dns-lan = {172.16.16.7:53, udp}`；`dns.rules[0] = {domain_suffix: ["<AD域>"], server: "dns-lan"}`
- 系统代理绕过表三个服务都含 `*.<AD域>` 与 `<AD域>`
- `settings.json` 里手动项全为空 ⇒ 域名**完全来自 PTR 推断**
- 全量 344 通过 / 1 跳过 / 0 失败，0 编译警告

### 待用户验证

**TUN 模式需要点一次并输密码**（App 重建 cdhash 变，助手要重装一次）。
验完看 `dig @172.19.0.1 <内网主机>` 应返回真实内网 IP 而不是 240.x。

### 已知边界

内网 DNS 只在启动时探测。**TUN 运行中换网络**不会重新探测，旧内网域名会被送去
已不可达的内网 DNS；关掉再开即可。

### 顺带确认

助手连续存活 6 小时以上，0.1.46 的 SIGTRAP 修复稳住了。

## 2026-07-30 11:05 运行复查：两个待修问题（最新）

App 已连续跑 10h41m，0.1.47 的 DNS 修复未复发（~16 分钟节律彻底消失），
崩溃报告归零，排除断网窗口后真实失败率 0.67%。**但发现两个新问题，建议在
推送/发布前一并处理成 0.1.48**（详细证据链见 `docs/progress/SESSION_LOG.md`
「2026-07-30 11:05」条）。

| # | 问题 | 严重度 | 根因位置 |
|---|---|---|---|
| A | 固定 mixed 端口在一次完整重启后从 49609 变成 65408，而 49609 当时空闲 | 中（0.1.45 要治的「正在重新连接」会重现） | `RuntimeSecrets.availableHighPort(preferred:)` 首选端口只探测一次、无重试 |
| B | 主 App 后台空闲时烧 50% CPU 持续 178 秒（04:43–04:46） | 低（自行结束、无崩溃、10h 内 1 次） | `AppState` 每秒无条件写 `@Observable` 属性 → 全图失效 → 深 96 层 AppKit 布局 |

**A 的判定依据**：此前六次启动 mixed 全是 49609、clash-api 是散乱随机端口；
08:35:24 这次 mixed 65408 / clash-api 65409 **相邻**，是「首选端口绑定失败、
连续两次内核分配」的指纹。`preferredMixedPort` 不被 `clearRuntimeState()` 清空，
崩溃自愈路径复用 `currentConfig` 不可能换端口，`config.json` mtime=08:35:24
证明走的是完整 `start()`。端口池 `49_152...65_535` 就是 macOS 临时端口范围，
首选端口随时可能被瞬时占用 → **0.1.45 的保证目前只是概率性的**。
修法：首选端口 3–5 次 × 200–300ms 退避重试；端口真变了给一条 warning。

**B 的判定依据**：`cpu_resource.diag` 热栈无任何业务帧，96 层
`_layoutSubtreeWithOldSize` 触底在 `ObservationCenter.invalidate` /
`SystemSegmentedControl._overrideSizeThatFits`；那三分钟连接量反而更低
（1/3/1/6，邻近 11–15），排除「连接多导致渲染重」。当前后台空闲基线 CPU 4–5.6%，
与「每秒至少一次全图失效」吻合。修法：`AppState.swift:1354/1362/2479-2480`
加等值守卫。**178 秒那次的确切触发条件采样不足，未定论。**

## 2026-07-30 0.1.47 DNS 停摆修复（当前版本）

### 仓库状态：本地领先 `origin/main` 两个提交，**未推送、未发 Release**

```
dac3718 fix(dns): 节点域名解析改走无连接 UDP，根治代理每 ~16 分钟停摆 10 秒   ← 0.1.47
cc10d39 fix(helper): 助手每 30 秒 SIGTRAP 崩溃——Swift 6 顶层代码的 actor 隔离  ← 0.1.46
```

GitHub 上最新 Release 仍是 **v0.1.45**。工作区干净，分支 `main`。
`dist/kongshan-0.1.47.dmg`，`/Applications/kongshan.app` = 0.1.47。
测试 314 通过 / 1 跳过 / 0 失败，0 编译警告。

### 0.1.46：免密码助手每 30 秒 SIGTRAP 崩溃

`swift-tools-version: 6.0` 下 `main.swift` 顶层代码是 @MainActor 隔离的，
助手却把 `DispatchSource` 信号处理与 30 秒自愈定时器挂在自建队列上，
闭包一碰顶层状态就触发执行器断言 → SIGTRAP，**编译期零提示**。
后果：`checkClientLiveness()`（App 消失时停 root 内核）从未执行过一次；
SIGTERM 优雅退出路径从未跑到；一个 root 进程每 30 秒被 launchd 拉起。
一直没被发现是因为 TUN 表面完全正常——内核是独立进程，助手重启后靠
`adoptOrphanKernel()` 重新认领，用户无感。
修法是把并发整个去掉：C 信号处理器 + accept 循环内按 `CLOCK_MONOTONIC` 轮询。
回归测试是源码层守卫（禁 `DispatchSource`/`DispatchQueue`/`setEventHandler`），
已反向验证注入后会失败。**助手需重装一次修复才生效**（helper 二进制不随 App 更新）。

### 0.1.47：`default_domain_resolver` 走 DoH，长连接被 NAT 回收后整个代理停摆

失败每 ~16 分钟一簇、全部 10.0s `context deadline exceeded`，末尾露出
`read tcp ...->223.5.5.5:443: operation timed out`。DoH 是 HTTP/2 over TLS 长连接，
路由器 NAT 悄悄回收后 sing-box 察觉不到，而这条通道正好负责解析**出站节点自己的域名**
——它一卡，整个代理跟着停摆。修法：`dns-bootstrap`（UDP 53）改为无条件生成，
`route.default_domain_resolver` 指向它；地址跟随用户配置的国内 DoH，不硬钉阿里。

### 2026-07-30 00:07 实机复核（本次会话实测，非推断）

| 项 | 结果 |
|---|---|
| 0.1.47 DNS 修复 | ✅ 修复前 19:49→20:05→20:21→20:33 每 16 分钟一簇；20:48 起 3h19m 内**只剩 1 次**（22:11），周期性消失 |
| 0.1.46 助手修复 | ✅ 助手 PID 39659 连续存活 **5h14m**（修复前每 30 秒重启）；崩溃报告停在 42 份，最后一份 18:34（修复前） |
| 0.1.45 端口固定 | ✅ `settings.json` mixedPort = 49609，跨多次重启未变 |
| 资源 | App RSS 100MB / 内核 43MB，运行 3h23m 无增长 |

残留（已知、可接受）：国内网站解析仍可能撞上陈旧 DoH 连接失败一次，
影响面已从"整个代理停摆"缩到"个别请求失败、重试即好"。
另有节点侧偶发 `i/o timeout` / `connection reset by peer`（00:01、00:03），
属节点或链路问题，与 DNS 修复无关。

## 2026-07-28 v0.1.45 固定本地代理端口（已真机验收）

版本号 0.1.45 = 0.1.44 的同一份代码（`verify_m4.sh` 会重新构建并递增补丁号）。

### 真机验收结果（全部实测，非推断）

| 项 | 结果 |
|---|---|
| 端口跨**完全退出重启** | ✅ 保持 49609 |
| 端口跨**三轮关→开** | ✅ 保持 49609（clash_api 端口每次随机，符合设计） |
| 端口跨**重装 App** | ✅ 保持 49609 |
| 崩溃自愈（强杀内核） | ✅ 自动重启且复用同一端口与同一份配置 |
| 崩溃限流（连杀 4 次） | ✅ 停止接管并**自动还原系统代理**，不留指向死端口的设置 |
| 退出清理 | ✅ 1.16s 退出，无残留内核、代理已还原、无恢复文件 |
| 系统代理 bypass | ✅ `127.0.0.1` / `localhost` / `::1` 在列表最前 |
| 诊断快照脱敏 | ✅ clash_api 已移除，password/uuid/reality 全为 `<redacted>` |
| 资源占用 | ✅ App CPU 0.3~0.5% / RSS 140MB；内核 CPU 0% / RSS 43~47MB |
| `verify_m4.sh` | ✅ 通过，空闲 CPU 0%、最大 RSS 123MB |
| 单元测试 | ✅ 311 通过 / 1 跳过 / 0 失败，0 编译警告 |

**驱动方式**：显示器休眠时 SwiftUI 不建可访问性树（`entire contents` 返回 0 个按钮，
截图全黑），AX 定位会失效；改用坐标点击 `{1167, 294}`（仪表盘页「系统代理」胶囊，
窗口在 `(375,112) 960x724` 时）。这不是应用问题。
另：`osascript ... to quit` 可能挂满 2 分钟——那是 AppleScript 等事件回复的默认超时，
应用本身 1.16s 就退干净了；测退出耗时要独立轮询进程，别信 osascript 的返回时刻。

### 本轮环境限制：所在网络在做透明代理，节点连通性无法验证

判据（`docs/design/tun-real-machine-debug.md` 的三条全中）：

- 直连国外出口 = `69.63.217.24`（就是订阅节点的 IP），直连国内出口 = `125.123.17.206`（嘉兴电信）——两个出口。
- 到洛杉矶 `69.63.217.24` 以及 `1.1.1.1`、`8.8.8.8` 的 TCP 握手**全部只要 4.5ms**，真跨太平洋不可能低于 130ms。
- 内核日志清一色 `reality verification failed`（握手被中途改写）。

即**路由器已把国外流量透传到同一个节点**，所以用户"关掉代理也能上外网"。
该环境下任何代理客户端的 Reality 节点都连不上，与本应用无关。
**「经代理取出口 IP」仍需换一个没有透明代理的网络才能验**（手机热点最省事）。

## 2026-07-28 0.1.44 固定本地代理端口

- **解决的问题**：用户报告 codex 在系统代理模式下反复「正在重新连接」、约 5 次后才连上。
- **根因（已坐实，非猜测）**：mixed inbound 端口每次内核启动都重新随机
  （`AppState.start()` → `runtimeFactory()` → `RuntimeSecrets.availableHighPort()`）。
  用户的 codex 是 ChatGPT 桌面版内嵌服务（Chromium 内核，日志 `router: found process path`
  可见），它**缓存**解析到的系统代理地址。内核一重启换端口 → 客户端继续打死端口 →
  「正在重新连接」→ 它自己重新读取系统代理配置并退避重试 → 若干次后才恢复。
  铁证：ChatGPT.app 启动于 10:05:38、内核启动于 10:47:09（晚 42 分钟），
  而 ChatGPT.app 事后连的是内核本次随机到的新端口——它被迫换过一次。
  只在系统代理模式出现，因为 TUN 模式根本不涉及端口。
- **已排除**（真机实测全部健康）：并发 10 条连接全成功；节点出口 69.63.217.24/LAX，
  `cdn-cgi/trace` 连打 12 次全 200 无限流；`ws.chatgpt.com` 的 WebSocket 隧道正常；
  无 DNS 失败（每条连接那 ~300ms 是 LA 节点 RTT，不是超时）。
- **修法**：端口首次分配后写入 `settings.json` 跨启动复用，被占用才另选。
  探测绑定必须置 `SO_REUSEADDR`（对齐 Go `net.Listen` 的默认行为）——否则内核刚停时
  旧连接还在 TIME_WAIT，裸 bind 会 EADDRINUSE，于是仍旧每次换端口，等于没修。
  clash_api 端口与 secret 保持随机（secret 是真正的安全边界；mixed 端口不是，
  它只监听 127.0.0.1、无鉴权，且必然通过系统代理设置公开给本机所有 App）。
- 测试：311 通过 / 1 跳过 / 0 失败，0 警告（新增 6 条回归）。
- 当前状态：0.1.44 / build 144 已装 `/Applications`；`dist/kongshan-0.1.44.dmg`。
- **注意**：升级后第一次启动仍会换一次端口（旧版没落盘过），之后才稳定。

## 2026-07-28 已发布 v0.1.43

- **代码已提交、已 squash 合并 `main`、已推送、已发 GitHub Release**。
  仓库只剩 `main` 一条分支（`fix/config-switch-ui-batch` 已删除）。
- Release：<https://github.com/kongshan-0924/kongshan-proxy/releases/tag/v0.1.43>
  DMG SHA-256 `3606670d0dc7749bf3600b70da04ee87091055c3ce488e49b03eb7aeeb79afe7`
- 本机 `/Applications/kongshan.app` 已是 0.1.43；`dist/` 只保留当前版本 DMG。
- 测试：`swift test` **305 通过 / 1 跳过 / 0 失败**，`swift build` 0 警告。

### 这一轮解决了什么

免密码 TUN 助手**此前从未真正生效**，四个缺陷串在一条链上（修好一个才暴露下一个），
全部修复且每个都有能独立验证该环节的回归测试。完整机理与"别改回去"的理由见
`docs/design/tun-authorization-approaches.md`：

1. 身份校验比对错对象（`SecCodeCopyPath` 对 bundle 返回 `.app` 目录）→ 永远"需重装"
2. launchd 装载竞态（bootout 异步 + helper 慢退）→ `Bootstrap failed: 5: EIO`
3. 线缆层用普通 `read()` 读长度前缀 → SCM_RIGHTS 被内核丢弃 → `missing config fd`
4. `posix_spawn` 继承管道写端 → 内核永远等不到 EOF，卡在读配置

外加睡眠唤醒假死、信号升级、连接重置等生命周期加固（见 SESSION_LOG 2026-07-27/28 各条）。

### 真机验证到什么程度

- **TUN 数据面已完全打通**：352KB 内核日志逐条确认 tun-in 收包、DNS 劫持、规则分流、
  国内直连、进程匹配、Fake-IP 全部正常。
- **系统代理 + TUN 双开可用**，出口 IP 为节点所在地、DNS 无泄漏（用户截图佐证）。
- 系统代理/DNS 的接管与还原在真机上逐字节核对通过；Clash API 三条实时流、退出监控、
  规则集下载编译、日志存储均真跑通过。

### 仍未验证 / 已知边界

- **睡眠唤醒后的自动重建隧道**（0.1.40 新增）尚未经用户真机复现验证。
- 用户家庭网络在做**透明代理 + SNI 分流**，该环境下任何代理客户端的节点都连不上
  （判据见 `docs/design/tun-real-machine-debug.md`）。验证节点连通性须换网络。
- ad-hoc 签名固有代价：**App 每次重新构建 cdhash 都会变，助手需重装一次**
  （首次开 TUN 会自动弹一次密码完成），这不是 bug，不要为省这一次弹窗放宽 cdhash 校验。
- 同时运行多个 TUN 客户端（本应用与 Stash/Surge）会互抢默认路由。

## 2026-07-28 0.1.43 复审第二轮修复（当前版本）

- 专项复审本轮新代码，修 5 处：① 助手自愈停内核失败会弄丢 PID → 可能同时跑两个 root 内核
  （最严重，已与 stopKernel 分支对齐）；② 网络指纹改为只认 `en*`，避免 awdl/llw/bridge 抖动
  被误判成换网而掐断长连接；③ 指纹更新被短路跳过 + getifaddrs 失败时的误判；
  ④ `stop()` 早退丢失还原失败信息；⑤ `start()` 失败时还原错误被静默吞掉。
- 连带：停内核最坏 6 秒（三级信号），安装脚本等待预算 5s → 10s。
- 测试结果：305 通过 / 1 跳过 / 0 失败，0 警告。
- 当前状态：0.1.43 / build 143 已装 `/Applications`；代码未提交。

## 2026-07-28 0.1.42 连接重置收紧（当前版本）

- 0.1.41 加的"换网后重置全部连接"挂在 `NWPathMonitor` 上，会被 Wi-Fi 信号抖动、IPv6 续租
  之类的无关事件触发，**反而会掐断正在进行的长连接**。改为只在物理网络指纹
  （非回环/非隧道接口的 IPv4 集合）真的变化时才重置；睡眠唤醒仍无条件重置。
- 断流排查结论：系统代理日志里 vless 只有 2 条 `context canceled`（关闭时的正常收尾），
  无中途失败痕迹；但有 7 次内核启动（含 16 秒内重启一次）——内核重启会瞬间掐断所有连接，
  是最可能的断流机制。订阅自动更新已关、规则集更新不重启内核，故重启应来自用户操作。
- 测试结果：305 通过 / 2 跳过 / 0 失败，0 警告。
- 当前状态：0.1.42 / build 142 已装 `/Applications`；代码未提交。

## 2026-07-28 0.1.41 换网/唤醒后主动重置连接（当前版本）

- 已完成：`reassertTakeoversAfterNetworkChange`（网络变化 + 睡眠唤醒共用）在补挂代理/DNS 后
  主动 `DELETE /connections`。换网后旧连接已作废但本地客户端不知情，会卡在死 socket 上
  反复重试（TCP 重传耗尽要十几分钟），主动关掉可让客户端立刻收到 RST 并重连。
- 测试结果：305 通过 / 1 跳过 / 0 失败，0 警告。
- 当前状态：0.1.41 / build 141 已装 `/Applications`；`dist/kongshan-0.1.41.dmg`；代码未提交。

## 2026-07-27 0.1.40 睡眠唤醒内核假死修复（当前版本）

- 已完成三项修复（详见 SESSION_LOG 2026-07-27 23:55）：
  1. **助手停内核只发 SIGINT 不升级** → 睡眠唤醒后假死的内核杀不掉，赖着导致
     下次开 TUN 撞 `kernel already running`，即用户说的"休眠后再也起不来"。
     改为 SIGINT→SIGTERM→SIGKILL 逐级升级并确认退出；连带修掉"子进程变僵尸时
     `kill(pid,0)` 仍返回 0"导致的误判（先 `waitpid(WNOHANG)` 收尸）。
  2. **唤醒自检只查 Clash API** → 内核假死时 API 照常应答，TUN 网卡没了却察觉不到。
     改为用 `getifaddrs` 判定 TUN 地址是否还在，没了就走崩溃自愈重建隧道。
  3. **日志轮转用原子写换 inode** → 运行中内核的 fd 指向已 unlink 的旧文件，
     日志静默消失。改为原地 `ftruncate` + `pwrite`。
- 新增 6 条回归测试（信号升级纯逻辑 5 条 + 真起 `trap '' INT` 子进程的实证 1 条）。
- 测试结果：305 通过 / 1 跳过 / 0 失败，0 警告。
- 当前状态：0.1.40 / build 140 已装 `/Applications`；`dist/kongshan-0.1.40.dmg`；代码未提交。

## 2026-07-27 0.1.39 `kernel already running` 自愈（当前版本）

- 已完成：`startTUN` 的 helper 分支无条件先 `recoverIfNeeded()` 再 start——
  助手握着遗留内核时不再把用户顶成死胡同（此前只能去终端 sudo 杀进程）。
- 真机验证（0.1.38 起的内核）：352KB 日志证明 **TUN 数据面完全打通**——
  tun-in 收包、DNS 劫持、规则分流、国内直连、进程匹配、Fake-IP 全部正常。
- 节点连不上系**用户家庭路由器做透明代理 + SNI 分流**所致，与 App 无关。铁证：
  国内/国外 IP 服务给出两个不同出口；任意 SNI 连节点服务器都返回对应证书；
  到美国 IP 的 TCP 握手仅 3~4ms。判据已写入 `docs/design/tun-real-machine-debug.md`。
- 测试结果：299 通过 / 1 跳过 / 0 失败，0 警告。
- 当前状态：0.1.39 / build 139 已装 `/Applications`；`dist/kongshan-0.1.39.dmg`；代码未提交。
- 下一步：在没有透明代理的网络（手机热点最省事）验一次代理出口 IP，通过即可提交合并发布。

## 2026-07-27 0.1.38 spawn 继承管道写端修复（当前版本）

- 已完成：修掉助手链路第四个坑——`posix_spawn` 继承了未置 CLOEXEC 的管道写端，
  sing-box 自己握着自己 stdin 的写端 → 永远等不到 EOF → 卡在读配置：
  进程活着但不监听、日志 0 字节，App 报"控制接口未就绪"。
  两端置 `FD_CLOEXEC`，日志 fd 用 `O_CLOEXEC`；helper 监听/连接 socket 同样置 CLOEXEC。
- 新增 2 条真 spawn 回归测试（`/bin/cat` 替身，正反证明）。
- 测试结果：299 通过 / 2 跳过 / 0 失败，0 警告。
- 当前状态：0.1.38 / build 138 已装 `/Applications`；`dist/kongshan-0.1.38.dmg`；代码未提交。
- 助手四连坑全部修完（身份校验对象错 / launchd 装载竞态 / SCM_RIGHTS 被丢弃 / spawn 继承写端），
  每个都有独立回归测试。
- 遗留：用户机上卡住的 root sing-box(PID 14194) 会在下次开 TUN 或 App 重启时被自动清掉；
  手动清理：`sudo pkill -f '/Library/Application Support/kongshan/helper/sing-box'`。

## 2026-07-27 0.1.37 线缆层修复：missing config fd（当前版本）

- 已完成：修掉助手链路的第三个坑——App 一次 sendmsg 发「长度前缀+body」并挂 SCM_RIGHTS FD，
  helper 却先用普通 `read()` 读长度前缀，内核因此丢弃辅助数据并关闭 FD → `missing config fd`。
  线缆层收拢为 `HelperProtocol.HelperWire` 两端共用，接收端改用 `recvmsg` 读长度前缀。
  顺带修掉 sendResponse 单次 write 截断、sendmsg 部分发送未补齐。
- 新增 6 条真 socketpair 回环测试，含"收到的 FD 与发出的是同一个 pipe"与
  "普通 read 会丢 FD"的反向证明。
- 测试结果：297 通过 / 1 跳过 / 0 失败，0 警告。
- 当前状态：0.1.37 / build 137 已装 `/Applications`；`dist/kongshan-0.1.37.dmg`；代码未提交。
- 助手三连坑至此全部修完（身份校验对象错、launchd 装载竞态、SCM_RIGHTS 被丢弃），均有回归测试。
- 下一步：用户开 TUN 验证零弹窗启动。

## 2026-07-27 0.1.36 助手装载竞态修复（当前版本）

- 已完成：坐实并修复 `Bootstrap failed: 5: Input/output error`——`launchctl bootout` 是异步的，
  helper 收到 SIGTERM 后要一两秒才退出（accept 循环 `poll(...,1000)`），脚本紧接着 `bootstrap`
  就撞上仍在卸载的 label。这正是"输了密码仍显示需重装、开 TUN 要输两次密码"的直接原因。
  已用用户域 LaunchAgent 实证复现（旧写法 exit=5，新写法 exit=0）。
  安装脚本改为 bootout → 轮询等 label 消失 → enable → bootstrap（失败重来一轮）→ print 确认；
  并把脚本抽成纯函数 `makeInstallScript`，加了真 `sh -n` 语法校验等 3 条测试。
- 测试结果：291 通过 / 2 跳过 / 0 失败，0 警告。
- 当前状态：0.1.36 / build 136 已装 `/Applications`；`dist/kongshan-0.1.36.dmg`
  SHA-256 `6ed44ebd7212e0c0662c4e75a7b58c5719c3a87a1fc42527cef454630ea47549`；代码未提交。
- 风险/注意事项：用户机上 **Stash 正在运行且开着 TUN**（utun4=198.18.0.1）并占着系统代理 7890；
  验收 kongshan 的 TUN 前必须先关 Stash 的 TUN，否则两个 TUN 抢默认路由。
  新网络下节点已完全可用（出口 69.63.217.24 / DMIT LA）。
- 下一步：用户关掉 Stash 的 TUN → 点一次 kongshan 的 TUN → 应只弹一次密码 → 之后启停零弹窗。

## 2026-07-27 0.1.35 免密码助手修复 + 模块巡检（当前版本）

- 已完成：修掉**让免密码助手长期完全失效**的根因——`SecCodeCopyPath` 对 bundle 返回 `.app` 目录，
  而 trust.json 钉的是主可执行路径，恒不相等 → 助手静默拒绝所有连接 → 界面永远"需重装"。
  trust schema 升 v3、新增 `clientBundlePath` 作为身份校验字段；安装后自检改轮询 5 秒；
  设置页说明"App 更新过（签名变了）"才是常见原因。
- 新增 `docs/design/tun-authorization-approaches.md`：NetworkExtension / SMJobBless 助手 /
  每次 osascript / setuid 四种做法的对比，以及本项目为何只能钉 cdhash、
  "App 更新 = 重装一次助手"为何是固有代价（禁止为省弹窗放宽 cdhash 校验）。
- 测试结果：288 单测 0 失败 0 警告；真机巡检 Clash API 三条流、退出监控、规则集下载编译、
  日志存储全通过；真机只读回归确认修复后 `isTrusted == true`。
- 当前状态：0.1.35 / build 135 已装 `/Applications`；`dist/kongshan-0.1.35.dmg`；代码未提交。
- 风险/注意事项：**待用户手动点一次「重新安装」助手**（需密码，无法自动化）；
  机器上现存的是旧 v2 助手，显示"需重装"属预期。用户当前网络仍拦着订阅里的两个节点。
- 下一步：用户装助手 → 验证零弹窗 TUN → 提交 → squash 合 `main` → 发 v0.1.35。

## 2026-07-27 0.1.34 全面审计 + 真机全流程测试

- 已完成：对全量源码（13.9k 行）做审计，发现并修复 10 项；细节见 `docs/progress/SESSION_LOG.md` 2026-07-27 00:30 条。最关键的三项：
  - `ProcessRunner` 的 continuation 存在数据竞争（每次 networksetup / sing-box check / version 都走这条路）。
  - Reality 的 `public_key` 未脱敏，真机 `config.json` 明文可见（0.1.32 加 VLESS 时漏的）；已改为按字段名的递归脱敏。
  - 未忽略 SIGPIPE：内核在读完配置前退出会**直接杀掉整个 App**。
- 测试结果：285 单测 0 失败 0 警告；真机跑通「真订阅 → 转换 → 生成 → check → 起内核 → Clash API → 路由 → 真流量」，direct 模式取到真实出口 IP；系统代理与系统 DNS 的接管/还原逐字节核对通过。
- 当前状态：0.1.34 / build 134 已装 `/Applications` 并运行正常；`dist/kongshan-0.1.34.dmg`，SHA-256 `2d58a2e6f2d66783f8d673328c1203144ec0fed733c5597017a84a3554c6bffe`；代码未提交，分支 `fix/config-switch-ui-batch`。
- 风险/注意事项：**用户当前网络拦掉了订阅里的两个节点**（TCP 3ms 假握手、TLS 零响应），因此"经代理取出口 IP"在该网络无法通过——与 App 无关。TUN 需 root 密码，仍待用户实测。
- 下一步：换一个能连通的网络验收代理出口与 TUN；通过后提交 → squash 合 `main` → 发 v0.1.34。

## 2026-07-25 0.1.33 复审问题已全部修复 + 已装本机

- 已完成：复审的 P1~P6 六项全修（详见 `docs/progress/SESSION_LOG.md` 2026-07-25 21:40 条）。
  - P1 残留 root 内核三层封堵：helper 启动 `adoptOrphanKernel()` 认领/清理遗留内核；卸载前先停内核 + 卸载脚本 `pkill` 兜底；TUN 运行时禁用安装/卸载/重装按钮。
  - P2 还原失败改 errorMessage + 手工恢复指引（不再说「可忽略」，仍不阻塞退出）。
  - P3/P4 用量与菜单栏速率占位符修正（菜单栏恢复单字母紧凑格式）。
  - P5/P6 白名单边界写进注释 + 四种模式组合回归；高位端口范围收进 `HelperConstants` 单一来源。
- 修改文件：`HelperProtocol.swift`、`KongshanHelper/main.swift`、`PrivilegedHelperInstaller.swift`、`RuntimeSecrets.swift`、`AppState.swift`、`MainWindowView.swift`、`DashboardView.swift`、`MenuBarView.swift` + 2 个测试文件 + `VERSION`。
- 测试结果：`swift build` 0 警告；`swift test` 285 通过 / 1 跳过 / 0 失败；arm64、deep/strict 签名、hardened runtime、sing-box 1.13.14 均通过。
- 当前状态：0.1.33/build 133 已安装到 `/Applications/kongshan.app` 并启动自检通过（无崩溃、空闲 CPU 0.4%、RSS≈116MB）；成品 `dist/kongshan-0.1.33.dmg`；**代码改动未提交**，分支仍是 `fix/config-switch-ui-batch`。
- 风险/注意事项：App 重建后 cdhash 变，旧 helper 会拒新 App → 首次开 TUN 弹一次密码自动重装助手（预期）。`adoptOrphanKernel` 需真机装 helper 后才能验证。
- 下一步：用户验收 0.1.33 → 提交 → squash 合 `main` → 发布 v0.1.33。
- 接手方式：改 helper 生命周期时保持「只对可执行路径匹配的 PID 发信号」不放宽。

## 2026-07-25 0.1.32 维护者复审结论（合并前）

- 已完成：`origin/main...fix/config-switch-ui-batch` 9 提交逐文件复审；独立复跑 `swift build`（0 警告）、`swift test`（282 通过 / 1 跳过 / 0 失败）；diff 无真实凭据、无二进制入库。
- 结论：helper 白名单投递链、trust v2 fail-closed 迁移、`activeTUNBackend` 后端钉死、`TunStack` 删除的 Codable 兼容性、VLESS `network: tcp` 修复均正确，可合。
- 待修（详见 `docs/progress/SESSION_LOG.md` 2026-07-25 21:10 条 6 项）：
  - P1 卸载/重装助手不先停内核 + 按钮未按 TUN 状态禁用 → 可能留下无法从 App 清理的 root sing-box（既有缺口，本分支让它更易触发）。
  - P2 `stop()` 里 DNS 还原失败的「可忽略」文案与实际断网后果不符。
  - P3 `MainWindowView.swift:341`、`DashboardView.swift:343` 仍用会返回空串的 `Theme.bytes`。
  - P4 菜单栏 `MenuRateFormatter.compact` 改用 ByteCountFormatter 后更宽更跳。
  - P5 白名单未覆盖 `dns`/`route`/outbound 非 type 字段；回归测试只覆盖 `[.tun]`。
  - P6 高位端口范围两处硬编码。
- 建议：P3/P4 + P1 的按钮禁用是分钟级修复，修完再 squash 合 `main`；P1 的 `kernel.pid` 持久化与 helper 启动 reconcile 可排 0.1.33。

## 2026-07-25 0.1.32 功能整合成品

- 已完成：在 0.1.31 审计修复基础上，删除无效 TUN stack/interfaceName，修复 IPv6-only 空地址；新增订阅 VLESS（含 TLS/WS/gRPC/Reality）、兼容性统计、脱敏诊断导出、已安装 App 分流选择和安全的应用更新入口。
- 修改文件：`ProxyMode.swift`、`Models.swift`、`ClashSubscriptionConverter.swift`、`ConfigGenerator.swift`、`AppState.swift`、`MainWindowView.swift`、`RoutingView.swift`、`LogsView.swift`、`Theme.swift` 及对应测试。
- 测试结果：全量 `swift test` 282 通过、1 跳过、0 失败；10 张离屏界面快照生成成功；VLESS 配置通过内置 sing-box 1.13.14 check；M4 自动验证、arm64、deep/strict 签名、hardened runtime、DMG 校验全部通过。
- 当前状态：分支 `fix/config-switch-ui-batch`，未推、未合 main；成品 `dist/kongshan-0.1.32.dmg`，SHA-256 `ec255233febb71d6152719d592bcef970084dca6018069a587b72cce3180f00c`；未安装、未修改真机网络。
- 风险/注意事项：private GitHub 仓库不能安全地由 App 匿名查询版本，因此更新入口只打开 `releases/latest`，绝不内置 Token；诊断包不含凭据，但日志可能含域名/服务器地址。
- 下一步：交用户安装并完成 `NEXT_STEPS.md` 的真机验收；明确通过后再复审并合并 main。
- 接手方式：先核对分支、版本和上述 DMG 哈希；不要在用户验收前合 main。

## 稳定边界

- TUN 固定 gVisor；系统 DNS 指向 TUN 接口自身 IPv4；Fake-IP 使用 `240.0.0.0/4`。
- TUN 启停只经 `startTUN/stopTUN/recoverTUNIfNeeded`；一次生命周期固定 helper/osascript 后端。
- helper 只执行内置、签名钉死的 sing-box；配置经 FD 传递并通过白名单；不得弱化 trust v2。
- 代理/DNS 恢复失败必须保留失败服务快照供下次重试。
- 测试和文档严禁写入真实订阅密码；`subscriptions/*.yaml` 不得提交或导出到诊断包。
