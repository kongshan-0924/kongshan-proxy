import Foundation
import Network

/// 一次性读取当前网络路径是否可用，不常驻监听。
///
/// 用在「定时任务触发时要不要现在就联网」：Mac 睡眠时每隔十几分钟会有一次两秒的暗唤醒，
/// 计时器照常触发，但网络多半没起来，URLSession 立刻报「The Internet connection appears to be offline」。
/// 2026-09-19 真机：一夜下来日志里全是订阅 / 规则集的离线失败与「通知未发送」。
public enum NetworkPathProbe {
    /// 拿不到路径（极少见）时按「可用」处理：探测失败不该把正常的更新拦下来。
    public static func isSatisfied(timeout: Duration = .seconds(1)) async -> Bool {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "kongshan.network-path-probe")
        let status: NWPath.Status? = await withCheckedContinuation { continuation in
            let gate = OnceGate(continuation)
            monitor.pathUpdateHandler = { path in gate.resume(path.status) }
            monitor.start(queue: queue)
            let components = timeout.components
            let milliseconds = Int(components.seconds) * 1_000 + Int(components.attoseconds / 1_000_000_000_000_000)
            queue.asyncAfter(deadline: .now() + .milliseconds(max(milliseconds, 1))) {
                gate.resume(nil)
            }
        }
        monitor.cancel()
        return status.map { $0 == .satisfied } ?? true
    }

    private final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<NWPath.Status?, Never>?

        init(_ continuation: CheckedContinuation<NWPath.Status?, Never>) {
            self.continuation = continuation
        }

        func resume(_ value: NWPath.Status?) {
            let pending: CheckedContinuation<NWPath.Status?, Never>? = lock.withLock {
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: value)
        }
    }
}
