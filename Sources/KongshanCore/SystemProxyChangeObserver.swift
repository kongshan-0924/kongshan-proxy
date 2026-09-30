import Foundation
import SystemConfiguration

/// 系统代理设置变化的监听。
///
/// **为什么要有它**：「没在接管时代理仍指向 kongshan 端口」的残留，原先只在启动、换网、停止、
/// 手动自检这几个时点清扫。残留若在这些时点之外出现，就一直留着——真机 2026-09-29 23:32 重启后，
/// Wi-Fi 与雷雳网桥的代理又指回 36815（重启前 23:26、23:27 两次自检都正常，来源因系统日志已轮转无从查证），
/// 直到次日 08:02 用户手动自检才清掉；其间遵循系统代理的应用都连向一个没人监听的端口。
///
/// 这里订阅 SCDynamicStore：全局代理状态 `State:/Network/Global/Proxies`，以及每个网络服务的
/// 代理配置 `Setup:/Network/Service/<id>/Proxies`（`networksetup` 写入并应用后会更新）。
/// 只负责「变了」这一个信号；清不清、清哪些由调用方按接管状态决定。
public final class SystemProxyChangeObserver: @unchecked Sendable {
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "kongshan.proxy-change-observer", qos: .utility)
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
            Unmanaged<SystemProxyChangeObserver>.fromOpaque(info).takeUnretainedValue().onChange()
        }
        guard let created = SCDynamicStoreCreate(nil, "kongshan.proxy-change-observer" as CFString, callback, &context) else {
            return false
        }
        let keys = ["State:/Network/Global/Proxies"] as CFArray
        let patterns = ["Setup:/Network/Service/[^/]+/Proxies"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(created, keys, patterns),
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
