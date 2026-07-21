# 下一步

## 🔴 待排查：开 TUN 后仪表盘出站 IP 一直跳 / 一会一变

用户反馈：TUN 已能正常开启且快，但开了之后**出站 IP 频繁变化**，怀疑规则或节点在自动切换。

排查方向（按可能性）：
1. **看当前 config.json 的 `route.final` 和主流量走向**：我们默认 `final: 自动选择`（urltest）。unmatched 流量走 urltest→最快节点，urltest 每 `interval`(5m) 重测、按 `tolerance` 切换。若 342 个节点里多个延迟接近，可能来回切 → IP 跳。
   - 位置：`ConfigGenerator.route(...)` 里 `"final": "自动选择"`；urltest 生成在 `generate(...)` 顶部。
   - 可选修法：把 `final` 或主组默认改成用户在「手动选择」里选的**固定节点**（稳定不跳）；或给 urltest 调大 `tolerance`(如 150ms)、拉长 `interval`。
2. **订阅规则可能指向了 urltest / load-balance 组**：`ClashSubscriptionConverter.policyGroups` 把 Clash 的 `url-test/fallback/load-balance` 都映射成我们的 `.urltest`。若机场主组是 `load-balance`（本意是每条连接轮流用不同节点→每次 IP 不同），被当成 urltest 后行为不一致；反之若确是 urltest，多目标请求分散到不同组也会让"我的IP"每次不同（属正常）。
   - 确认：`discoveredRules[activeConfigID]` 里主要 target 是哪个组，该组 kind 是不是 urltest。
3. **DNS remote DoH 经 `自动选择`**：DNS 查询走 urltest，不同查询可能不同节点，但这影响解析不影响浏览出站 IP。
4. 让用户切「出站模式=全局」并在「手动选择」选一个固定节点，看 IP 是否就稳定——能快速区分是"urltest 在跳"还是"规则把流量分到多组"。

结论倾向：多半是 `自动选择`(urltest) 作为 final/主组导致的正常但不理想的行为。建议做一个开关或默认走手动选中的固定节点。

## 真机回归（本会话大量改动，务必过一遍）
1. **系统代理**：点一下应"又快又不卡"（之前是托盘菜单 100% CPU 拖累，已修）。开启后提示条会显示"启动耗时 → …"，正常零点几秒。
2. **TUN**：点 TUN→输密码→秒级接管；`~/Library/Application Support/kongshan/logs/sing-box-tun.log` 应有 `inbound/tun` 正常路由，无 `EOF`/`bad tun name`。
3. **配置切换 / 节点增删**：运行中热重载 <2s，不卡。
4. **托盘菜单**：每个策略子菜单最多 40 项，超出显示"在代理页选择全部（N 个）…"。
5. 空闲 CPU 应为 0%，RSS <150MB（实测 141MB）。

## 环境坑（必须让用户处理，否则反复出问题）
- **CleanMyMac 5** 后台代理会反复删除 `~/Library/Application Support/kongshan`（订阅/设置/缓存）和 `.app`。
  务必在 CleanMyMac 里把这两个路径 + 项目 `dist/` 加入**忽略/排除**。已发生多次数据与 App 被清。
- 用户是**笔记本(主屏,菜单栏) + 上方大外接屏**的多显示器；窗口已强制居中到主屏。

## 可选（非阻塞）
- 订阅级自定义 UA / base64 格式回退；`profile-update-interval` 头。
- 一次性特权 helper（SMAppService+XPC）替代每次 TUN 提权弹窗。
- 策略组还原订阅成员的嵌套引用；被丢弃订阅规则的可见提示。
- 托盘实时速率、外部访问（需破红线，待用户拍板）。
- 启动时那一次性 ~2s CPU 峰值（首建菜单+载配置）可再优化，但已可接受。
- 清理 start() 里的临时计时提示（"启动耗时 → …"每次开代理都进 warnings，确认没问题后可去掉或只在慢时显示）。
