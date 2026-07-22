# Fixed Sidebar Toggle Position Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep exactly one sidebar button fixed at the macOS toolbar leading edge while it shows and hides the full sidebar.

**Architecture:** Keep `NavigationSplitView`, bind its visibility to local SwiftUI state, remove its default sidebar toggle from the sidebar view that contributes it, and add one `.navigation` toolbar button that changes the binding. Preserve all page, proxy, and window behavior.

**Tech Stack:** Swift 6, SwiftUI on macOS 14+, XCTest, existing shell build and DMG scripts.

---

## File map

- `Tests/KongshanAppTests/MainWindowToolbarTests.swift`: source-architecture regression check because CLI XCTest cannot inspect the real SwiftUI titlebar.
- `Sources/kongshan/MainWindowView.swift`: controlled split-view visibility and the sole fixed toolbar button.
- `VERSION`: release version 0.1.22; `scripts/build_app.sh` derives build 122.
- `docs/HANDOFF.md`, `docs/PROGRESS.md`, `docs/NEXT_STEPS.md`, `docs/progress/SESSION_LOG.md`: durable implementation and acceptance state.

### Task 1: Add the failing fixed-position regression

**Files:**
- Modify: `Tests/KongshanAppTests/MainWindowToolbarTests.swift`

- [ ] **Step 1: Replace the old native-only assertions with the approved architecture**

```swift
func testMainWindowUsesOneFixedSidebarToggle() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let projectRoot = testFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let mainWindowSource = try String(
        contentsOf: projectRoot.appending(path: "Sources/kongshan/MainWindowView.swift"),
        encoding: .utf8
    )
    let appSource = try String(
        contentsOf: projectRoot.appending(path: "Sources/kongshan/KongshanApp.swift"),
        encoding: .utf8
    )

    XCTAssertTrue(mainWindowSource.contains("@State private var columnVisibility: NavigationSplitViewVisibility = .all"))
    XCTAssertTrue(mainWindowSource.contains("NavigationSplitView(columnVisibility: $columnVisibility)"))
    XCTAssertTrue(mainWindowSource.contains(".toolbar(removing: .sidebarToggle)"))
    XCTAssertEqual(mainWindowSource.components(separatedBy: "ToolbarItem(placement: .navigation)").count - 1, 1)
    XCTAssertFalse(mainWindowSource.contains("isSidebarCompact"))
    XCTAssertFalse(appSource.contains("removeSystemSidebarToggle"))
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `swift test --filter MainWindowToolbarTests/testMainWindowUsesOneFixedSidebarToggle`

Expected: FAIL on the visibility state, controlled initializer, removal modifier, and unique navigation button assertions because 0.1.21 contains none of them.

- [ ] **Step 3: Record RED in `docs/progress/SESSION_LOG.md`**

Append a concise stage entry with the failing assertion count and the current branch.

- [ ] **Step 4: Commit the regression test**

```bash
git add Tests/KongshanAppTests/MainWindowToolbarTests.swift docs/progress/SESSION_LOG.md
git commit -m "test: reproduce migrating sidebar toggle"
```

### Task 2: Implement the minimum controlled SwiftUI toggle

**Files:**
- Modify: `Sources/kongshan/MainWindowView.swift`

- [ ] **Step 1: Add visibility state and bind the split view**

```swift
@State private var selection: SidebarPage? = .dashboard
@State private var columnVisibility: NavigationSplitViewVisibility = .all

NavigationSplitView(columnVisibility: $columnVisibility) {
```

- [ ] **Step 2: Remove the system item at the sidebar-owner scope**

Place this directly on the sidebar `List`, after its existing sidebar styling and width modifiers:

```swift
.toolbar(removing: .sidebarToggle)
```

- [ ] **Step 3: Add the sole fixed leading toolbar button**

Apply this to the `NavigationSplitView` before `.navigationTitle("kongshan")`:

```swift
.toolbar {
    ToolbarItem(placement: .navigation) {
        Button {
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        } label: {
            Image(systemName: "sidebar.left")
        }
        .help(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏")
        .accessibilityLabel(columnVisibility == .detailOnly ? "显示侧边栏" : "隐藏侧边栏")
    }
}
```

- [ ] **Step 4: Run focused and app tests for GREEN**

Run: `swift test --filter MainWindowToolbarTests/testMainWindowUsesOneFixedSidebarToggle`

Expected: 1 test passed, 0 failures.

Run: `swift test --filter KongshanAppTests`

Expected: all App tests pass; the existing opt-in render snapshot may remain skipped.

- [ ] **Step 5: Record GREEN and commit**

```bash
git add Sources/kongshan/MainWindowView.swift docs/progress/SESSION_LOG.md
git commit -m "fix(ui): pin sidebar toggle to leading toolbar"
```

### Task 3: Build and install 0.1.22 for acceptance

**Files:**
- Modify: `VERSION` through the existing build script.
- Generate ignored artifacts: `dist/kongshan.app`, `dist/kongshan-0.1.22.dmg`.

- [ ] **Step 1: Run full verification and its single release build**

Run: `zsh scripts/verify_m4.sh`

Expected: `verify_m3.sh` runs the full tests and `build_app.sh` once, changing `VERSION` from 0.1.21 to 0.1.22 and producing build 122; release arm64/signature/performance gates pass, and the final line is `M4 automated verification passed`.

- [ ] **Step 2: Validate the generated version instead of rebuilding**

Run:

```bash
test "$(tr -d '[:space:]' < VERSION)" = 0.1.22
test "$(defaults read "$PWD/dist/kongshan.app/Contents/Info" CFBundleShortVersionString)" = 0.1.22
test "$(defaults read "$PWD/dist/kongshan.app/Contents/Info" CFBundleVersion)" = 122
```

Expected: all three checks pass. Do not call `build_app.sh` again without `KONGSHAN_KEEP_VERSION=1`, because its default behavior increments the patch version.

- [ ] **Step 3: Create and verify the DMG**

Run: `zsh scripts/make_dmg.sh`

Expected: `dist/kongshan-0.1.22.dmg` exists and `hdiutil verify dist/kongshan-0.1.22.dmg` succeeds.

- [ ] **Step 4: Install one discoverable application without touching proxy state**

Run read-only guards first:

```bash
support="$HOME/Library/Application Support/kongshan"
test ! -e "$support/proxy-recovery.json"
test ! -e "$support/dns-recovery.json"
test ! -e "$support/tun-recovery.json"
! pgrep -x sing-box
```

Then terminate only the exact installed UI process, stage the verified app under `/Applications`, move the old installed app to a versioned Trash path, move the staged 0.1.22 app to `/Applications/kongshan.app`, unregister the ignored dist and Trash copies with `lsregister -u`, register the installed app with `lsregister -f`, and run `open /Applications/kongshan.app`.

Expected: `/Applications/kongshan.app` reports 0.1.22/build 122, passes `codesign --verify --deep --strict`, and is the only Spotlight result for bundle ID `com.kaysen.kongshan`.

- [ ] **Step 5: Keep only the latest DMG and record release evidence**

Copy the verified worktree DMG to `/Users/kaysen/workspace/mac/代理软件/dist/kongshan-0.1.22.dmg`, move the previous 0.1.21 DMG and worktree app/DMG build copies to versioned Trash paths, record `shasum -a 256`, and append build/install evidence to `docs/progress/SESSION_LOG.md`.

- [ ] **Step 6: Commit the version and release state**

```bash
git add VERSION docs/progress/SESSION_LOG.md
git commit -m "release: 0.1.22 fixed sidebar toggle position"
```

### Task 4: Final verification and durable handoff

**Files:**
- Modify: `docs/HANDOFF.md`
- Modify: `docs/PROGRESS.md`
- Modify: `docs/NEXT_STEPS.md`
- Modify: `docs/progress/SESSION_LOG.md`

- [ ] **Step 1: Verify branch, installed product, and single-copy state**

Run the current-state checks for branch cleanliness, installed version/build/signature/process path, Spotlight bundle results, workspace `.app` copies, latest DMG count, and main HEAD.

Expected: `fix/sidebar-toggle` is clean after the final records commit; main remains unmerged; one installed App and one 0.1.22 DMG remain.

- [ ] **Step 2: Update all project records**

Record completed files, RED/GREEN/full-test results, installed artifact, current acceptance state, known CLI titlebar limitation, and the next action: user visually validates the fixed position before merge.

- [ ] **Step 3: Commit records**

```bash
git add docs/HANDOFF.md docs/PROGRESS.md docs/NEXT_STEPS.md docs/progress/SESSION_LOG.md
git commit -m "docs: hand off 0.1.22 for acceptance"
```

- [ ] **Step 4: Re-run `git diff --check` and final state checks**

Expected: no whitespace errors, clean branch, main unchanged, installed 0.1.22 process running from `/Applications/kongshan.app`.
