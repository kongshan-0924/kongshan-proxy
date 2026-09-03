# 原生 macOS 界面重构（v0.1.96）

## 一、现状盘点

现有界面是 **Surge / Stash 式的"仪表盘"语汇**（`Theme.swift` 注释原话："风格参考 Surge / Stash"）：

| 现状 | 出处 | 与原生的差距 |
| --- | --- | --- |
| 窗口 `titleVisibility = .hidden`、`titlebarAppearsTransparent = true` | `KongshanApp.swift` | 没有真正的标题栏；每页用自绘 `PageHeader` 冒充页头，标题 15pt 手写 |
| `.card()`：白底 + 0.5pt 描边 + **投影** | `Theme.swift` | macOS 原生容器是 `GroupBox`/`Form` 分组，**不用投影** |
| `IconBadge`：渐变填充的彩色圆角图标块 | 仪表盘指标卡、配置行 | 系统件里没有这种"贴纸"，是 web 仪表盘的装饰 |
| 自绘 `SearchField`（放大镜 + 清除按钮） | 连接 / 日志 / 代理 | 系统有 `.searchable`，会放进工具栏并带原生快捷键与外观 |
| 连接列表是 `LazyVStack` 自绘行 | `ConnectionsView` | 活动监视器那类实时表格是 `Table`（可排序、列宽可调、AppKit 承载、省 CPU） |
| 节点是 `LazyVGrid` 卡片网格，悬停加投影 | `PolicyGroupsView` | Surge/ClashX 都是**列表**：一行一个节点，点击即选中 |
| 设置分区用页头里的分段控件 | `SettingsView` | 分段控件应在工具栏正中（访达视图切换器的位置） |
| 侧栏宽度 168–230 | `MainWindowView` | HIG 建议 225–275 起步；未读数自绘胶囊而非系统 `.badge` |
| 硬编码字号 `.system(size:)` 70 处 | 全部视图 | 系统文本样式（`.headline`/`.body`/`.caption`）才跟随动态字体与系统一致 |

## 二、参考与依据

- Apple HIG · Toolbars：工具栏承载页面主任务，按优先级排序，别塞太多项。
  https://developer-mdn.apple.com/design/human-interface-guidelines/components/menus-and-actions/toolbars/
- Apple HIG · Sidebars / 第三方整理的侧栏规范：侧栏 225–275pt 起步、最多两级、动作放底栏而非侧栏工具栏。
  https://marioaguzman.github.io/design/sidebarguidelines/
- macOS 设置窗口规范（usagimaru）：分组用 Form、标签 13pt、说明 11pt 次要色、边距 20pt、**避免 Save/Apply 式按钮**、不自定义背景色。
  https://zenn.dev/usagimaru/articles/b2a328775124ef?locale=en
- SwiftUI on macOS：`NavigationSplitView` + `Form(.grouped)` + `Table` + `.inspector` 是 2023 后的原生骨架。
  https://oneuptime.com/blog/post/2026-02-02-swiftui-macos-applications/view
  https://www.createwithswift.com/exploring-the-navigationsplitview/
- Surge Mac 6.0："几乎每一页都按最新 macOS 设计规范重做"，首页增强数据展示；仪表盘可隐藏列、导出 CSV——即**表格**形态。
  https://kb.nssurge.com/surge-knowledge-base/release-notes/surge-mac-6-release-note
- 本机系统应用对照：系统设置（grouped Form）、活动监视器（Table + 副标题统计）、邮件（侧栏 `.badge`、标题 + 副标题）、控制台（等宽日志 + 工具栏过滤）。
- `ui-ux-pro-max` skill：只取"设置用 Form 不手工分组""尊重减弱动态"两条；其余推荐（OLED 暗色、玻璃拟态）是 web 语汇，与本次目标相反，**不采纳**。

## 三、原则

1. **标题栏是真的**：`titleVisibility = .visible`、`toolbarStyle = .unified`。每页 `.navigationTitle` + `.navigationSubtitle`（副标题放统计："12 条 · ↑ 1.2 MB/s"），页面操作进 `.toolbar`。
2. **容器只用系统件**：`GroupBox` / `Form(.grouped)` / `List(.inset(alternatesRowBackgrounds:))` / `Table`。不投影、不渐变、不描边卡片。
3. **搜索进工具栏**：`.searchable(placement: .toolbar)`。
4. **颜色只用语义色**：`.primary/.secondary/.tertiary/.quaternary`、`Color.accentColor`、状态色（绿/橙/红）只做点缀，状态同时有文字。
5. **字体只用文本样式**：`.title2/.title3/.headline/.body/.callout/.caption/.caption2`，数字 `.monospacedDigit()`。
6. **不动的东西**：所有业务行为与 `AppState` 接口；侧栏切换按钮（`MainWindowToolbarTests` 钉死为一个 `.navigation` 项 + `removing: .sidebarToggle`）；消息页「只看问题」开关与事件详情渲染（`RuntimeEventDetailTests` 钉死）；高频数值**不做动画**（v0.1.79 那次 8 小时燃烧的教训）。

## 四、逐页方案

| 页 | 工具栏 | 内容 |
| --- | --- | --- |
| 仪表盘 | — | 状态 `GroupBox`（状态点 + 文字 + 节点 + 实时速率；第二行出站模式/接管开关）；指标 `GroupBox` 网格；流量 `GroupBox` |
| 配置 | 刷新全部 · 自建节点 | 导入栏（圆角文本框 + 按钮）；`List` 交替行底色，系统符号替代渐变图标块 |
| 代理 | 出站模式 · 排序 · 测速全部 · 测速并选最快；`.searchable` | 左 `List(.sidebar)` 策略；右 **`List` 选择即切换节点**，一行：选中标记 · 国旗 · 名称 · 协议 · 倍率 · 延迟 |
| 规则 | `.searchable`（搜规则） | 上半 `Form(.grouped)`：规则开关分区 + 四个可折叠分区（`Section(isExpanded:)`）；下半规则浏览 `List` |
| 连接 | 全部关闭；`.searchable`；副标题放条数与总速率 | **`Table`**：目标/进程 · 规则·链路 · ↑↓ 速率 · ↑↓ 累计 · 关闭；列可排序；右键菜单保留 |
| 内核日志 | 等级分段 · 过滤菜单（三个勾选项） · 清空 · 导出；`.searchable` | 等宽行不变（控制台式） |
| 消息 | 正中分段（警告/运行事件） · 全部清除 | `List`；底部状态条标明存档路径 |
| 设置 | 正中分段（五个分区） | `Form(.grouped)` 不变，去掉自绘页头与自定义背景 |
| 托盘弹窗 | — | 去投影/渐变；策略组改系统 `Picker(.menu)`；速率用 `Label` |

## 五、刻意不做的

- **不搬到 `Settings` 场景（⌒,）**：本应用是 LSUIElement + 自管 NSWindow，激活策略在 `.accessory/.regular` 间切换，多开一个 SwiftUI 管理的窗口会引入新的激活/关闭时序问题；且"接管方式/助手安装"这类操作性设置用户高频访问，留在侧栏更顺手。
- **不做 Liquid Glass（macOS 26）**：最低系统仍是 macOS 14，只用 14 可用的 API。
- **不改任何业务逻辑**：这是纯表现层重构；`AppState` 与 Core 零改动。
