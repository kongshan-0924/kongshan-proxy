# kongshan Network Observability and Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver one acceptance build that adds real exit diagnostics, node metadata, live connection rates, automatic fastest-node selection, per-app routing, menu-bar rates, and backup/restore.

**Architecture:** Pure parsing, rate calculation, DNS assessment, and backup validation live in `KongshanCore` so they can be test-driven. `AppState` owns side effects and exposes observable state; existing SwiftUI pages are extended without adding navigation destinations or duplicate runtime streams.

**Tech Stack:** Swift 6, SwiftUI/AppKit on macOS 14+, Foundation URLSession, existing Clash-compatible WebSocket API, XCTest, sing-box configuration validation.

---

### Task 1: Exit IP and DNS diagnostic domain model

**Files:**
- Create: `Sources/KongshanCore/ExitDiagnostics.swift`
- Test: `Tests/KongshanCoreTests/ExitDiagnosticsTests.swift`

- [ ] Write failing tests for Mullvad JSON decoding, resolver deduplication, expected DoH provider matching, same-country resolution, possible leak, and indeterminate empty results.
- [ ] Run `swift test --filter ExitDiagnosticsTests` and confirm missing types fail compilation.
- [ ] Implement `ExitIPInfo`, `DNSResolverInfo`, `DNSLeakAssessment`, and the pure `DNSLeakAnalyzer.assess(exit:resolvers:remoteDoH:)`.
- [ ] Re-run the focused tests and confirm they pass.

### Task 2: Exit diagnostic service and dashboard UI

**Files:**
- Create: `Sources/kongshan/ExitDiagnosticsService.swift`
- Modify: `Sources/kongshan/AppState.swift`
- Modify: `Sources/kongshan/DashboardView.swift`
- Test: `Tests/KongshanAppTests/ExitDiagnosticsServiceTests.swift`

- [ ] Write URLProtocol-backed failing tests for `/config`, `/json`, unique resolver queries, HTTP failure, and preserving the latest success in `AppState`.
- [ ] Run `swift test --filter ExitDiagnosticsServiceTests` and confirm expected failures.
- [ ] Implement a 10-second service request timeout, three concurrent resolver samples, deduplication, and injectable service factory.
- [ ] Replace Google/GitHub connectivity state with exit information, DNS assessment, refresh state, and last error.
- [ ] Replace the dashboard connectivity card with IP/location/organization/DNS status and refresh/detect actions.
- [ ] Run focused tests and `swift test`.
- [ ] Append the completed phase to `docs/progress/SESSION_LOG.md`.

### Task 3: Node flag, region, and multiplier metadata

**Files:**
- Create: `Sources/KongshanCore/NodeNameMetadata.swift`
- Modify: `Sources/kongshan/PolicyGroupsView.swift`
- Modify: `Sources/kongshan/MenuBarView.swift`
- Test: `Tests/KongshanCoreTests/NodeNameMetadataTests.swift`

- [ ] Write failing tests for explicit flags, JP/Japan/日本, Hong Kong, Los Angeles, Fiji, `3x`, `3×`, `3倍`, decimals, and names without metadata.
- [ ] Run `swift test --filter NodeNameMetadataTests` and confirm missing parser failures.
- [ ] Implement a deterministic longest-keyword parser and normalized multiplier display.
- [ ] Add flag and highlighted multiplier badges to node cards and compact flags to menu items without changing stored node names.
- [ ] Run focused tests and `swift test`.
- [ ] Append the phase record.

### Task 4: Live per-connection rates and sorting

**Files:**
- Create: `Sources/KongshanCore/ConnectionRateTracker.swift`
- Modify: `Sources/kongshan/AppState.swift`
- Modify: `Sources/kongshan/ConnectionsView.swift`
- Test: `Tests/KongshanCoreTests/ConnectionRateTrackerTests.swift`

- [ ] Write failing tests for first sample zero, byte delta/time rate, reset to zero, removed connections, and total-rate calculation.
- [ ] Run `swift test --filter ConnectionRateTrackerTests` and confirm missing types fail.
- [ ] Implement `ConnectionLiveDetail` and `ConnectionRateTracker` with injected timestamps.
- [ ] Apply the tracker to each WebSocket connection snapshot and reset it on stop/close.
- [ ] Add total rate badges, per-row B/s plus cumulative bytes, and default/total/upload/download sorting.
- [ ] Run focused tests and `swift test`.
- [ ] Append the phase record.

### Task 5: Test and automatically select fastest

**Files:**
- Modify: `Sources/kongshan/AppState.swift`
- Modify: `Sources/kongshan/PolicyGroupsView.swift`
- Modify: `Sources/kongshan/MenuBarView.swift`
- Test: `Tests/KongshanAppTests/AppStateTests.swift`

- [ ] Write failing AppState tests proving the lowest successful delay in the selected selector group is chosen and total failure preserves selection.
- [ ] Run the focused AppState tests and confirm failure.
- [ ] Extract the existing all-delay body to return measured results, add `testAndSelectFastest(in:)`, and call existing `select(optionName:in:)` only after success.
- [ ] Add the one-click button to the proxy page and menu, with in-progress disabling.
- [ ] Run focused tests and `swift test`.
- [ ] Append the phase record.

### Task 6: Per-application routing UI and node targets

**Files:**
- Modify: `Sources/KongshanCore/ConfigGenerator.swift`
- Modify: `Sources/kongshan/AppState.swift`
- Modify: `Sources/kongshan/RoutingView.swift`
- Test: `Tests/KongshanCoreTests/RoutingConfigTests.swift`
- Test: `Tests/KongshanAppTests/AppStateTests.swift`

- [ ] Write failing config tests that allow a process_name proxy rule to target a generated node tag and reject an unavailable outbound target.
- [ ] Run focused tests and confirm the node-target case fails.
- [ ] Validate custom proxy targets against generated groups plus node tags before writing route rules.
- [ ] Add AppState helpers to enumerate regular running apps and to add/remove process rules through `applyRoutingSettings`.
- [ ] Add a compact per-app rule editor and existing-rule list above subscription rules.
- [ ] Run config generation through the bundled sing-box check and run `swift test`.
- [ ] Append the phase record.

### Task 7: Menu-bar real-time rate without stream conflicts

**Files:**
- Modify: `Sources/kongshan/AppState.swift`
- Modify: `Sources/kongshan/KongshanApp.swift`
- Modify: `Sources/kongshan/MenuBarView.swift`
- Test: `Tests/KongshanAppTests/AppStateTests.swift`

- [ ] Write failing tests that dashboard and menu consumers share one monitor, removing dashboard keeps monitoring alive, and runtime stop cancels it.
- [ ] Run focused tests and confirm the visibility Bool cannot satisfy them.
- [ ] Replace `isDashboardVisible` with an idempotent consumer set; register the persistent menu label consumer and retain existing reconnect backoff.
- [ ] Render compact `↓ / ↑` speed beside the menu-bar icon and full values at the top of the dropdown.
- [ ] Run focused tests and `swift test`.
- [ ] Append the phase record.

### Task 8: Versioned configuration and settings backup

**Files:**
- Create: `Sources/KongshanCore/KongshanBackup.swift`
- Create: `Sources/kongshan/BackupDocument.swift`
- Modify: `Sources/kongshan/AppState.swift`
- Modify: `Sources/kongshan/MainWindowView.swift`
- Test: `Tests/KongshanCoreTests/KongshanBackupTests.swift`
- Test: `Tests/KongshanAppTests/AppStateTests.swift`

- [ ] Write failing tests for round-trip, unsupported version, malformed payload, and no state mutation on failed import.
- [ ] Run focused tests and confirm missing backup API failures.
- [ ] Implement version 1 Codable payload and `FileDocument` JSON integration.
- [ ] Export subscriptions, manual nodes, persisted settings, and routing settings; import only while stopped, validate all data, persist atomically, and refresh derived subscription caches.
- [ ] Add export/import buttons and the subscription-credential warning to Settings → More.
- [ ] Run focused tests and `swift test`.
- [ ] Append the phase record.

### Task 9: Release verification and single-product handoff

**Files:**
- Modify: `VERSION`
- Modify: `docs/HANDOFF.md`
- Modify: `docs/PROGRESS.md`
- Modify: `docs/NEXT_STEPS.md`
- Modify: `docs/progress/SESSION_LOG.md`

- [ ] Run `swift test` and fix every failure.
- [ ] Run the repository release verification script once so version/build, arm64 binary, signing, DMG, performance and privacy gates are all checked.
- [ ] Inspect the built app on dashboard, proxy, connections, rules, settings, and menu bar; verify sidebar toggle remains single and fixed.
- [ ] Replace the installed acceptance app with the verified build, remove older app/DMG build copies through the existing recoverable release workflow, and launch `/Applications/kongshan.app`.
- [ ] Verify installed version, PID executable path, code signature, one Spotlight app result, one canonical DMG, and no mounted stale DMG.
- [ ] Update all required handoff records with changed files, tests, current state, risks, next step, and takeover instructions.
- [ ] Commit the release and documentation on `codex/network-observability-batch`; keep main unchanged for user acceptance.

