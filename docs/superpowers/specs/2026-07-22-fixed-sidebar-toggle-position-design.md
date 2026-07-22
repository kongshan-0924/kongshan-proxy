# 侧边栏按钮固定位置设计

## 问题与目标

0.1.21 只保留了 `NavigationSplitView` 的系统侧边栏按钮，解决了重复按钮，但人工验收发现：侧边栏展开时按钮位于左上角，折叠后同一个系统按钮会迁到标题栏最右侧。

用户已在可视化对比中选择 B：无论侧边栏展开或折叠，界面始终只显示一个按钮，并固定在红黄绿窗口控制键右侧。

## 根因

系统按钮由 `NavigationSplitView` 自动加入，位置随分栏状态由 macOS 决定。上一版曾把 `.toolbar(removing: .sidebarToggle)` 放在整个分栏外层；Apple 的 API 用法要求将它放在产生默认按钮的侧栏视图上，因此不能依赖旧写法稳定移除系统按钮。

## 决策

采用纯 SwiftUI 的受控分栏：

1. 给 `NavigationSplitView` 增加 `NavigationSplitViewVisibility` 绑定。
2. 在侧栏 `List` 上使用 `.toolbar(removing: .sidebarToggle)`，从正确作用域移除系统默认按钮。
3. 在主窗口声明唯一一个 `.navigation` 位置的自定义按钮。该位置在 macOS 工具栏左侧，按钮不会随侧栏消失迁移。
4. 点击按钮只在 `.all` 与 `.detailOnly` 间切换，分别显示和隐藏完整侧栏。

不恢复图标紧凑侧栏，不新增 AppKit 工具栏监听、延时重试、私有 API、依赖或抽象层。

## 状态与交互

- 初始状态为 `.all`，主窗口打开时显示完整侧栏。
- 当前为 `.detailOnly` 时，点击按钮切换为 `.all`；其他状态点击后切换为 `.detailOnly`。
- 按钮使用 `sidebar.left` 系统图标，并按当前状态提供“显示侧边栏”或“隐藏侧边栏”的帮助与辅助功能标签。
- 页面选择、侧栏底部状态、代理状态和窗口生命周期均保持不变。

## 修改范围

- `Sources/kongshan/MainWindowView.swift`：增加分栏可见性状态、正确作用域的默认按钮移除、唯一固定按钮及切换逻辑。
- `Tests/KongshanAppTests/MainWindowToolbarTests.swift`：先写失败回归检查，再锁死受控可见性、正确移除作用域、唯一导航按钮和无 AppKit 时序清理。
- `VERSION` 与发布记录：产出 0.1.22（build 122），供用户重新验收。

不修改 `KongshanApp.swift`、AppState、代理内核、系统代理、TUN、订阅或持久化逻辑。

## 测试与验收

1. 回归测试先在当前 0.1.21 代码上因缺少受控可见性和固定按钮而失败，再由最小实现转绿。
2. App 测试及全量 `verify_m4.sh` 通过，打包、签名和 DMG 校验通过。
3. 安装后系统只发现一个 `/Applications/kongshan.app`，只保留一个最新版 DMG。
4. 人工打开仪表盘、设置及其他页面：标题栏始终只有一个按钮。
5. 连续展开、折叠侧栏：按钮始终紧邻红黄绿窗口控制键右侧，不跳到最右侧。
6. 用户验收通过前，修复保持在 `fix/sidebar-toggle`，不合并 main。

## 风险与回退

命令行 XCTest 不能可靠读取 SwiftUI Scene 生成的真实标题栏项目，因此自动测试锁死布局架构，最终位置保留打包 App 人工确认。若新方案异常，回退本次提交即可恢复 0.1.21；不需要迁移数据或恢复代理设置。
