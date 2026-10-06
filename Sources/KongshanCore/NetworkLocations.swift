import Foundation
import SystemConfiguration

/// macOS 的「网络位置」（Apple 菜单 → 位置；系统设置 → 网络 → … → 位置）。
///
/// 存在的理由：每个位置有**各自一套**网络服务，代理与 DNS 按位置分别保存；`networksetup` 只能读写
/// **当前位置**。原先的接管快照只按服务名记，不记位置——真机 2026-10-06 23:29:56 用户在接管中
/// 从「自动」切到另一个手动指定网关与 DNS 的位置，5 秒后停止接管：还原把「自动」位置里拍的快照按同名写进了新位置
/// （Wi-Fi 的 DNS 被清空，系统随即判 Wi-Fi 不可用），「自动」里的代理与 TUN DNS 却没人还原；
/// 自检只看当前位置，报「接管残留：ok」。重启无效，切回「自动」手工清掉才恢复。
public struct NetworkLocation: Codable, Equatable, Hashable, Sendable {
    /// `Sets/<ID>` 里的 ID，跨改名稳定。
    public let id: String
    /// 用户起的名字；系统默认位置存的是 `Automatic`，界面上显示「自动」。
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// 给用户看的名字。
    public var displayName: String { Self.displayName(for: name) }

    public static func displayName(for name: String) -> String {
        name == "Automatic" ? "自动" : name
    }
}

/// 某个位置里一个网络服务的代理与 DNS（从系统网络偏好只读得来）。
public struct NetworkLocationService: Equatable, Sendable {
    public let location: NetworkLocation
    public let name: String
    public let enabled: Bool
    /// 手动填写的 DNS；空表示跟随 DHCP。
    public let dnsServers: [String]
    public let http: ProxyEndpointState
    public let https: ProxyEndpointState
    public let socks: ProxyEndpointState

    public init(
        location: NetworkLocation,
        name: String,
        enabled: Bool,
        dnsServers: [String],
        http: ProxyEndpointState,
        https: ProxyEndpointState,
        socks: ProxyEndpointState
    ) {
        self.location = location
        self.name = name
        self.enabled = enabled
        self.dnsServers = dnsServers
        self.http = http
        self.https = https
        self.socks = socks
    }
}

/// 全部位置及其服务设置的一次只读快照。
public struct NetworkLocationsSnapshot: Equatable, Sendable {
    public let current: NetworkLocation?
    public let locations: [NetworkLocation]
    public let services: [NetworkLocationService]

    public init(current: NetworkLocation?, locations: [NetworkLocation], services: [NetworkLocationService]) {
        self.current = current
        self.locations = locations
        self.services = services
    }

    public func location(withID id: String) -> NetworkLocation? {
        locations.first { $0.id == id }
    }

    /// 解析系统网络偏好（`/Library/Preferences/SystemConfiguration/preferences.plist`）的三个顶层键。
    /// 纯函数，便于用真实结构的样本测试。
    public static func parse(currentSet: String?, sets: [String: Any], networkServices: [String: Any]) -> NetworkLocationsSnapshot {
        var locations: [NetworkLocation] = []
        var services: [NetworkLocationService] = []
        for setID in sets.keys.sorted() {
            guard let set = sets[setID] as? [String: Any] else { continue }
            let location = NetworkLocation(id: setID, name: set["UserDefinedName"] as? String ?? setID)
            locations.append(location)
            let network = set["Network"] as? [String: Any]
            let links = network?["Service"] as? [String: Any] ?? [:]
            for linkID in links.keys.sorted() {
                let link = links[linkID] as? [String: Any]
                // 位置里的服务项是指向 `/NetworkServices/<ID>` 的链接；没有链接时 ID 相同。
                let target = (link?["__LINK__"] as? String).map { String($0.split(separator: "/").last ?? "") } ?? linkID
                guard let service = networkServices[target] as? [String: Any],
                      let name = serviceName(service) else { continue }
                let dns = (service["DNS"] as? [String: Any])?["ServerAddresses"] as? [String] ?? []
                let proxies = service["Proxies"] as? [String: Any] ?? [:]
                services.append(NetworkLocationService(
                    location: location,
                    name: name,
                    enabled: service["__INACTIVE__"] == nil,
                    dnsServers: dns,
                    http: endpoint(proxies, "HTTP"),
                    https: endpoint(proxies, "HTTPS"),
                    socks: endpoint(proxies, "SOCKS")
                ))
            }
        }
        let currentID = currentSet.map { String($0.split(separator: "/").last ?? "") }
        return NetworkLocationsSnapshot(
            current: locations.first { $0.id == currentID },
            locations: locations,
            services: services
        )
    }

    /// 与 `networksetup` 一致：服务自己的名字优先，没有时用网卡的名字。
    private static func serviceName(_ service: [String: Any]) -> String? {
        if let name = service["UserDefinedName"] as? String, !name.isEmpty { return name }
        let interface = service["Interface"] as? [String: Any]
        if let name = interface?["UserDefinedName"] as? String, !name.isEmpty { return name }
        return interface?["DeviceName"] as? String
    }

    private static func endpoint(_ proxies: [String: Any], _ prefix: String) -> ProxyEndpointState {
        ProxyEndpointState(
            enabled: intValue(proxies["\(prefix)Enable"]) == 1,
            server: proxies["\(prefix)Proxy"] as? String ?? "",
            port: intValue(proxies["\(prefix)Port"]) ?? 0
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let int as Int: int
        case let string as String: Int(string)
        default: nil
        }
    }
}

/// 读系统网络偏好（只读，不需要权限）。
public typealias NetworkLocationsProvider = @Sendable () -> NetworkLocationsSnapshot?

public enum NetworkLocationReader {
    /// 每次新建一份偏好会话：`SCPreferences` 会缓存，复用旧会话读不到别处刚切换的位置。
    public static let live: NetworkLocationsProvider = {
        guard let preferences = SCPreferencesCreate(nil, "kongshan.locations" as CFString, nil) else { return nil }
        let currentSet = SCPreferencesGetValue(preferences, kSCPrefCurrentSet) as? String
        guard let sets = SCPreferencesGetValue(preferences, kSCPrefSets) as? [String: Any],
              let services = SCPreferencesGetValue(preferences, kSCPrefNetworkServices) as? [String: Any] else {
            return nil
        }
        return NetworkLocationsSnapshot.parse(currentSet: currentSet, sets: sets, networkServices: services)
    }
}

/// 接管快照里一项属于哪个位置的判定。
public enum NetworkLocationScope {
    /// 快照项是否属于当前位置。旧版本写的快照（不知道位置）与读不到当前位置时按「属于」处理，
    /// 即退回改动前只按服务名还原的行为。
    public static func belongs(_ entryLocationID: String?, to current: NetworkLocation?) -> Bool {
        guard let entryLocationID, let current else { return true }
        return entryLocationID == current.id
    }

    /// 两项是否占同一个「位置 + 服务」槽位。旧快照项不知道位置，按同名即同槽处理。
    public static func sameSlot(_ lhs: (name: String, locationID: String?), _ rhs: (name: String, locationID: String?)) -> Bool {
        guard lhs.name == rhs.name else { return false }
        guard let left = lhs.locationID, let right = rhs.locationID else { return true }
        return left == right
    }

    /// 快照项所属位置已被删除（读得到位置列表、却没有这个 ID）：再也还原不到，直接作废。
    public static func isOrphaned(_ entryLocationID: String?, in snapshot: NetworkLocationsSnapshot?) -> Bool {
        guard let entryLocationID, let snapshot, !snapshot.locations.isEmpty else { return false }
        return snapshot.location(withID: entryLocationID) == nil
    }
}

/// 非当前位置里还待还原的设置，按位置归组，供事件与自检说明。
public struct PendingLocationRestore: Equatable, Sendable {
    public let locationID: String
    public let locationName: String
    public let services: [String]

    public init(locationID: String, locationName: String, services: [String]) {
        self.locationID = locationID
        self.locationName = locationName
        self.services = services
    }

    /// 「位置「自动」：Wi-Fi、LAN」
    public var summary: String {
        "位置「\(NetworkLocation.displayName(for: locationName))」：\(services.joined(separator: "、"))"
    }

    static func group(_ entries: [(locationID: String, locationName: String?, service: String)]) -> [PendingLocationRestore] {
        var order: [String] = []
        var names: [String: String] = [:]
        var services: [String: [String]] = [:]
        for entry in entries {
            if services[entry.locationID] == nil {
                order.append(entry.locationID)
                services[entry.locationID] = []
            }
            if let name = entry.locationName { names[entry.locationID] = name }
            if !(services[entry.locationID] ?? []).contains(entry.service) {
                services[entry.locationID, default: []].append(entry.service)
            }
        }
        return order.map {
            PendingLocationRestore(locationID: $0, locationName: names[$0] ?? $0, services: services[$0] ?? [])
        }
    }
}

/// 其他位置里仍指向空山的设置（没在接管时就是残留）。
public enum NetworkLocationResidue {
    public struct Finding: Equatable, Sendable {
        public let location: NetworkLocation
        public let service: String
        public let proxy: Bool
        public let dns: Bool

        public init(location: NetworkLocation, service: String, proxy: Bool, dns: Bool) {
            self.location = location
            self.service = service
            self.proxy = proxy
            self.dns = dns
        }
    }

    /// 非当前位置里代理指向 `127.0.0.1:relayPort`、或 DNS 含 TUN 劫持地址的服务。
    public static func findings(
        in snapshot: NetworkLocationsSnapshot,
        relayPort: Int?,
        tunDNSAddresses: Set<String>
    ) -> [Finding] {
        snapshot.services.compactMap { service in
            guard service.location.id != snapshot.current?.id else { return nil }
            let proxy = relayPort.map { port in
                [service.http, service.https, service.socks].contains { pointsAtLoopback($0, port: port) }
            } ?? false
            let dns = service.dnsServers.contains { tunDNSAddresses.contains($0) }
            guard proxy || dns else { return nil }
            return Finding(location: service.location, service: service.name, proxy: proxy, dns: dns)
        }
    }

    /// 按位置归组的一句话：「位置「自动」：Wi-Fi（代理、DNS）、LAN（DNS）」
    public static func describe(_ findings: [Finding]) -> String {
        var order: [NetworkLocation] = []
        var parts: [NetworkLocation: [String]] = [:]
        for finding in findings {
            if parts[finding.location] == nil { order.append(finding.location) }
            let kinds = [finding.proxy ? "代理" : nil, finding.dns ? "DNS" : nil].compactMap { $0 }
            parts[finding.location, default: []].append("\(finding.service)（\(kinds.joined(separator: "、"))）")
        }
        return order.map { "位置「\($0.displayName)」：\(parts[$0, default: []].joined(separator: "、"))" }
            .joined(separator: "；")
    }

    static func pointsAtLoopback(_ endpoint: ProxyEndpointState, port: Int) -> Bool {
        guard endpoint.enabled, endpoint.port == port else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(endpoint.server.lowercased())
    }
}
