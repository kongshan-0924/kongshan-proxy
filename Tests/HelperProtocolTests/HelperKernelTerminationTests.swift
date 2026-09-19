import Darwin
import XCTest
@testable import HelperProtocol

/// 停内核的信号升级。只发一个 SIGINT 是不够的——睡眠唤醒后内核会丢掉 utun 设备进入假死态，
/// SIGINT 杀不掉；进程赖着不走就会让下一次开 TUN 被 `kernel already running` 顶回来，
/// 用户表现为"休眠后内核崩了、再也起不来"。
final class HelperKernelTerminationTests: XCTestCase {
    /// 记录实际发出的信号序列。
    private final class Recorder {
        var sent: [Int32] = []
        var aliveUntilSignal: Int32?     // 收到这个信号后才死；nil = 一直活着
        var died = false

        func isAlive(_ pid: Int32) -> Bool { !died }
        func send(_ pid: Int32, _ signalNumber: Int32) {
            sent.append(signalNumber)
            if let trigger = aliveUntilSignal, signalNumber == trigger { died = true }
        }
    }

    private func run(_ recorder: Recorder) -> Bool {
        HelperKernelTermination.terminate(
            pid: 4_242,
            isAlive: recorder.isAlive,
            send: recorder.send,
            waitStep: {},
            stepsPerSignal: 3
        )
    }

    /// 正常情况：SIGINT 就走了，不该继续升级。
    func testStopsAtSIGINTWhenProcessExits() {
        let recorder = Recorder()
        recorder.aliveUntilSignal = SIGINT
        XCTAssertTrue(run(recorder))
        XCTAssertEqual(recorder.sent, [SIGINT], "已经退出了还继续发信号")
    }

    /// 假死：SIGINT 无效 → 必须升级到 SIGTERM。
    func testEscalatesToSIGTERMWhenSIGINTIgnored() {
        let recorder = Recorder()
        recorder.aliveUntilSignal = SIGTERM
        XCTAssertTrue(run(recorder))
        XCTAssertEqual(recorder.sent, [SIGINT, SIGTERM])
    }

    /// 彻底卡死：必须一路升级到 SIGKILL，绝不能"发完 SIGINT 就当成功"。
    func testEscalatesToSIGKILLWhenBothIgnored() {
        let recorder = Recorder()
        recorder.aliveUntilSignal = SIGKILL
        XCTAssertTrue(run(recorder))
        XCTAssertEqual(recorder.sent, [SIGINT, SIGTERM, SIGKILL])
    }

    /// 连 SIGKILL 都没让它消失（僵尸/内核态卡死）→ 必须**如实返回失败**，
    /// 否则助手会误报"已停止"，App 下次启动再撞 `kernel already running`。
    func testReportsFailureWhenProcessNeverDies() {
        let recorder = Recorder()
        recorder.aliveUntilSignal = nil
        XCTAssertFalse(run(recorder))
        XCTAssertEqual(recorder.sent, [SIGINT, SIGTERM, SIGKILL])
    }

    /// 进程本来就已经不在了：一个信号都不该发。
    func testSendsNothingWhenAlreadyGone() {
        let recorder = Recorder()
        recorder.died = true
        XCTAssertTrue(run(recorder))
        XCTAssertTrue(recorder.sent.isEmpty)
    }
}
