import Foundation

/// 通知观察者令牌的持有者，析构时统一摘除。
///
/// 为什么需要它：`@MainActor` 类的 `deinit` 在 Swift 6 里是 nonisolated 的，
/// 碰不到 actor 隔离的、且类型非 Sendable 的属性（`NSObjectProtocol` 就是），
/// 所以没法在 `AppState.deinit` 里直接摘观察者。
///
/// AppState 与 App 同生命周期，不摘也不会真泄漏。但留着一个"注册了却从不注销"的对象
/// 是个陷阱：将来若有谁在别处再造一个 AppState（测试夹具、SwiftUI 预览、多窗口重构），
/// 观察者会一层层叠上去，每次唤醒/遮挡通知都被多个已废弃实例接住。
final class NotificationObserverBag {
    private var entries: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func add(to center: NotificationCenter, _ token: NSObjectProtocol) {
        entries.append((center, token))
    }

    deinit {
        for entry in entries {
            entry.center.removeObserver(entry.token)
        }
    }
}
