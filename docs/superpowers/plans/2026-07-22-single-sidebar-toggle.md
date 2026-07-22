# Single Sidebar Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the duplicate sidebar toolbar button and retain only the native macOS `NavigationSplitView` toggle.

**Architecture:** Revert the custom compact-sidebar layer added in 0.1.20 and rely on SwiftUI/AppKit's native sidebar presentation. A real-window regression test counts both the native toolbar item and the custom tooltip-based item so the current duplicate fails and the native-only implementation passes.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Swift Package Manager.

---

### Task 1: Lock the duplicate-button regression

**Files:**
- Create: `Tests/KongshanAppTests/MainWindowToolbarTests.swift`

- [ ] **Step 1: Write the failing real-window test**

```swift
import AppKit
import XCTest
@testable import kongshan

@MainActor
final class MainWindowToolbarTests: XCTestCase {
    func testMainWindowHasExactlyOneSidebarToggle() throws {
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let delegate = KongshanAppDelegate()
        delegate.showMainWindow()
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let window = try XCTUnwrap(NSApp.windows.first {
            !existingWindows.contains(ObjectIdentifier($0)) && $0.title == "kongshan"
        })
        defer { window.close() }

        let sidebarItems = (window.toolbar?.items ?? []).filter { item in
            item.itemIdentifier == .toggleSidebar ||
                item.toolTip?.contains("侧边栏") == true ||
                item.toolTip?.contains("边栏") == true
        }
        XCTAssertEqual(
            sidebarItems.count,
            1,
            "窗口只能保留一个侧栏按钮：\(sidebarItems.map { $0.itemIdentifier.rawValue })"
        )
    }
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter MainWindowToolbarTests/testMainWindowHasExactlyOneSidebarToggle`

Expected: FAIL because the real window contains the native toggle plus the 0.1.20 custom compact-sidebar toolbar item.

- [ ] **Step 3: Commit the regression test**

```bash
git add Tests/KongshanAppTests/MainWindowToolbarTests.swift
git commit -m "test: reproduce duplicate sidebar buttons"
```

### Task 2: Return to the native sidebar toggle

**Files:**
- Modify: `Sources/kongshan/MainWindowView.swift:4-130`
- Modify: `Sources/kongshan/KongshanApp.swift:55-88`

- [ ] **Step 1: Remove custom compact-sidebar state and branches**

In `MainWindowView`, remove `isSidebarCompact`, `sidebarRowCompact`, the custom navigation `ToolbarItem`, `.toolbar(removing: .sidebarToggle)`, and all conditional widths/status layouts. Keep the native structure:

```swift
NavigationSplitView {
    List(selection: $selection) {
        sidebarRow(.dashboard)
        Section("管理") {
            sidebarRow(.nodes)
            sidebarRow(.policyGroups)
            sidebarRow(.routing)
        }
        Section("其他") {
            sidebarRow(.connections)
            sidebarRow(.logs)
            sidebarRow(.settings)
        }
    }
    .listStyle(.sidebar)
    .navigationSplitViewColumnWidth(min: 186, ideal: 200, max: 250)
    .safeAreaInset(edge: .bottom, spacing: 0) { sidebarStatus }
} detail: {
    // Existing detail content stays unchanged.
}
.navigationTitle("kongshan")
```

Restore `sidebarStatus` to one non-conditional `HStack(spacing: 8)` with 14-point horizontal padding.

- [ ] **Step 2: Delete the timing-dependent AppKit cleanup**

In `KongshanAppDelegate.showMainWindow()`, remove both `removeSystemSidebarToggle(from:)` calls. Delete the method entirely:

```swift
private func removeSystemSidebarToggle(from window: NSWindow) { ... }
```

- [ ] **Step 3: Run the focused test and verify GREEN**

Run: `swift test --filter MainWindowToolbarTests/testMainWindowHasExactlyOneSidebarToggle`

Expected: PASS with exactly one native `.toggleSidebar` item.

- [ ] **Step 4: Run the app test target**

Run: `swift test --filter KongshanAppTests`

Expected: all app tests pass; snapshot test may report its existing environment-based skip.

- [ ] **Step 5: Commit the minimal product fix**

```bash
git add Sources/kongshan/MainWindowView.swift Sources/kongshan/KongshanApp.swift
git commit -m "fix(ui): keep one native sidebar toggle"
```

### Task 3: Verify, package, and record the release

**Files:**
- Modify: `VERSION` through `scripts/build_app.sh`
- Modify: `docs/HANDOFF.md`
- Modify: `docs/PROGRESS.md`
- Modify: `docs/NEXT_STEPS.md`
- Modify: `docs/progress/SESSION_LOG.md`
- Create: `dist/kongshan-0.1.21.dmg` (ignored build artifact)

- [ ] **Step 1: Run full automated verification**

Run: `zsh scripts/verify_m4.sh`

Expected: all Swift tests pass, release app is arm64 and strictly ad-hoc signed, idle checks pass, final line is `M4 automated verification passed`. The build script advances `VERSION` from 0.1.20 to 0.1.21.

- [ ] **Step 2: Build and verify the DMG**

Run: `zsh scripts/make_dmg.sh`

Expected: `dist/kongshan-0.1.21.dmg` is created.

Run: `hdiutil verify dist/kongshan-0.1.21.dmg`

Expected: exit 0 and `verified successfully`.

- [ ] **Step 3: Update durable project records**

Record the root cause, deleted custom implementation, RED/GREEN result, full verification result, artifact version, remaining manual visual check, and exact handoff instructions in all four project record files.

- [ ] **Step 4: Verify repository state and commit**

Run: `git diff --check`

Expected: exit 0 with no output.

```bash
git add VERSION docs/HANDOFF.md docs/PROGRESS.md docs/NEXT_STEPS.md docs/progress/SESSION_LOG.md docs/superpowers/plans/2026-07-22-single-sidebar-toggle.md
git commit -m "release: 0.1.21 single sidebar toggle"
```

- [ ] **Step 5: Report the manual boundary**

Report that automated toolbar inspection and full verification passed. Keep dashboard/settings visual clicking as an explicit manual check unless a fresh UI screenshot is obtained from the packaged app.
