import Foundation
import XCTest
@testable import KongshanCore
@testable import kongshan

/// 告警取证的接线回归。
///
/// 存在的理由是一次真实的丢证：2026-09-01 排查发现 App 累计烧掉 21 小时 CPU（全机第二），
/// 而唯一记录在案的异常只占 0.20%——其余 99.8% 无从归因，因为消息页的「全部清除」
/// 把 `runtime-events.json` 整体抹掉了。这条链路（告警 → 存档 + 提醒）断掉不会有任何报错，
/// 只会安静地不再留证，因此必须有回归覆盖。
@MainActor
final class DiagnosticsArchiveWiringTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "kongshan-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeState(
        root: URL,
        journal: DiagnosticsJournal,
        notifier: any NotificationSending
    ) -> AppState {
        AppState(
            storage: Storage(rootDirectory: root),
            singBoxProcess: SingBoxProcess(binaryURL: URL(fileURLWithPath: "/usr/bin/false")),
            notificationSender: notifier,
            diagnosticsJournal: journal,
            automaticallyInitialize: false
        )
    }

    /// 存档是异步落盘的，轮询到出现为止；超时即判失败。
    private func waitForRecords(
        _ journal: DiagnosticsJournal,
        count: Int,
        timeout: TimeInterval = 3
    ) async -> [DiagnosticsJournal.Record] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let records = journal.records()
            if records.count >= count { return records }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return journal.records()
    }

    func testWarningIsArchivedAndAnnounced() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root)
        let notifier = FakeNotifier()
        let state = makeState(root: root, journal: journal, notifier: notifier)

        state.recordRuntimeEvent(level: .warning, title: "CPU 占用已回落", detail: "平均 24.2%")

        let records = await waitForRecords(journal, count: 1)
        XCTAssertEqual(records.map(\.title), ["CPU 占用已回落"])
        XCTAssertEqual(records.first?.level, "warning")
        XCTAssertEqual(records.first?.detail, "平均 24.2%")

        let sent = await notifier.messages(waitingFor: 1)
        XCTAssertEqual(sent.map(\.title), ["CPU 占用已回落"])
        XCTAssertEqual(sent.first?.body, "平均 24.2%")
    }

    /// 日常事件不进存档也不提醒——否则「系统已唤醒」这类信息会把存档和通知都淹掉，
    /// 存档一旦变噪音，就和被清空没区别了。
    func testInfoEventsAreNeitherArchivedNorAnnounced() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root)
        let notifier = FakeNotifier()
        let state = makeState(root: root, journal: journal, notifier: notifier)

        state.recordRuntimeEvent(title: "系统已唤醒", detail: "正在检查内核与接管")
        try? await Task.sleep(for: .milliseconds(300))

        let records = journal.records()
        XCTAssertTrue(records.isEmpty)
        let sent = await notifier.snapshot()
        XCTAssertTrue(sent.isEmpty)
    }

    /// **本次修复的核心**：「全部清除」只清界面列表，不得动取证存档。
    func testClearRuntimeEventsDoesNotTouchTheArchive() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root)
        let state = makeState(root: root, journal: journal, notifier: FakeNotifier())

        state.recordRuntimeEvent(level: .error, title: "内核意外退出", detail: "signal 9")
        state.recordRuntimeEvent(level: .warning, title: "DNS 解析持续超时", detail: "10 次")
        _ = await waitForRecords(journal, count: 2)

        state.clearRuntimeEvents()

        XCTAssertTrue(state.runtimeEvents.isEmpty, "界面列表要清空")
        let records = journal.records()
        XCTAssertEqual(
            records.map(\.title),
            ["内核意外退出", "DNS 解析持续超时"],
            "取证存档必须完好——这正是 2026-09-01 丢掉 99.8% 证据的那一步"
        )
    }

    /// 同一标题在冷却期内只提醒一次，但**每一条都要进存档**。
    /// 提醒是给人看的、可以合并；存档是给排查用的，合并就等于丢数据。
    func testRepeatedTitlesAreThrottledForNotificationsButAllArchived() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root)
        let notifier = FakeNotifier()
        let state = makeState(root: root, journal: journal, notifier: notifier)

        for index in 0..<4 {
            state.recordRuntimeEvent(level: .warning, title: "当前配置应用失败，已回滚", detail: "第 \(index) 次")
        }
        let records = await waitForRecords(journal, count: 4)
        XCTAssertEqual(records.count, 4, "四条全部进存档")

        try? await Task.sleep(for: .milliseconds(200))
        let sent = await notifier.snapshot()
        XCTAssertEqual(sent.count, 1, "冷却期内只提醒一次")
    }

    /// 通知可能因为未授权而失败。**存档不能跟着一起丢**——
    /// 恰恰是没人看着的时候，存档才最重要。
    func testArchiveSurvivesNotificationFailure() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root)
        let state = makeState(root: root, journal: journal, notifier: FailingNotifier())

        state.recordRuntimeEvent(level: .error, title: "启用系统代理失败", detail: "exit 8")

        let records = await waitForRecords(journal, count: 1)
        XCTAssertEqual(records.map(\.title), ["启用系统代理失败"])
    }

    private func cpuReport() -> CPUAnomalyReport {
        CPUAnomalyReport(
            phase: .ended,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            observedUntil: Date(timeIntervalSince1970: 1_700_000_623),
            averagePercent: 24.2,
            peakPercent: 80.4,
            userShare: 0.97,
            cpuSecondsConsumed: 151.1,
            peakResidentBytes: 186_646_528,
            peakThreadCount: 12,
            mainThreadShare: 0.96
        )
    }

    /// CPU 异常记录里此前只说得出「主线程在渲染」，说不出在渲染**哪一页**，
    /// 于是 2026-09-01 那 21 小时无法进一步定位。页面与活跃订阅都要写进去。
    func testVisiblePageAndActiveSubscriptionsAreRecordedForAttribution() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root)
        let state = makeState(root: root, journal: journal, notifier: FakeNotifier())

        state.noteVisiblePage("连接")
        state.record(cpuReport(), logLinesInWindow: 0)
        let records = await waitForRecords(journal, count: 1)
        let detail = try? XCTUnwrap(records.first?.detail)
        XCTAssertEqual(records.first?.title, "CPU 占用已回落")
        XCTAssertTrue(detail?.contains("当前页面 连接") == true, "实际：\(detail ?? "nil")")
        XCTAssertTrue(detail?.contains("活跃订阅") == true, "实际：\(detail ?? "nil")")

        // 窗口关闭时要记成"无窗口"，而不是留着上一页的陈旧值误导排查。
        state.noteVisiblePage(nil)
        state.record(cpuReport(), logLinesInWindow: 0)
        let after = await waitForRecords(journal, count: 2)
        XCTAssertTrue(after.last?.detail?.contains("当前页面 无窗口") == true)
    }

    /// 存档必须在 `recordRuntimeEvent` 返回时就已落盘，**不能等异步任务**。
    /// `finishSelfDiagnostics()` 在退出流程里记下最后一段异常——「一直烧到用户退出」
    /// 那类场景唯一的证据就是它；交给 detached Task 去写，进程正好这时结束就没了。
    func testArchiveIsWrittenSynchronouslySoExitPathCannotLoseIt() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root)
        let state = makeState(root: root, journal: journal, notifier: FakeNotifier())

        state.recordRuntimeEvent(level: .warning, title: "CPU 占用已回落", detail: "退出前最后一段")

        // 没有任何 await / sleep：返回时就必须已经在磁盘上。
        XCTAssertEqual(journal.records().map(\.title), ["CPU 占用已回落"])
    }

    /// 存档与提醒刻意不对称：自愈型事件（内核崩溃后一秒内自动重启）和
    /// 已经另发过通知的事件不该再弹一次，但**存档必须照留**——
    /// 排查「为什么内核反复重启」时靠的正是那些记录。
    func testSilencedEventsAreStillArchived() async {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticsJournal(directory: root)
        let notifier = FakeNotifier()
        let state = makeState(root: root, journal: journal, notifier: notifier)

        state.recordRuntimeEvent(
            level: .warning,
            title: "检测到内核意外退出",
            detail: "正在自动重启",
            announce: false
        )

        XCTAssertEqual(journal.records().map(\.title), ["检测到内核意外退出"], "存档不受影响")
        try? await Task.sleep(for: .milliseconds(200))
        let sent = await notifier.snapshot()
        XCTAssertTrue(sent.isEmpty, "自愈型事件不该弹窗")
    }

    /// 界面上要能告诉用户存档在哪，否则「全部清除」看起来就是不可逆的销毁。
    func testArchivePathIsShownWithTildeAbbreviation() {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = makeState(
            root: root,
            journal: DiagnosticsJournal(directory: root),
            notifier: FakeNotifier()
        )
        XCTAssertTrue(state.diagnosticsArchivePath.hasSuffix("diagnostics.ndjson"))
        XCTAssertFalse(
            state.diagnosticsArchivePath.contains(FileManager.default.homeDirectoryForCurrentUser.path()),
            "界面上不铺开完整家目录"
        )
    }
}

private actor FakeNotifier: NotificationSending {
    private(set) var sent: [(title: String, body: String)] = []

    func send(title: String, body: String) async throws {
        sent.append((title, body))
    }

    func snapshot() -> [(title: String, body: String)] { sent }

    func messages(waitingFor count: Int, timeout: TimeInterval = 3) async -> [(title: String, body: String)] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sent.count >= count { return sent }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return sent
    }
}

private struct FailingNotifier: NotificationSending {
    struct Denied: Error {}
    func send(title: String, body: String) async throws { throw Denied() }
}
