import XCTest

/// 助手主程序的**并发形态**约束。
///
/// 背景（真机实证，0.1.45 及之前）：`Sources/KongshanHelper/main.swift` 的顶层代码在
/// Swift 6 语言模式下是 `@MainActor` 隔离的。当时用 `DispatchSource` 接管信号，又挂了一个
/// 30 秒的自愈定时器，两个 handler 都跑在自建的 `signalQueue` 上，闭包一碰顶层状态
/// （`state` / `listenFD`），Swift 运行时的执行器检查就直接 SIGTRAP——**编译期零提示**。
///
/// 症状极具迷惑性：助手每 30 秒（正好是定时器周期）崩一次被 launchd 拉起，TUN 表面照常
/// 工作（内核是独立进程，重启后的助手靠 `adoptOrphanKernel()` 重新认领），但
/// `checkClientLiveness()` 从未真正执行过一次，`clientPID` 每轮重启即丢失。
/// 8 小时攒了 42 份 `EXC_BREAKPOINT` 报告，栈顶是
/// `dispatch_assert_queue_fail ← swift_task_isCurrentExecutor ← closure #2 in <top-level>`。
///
/// 修法是把并发整个去掉：C 信号处理器 + accept 循环内轮询，助手回归单线程。
/// 这条测试钉死"别再把闭包交给 dispatch 执行"——单元测试跑不到 root 助手的运行时行为，
/// 源码层守卫是这里唯一能自动化的防线（真机验证靠"运行 N 分钟无新增崩溃报告"）。
final class HelperMainIsolationTests: XCTestCase {
    func testHelperMainHasNoDispatchExecutedClosures() throws {
        // 只扫代码，注释要跳过——上面那段"为什么不能用 dispatch"的说明本身就含这些词。
        let code = try helperMainSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let marker = line.range(of: "//") else { return line }
                return line[line.startIndex..<marker.lowerBound]
            }
            .joined(separator: "\n")

        for banned in ["DispatchSource", "DispatchQueue", "setEventHandler", "DispatchWorkItem"] {
            XCTAssertFalse(
                code.contains(banned),
                """
                KongshanHelper/main.swift 不得使用 \(banned)。
                顶层代码是 @MainActor 隔离的，交给 dispatch 队列执行的闭包一碰顶层状态就会
                在运行时 SIGTRAP，且编译期没有任何提示。改用 C 信号处理器 + accept 循环轮询。
                """
            )
        }
    }

    func testHelperUsesCSignalHandlerAndMonotonicPolling() throws {
        let source = try helperMainSource()

        // 信号必须走 @convention(c) 处理器，标志位必须显式脱离 actor 隔离。
        XCTAssertTrue(source.contains("@convention(c) (Int32) -> Void"))
        XCTAssertTrue(source.contains("nonisolated(unsafe) static var terminationRequested"))
        XCTAssertTrue(source.contains("signal(SIGTERM, onTerminationSignal)"))
        XCTAssertTrue(source.contains("signal(SIGINT, onTerminationSignal)"))

        // 自愈必须挂在 accept 循环里，并用单调时钟计间隔。
        // wall clock 在睡眠唤醒后会跳，会把"睡了 8 小时"误判成"App 失联 8 小时"。
        XCTAssertTrue(source.contains("CLOCK_MONOTONIC"))
        XCTAssertTrue(source.contains("checkClientLiveness()"))
        XCTAssertFalse(
            source.contains("Date()"),
            "自愈间隔不得用 wall clock：睡眠唤醒后系统时间会跳。"
        )
    }

    private func helperMainSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HelperProtocolTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 包根
            .appending(path: "Sources/KongshanHelper/main.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
