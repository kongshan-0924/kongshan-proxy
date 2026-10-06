import Foundation
import SystemConfiguration

/// 网络位置切换的监听。
///
/// 切换位置时 configd 会改写 `Setup:/`（当前位置的名字）并重建全局 IPv4 / DNS 状态；任一变化都回调，
/// 由调用方读一次当前位置的 ID 判定是否真的换了位置（读偏好很便宜，误报只是多读一次）。
/// 不论是否在接管都要听：没在接管时，切回某个位置正是还原它上次留下的设置的时机。
public final class NetworkLocationObserver: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "kongshan.network-location-observer", qos: .utility)
    private let lock = NSLock()
    private var store: SCDynamicStore?

    public init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    /// 开始监听；系统拒绝时返回 false（调用方照常工作，只是少了这道兜底）。
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard store == nil else { return true }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkLocationObserver>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let created = SCDynamicStoreCreate(nil, "kongshan.network-location-observer" as CFString, callback, &context) else {
            return false
        }
        let keys = ["Setup:/", "State:/Network/Global/IPv4", "State:/Network/Global/DNS"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(created, keys, nil),
              SCDynamicStoreSetDispatchQueue(created, queue) else {
            return false
        }
        store = created
        return true
    }

    /// 停止监听。先摘掉派发队列，回调就不会再触达已释放的 `self`。
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if let store {
            SCDynamicStoreSetDispatchQueue(store, nil)
        }
        store = nil
    }
}
