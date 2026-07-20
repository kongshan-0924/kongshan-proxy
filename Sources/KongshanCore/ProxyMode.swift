import Foundation

public enum ProxyMode: String, Codable, CaseIterable, Sendable {
    case systemProxy
    case tun
}

public struct TunSettings: Codable, Equatable, Sendable {
    public var strictRoute: Bool
    public var interfaceName: String
    public var addresses: [String]
    public var mtu: Int

    public init(
        strictRoute: Bool,
        interfaceName: String,
        addresses: [String],
        mtu: Int
    ) {
        self.strictRoute = strictRoute
        self.interfaceName = interfaceName
        self.addresses = addresses
        self.mtu = mtu
    }

    public static let defaults = TunSettings(
        strictRoute: false,
        interfaceName: "kongshan-tun",
        addresses: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
        mtu: 9_000
    )
}
