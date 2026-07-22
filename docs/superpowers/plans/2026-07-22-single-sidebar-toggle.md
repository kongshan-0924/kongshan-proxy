# Single Sidebar Toggle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the duplicate sidebar toolbar button and retain only the native macOS `NavigationSplitView` toggle.

**Architecture:** Revert the custom compact-sidebar layer added in 0.1.20 and rely on SwiftUI/AppKit's native sidebar presentation. The regression test locks the native-only source invariant; CLI XCTest does not expose SwiftUI Scene titlebar items, so final packaged-window appearance remains a manual check.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, Swift Package Manager.

---

### Task 1: Lock the duplicate-button regression

**Files:**
- Create: `Tests/KongshanAppTests/MainWindowToolbarTests.swift`

- [x] **Step 1: Write the failing regression test**

The implemented test reads the two production source files and rejects `isSidebarCompact`, the custom navigation `ToolbarItem`, `.toolbar(removing: .sidebarToggle)`, and `removeSystemSidebarToggle`. This replaced the planned window count after three fixture attempts proved CLI XCTest exposes zero SwiftUI titlebar items.

- [x] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter MainWindowToolbarTests/testMainWindowHasExactlyOneSidebarToggle`

Expected: FAIL because the real window contains the native toggle plus the 0.1.20 custom compact-sidebar toolbar item.

- [x] **Step 3: Commit the regression test**

```bash
git add Tests/KongshanAppTests/MainWindowToolbarTests.swift
git commit -m "test: reproduce duplicate sidebar buttons"
```

### Task 2: Return to the native sidebar toggle

**Files:**
- Modify: `Sources/kongshan/MainWindowView.swift:4-130`
- Modify: `Sources/kongshan/KongshanApp.swift:55-88`

- [x] **Step 1: Remove custom compact-sidebar state and branches**

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

- [x] **Step 2: Delete the timing-dependent AppKit cleanup**

In `KongshanAppDelegate.showMainWindow()`, remove both `removeSystemSidebarToggle(from:)` calls. Delete the method entirely:

```swift
private func removeSystemSidebarToggle(from window: NSWindow) { ... }
```

- [x] **Step 3: Run the focused test and verify GREEN**

Run: `swift test --filter MainWindowToolbarTests/testMainWindowHasExactlyOneSidebarToggle`

Expected: PASS with exactly one native `.toggleSidebar` item.

- [x] **Step 4: Run the app test target**

Run: `swift test --filter KongshanAppTests`

Expected: all app tests pass; snapshot test may report its existing environment-based skip.

- [x] **Step 5: Commit the minimal product fix**

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

- [x] **Step 1: Run full automated verification**

Run: `zsh scripts/verify_m4.sh`

Expected: all Swift tests pass, release app is arm64 and strictly ad-hoc signed, idle checks pass, final line is `M4 automated verification passed`. The build script advances `VERSION` from 0.1.20 to 0.1.21.

- [x] **Step 2: Build and verify the DMG**

Run: `zsh scripts/make_dmg.sh`

Expected: `dist/kongshan-0.1.21.dmg` is created.

Run: `hdiutil verify dist/kongshan-0.1.21.dmg`

Expected: exit 0 and `verified successfully`.

- [x] **Step 3: Update durable project records**

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
