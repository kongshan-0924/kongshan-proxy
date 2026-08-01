import Darwin
import Foundation
import SystemConfiguration

/// 内网解析信息：TUN 接管系统 DNS **之前**从 macOS 解析器配置里读出来的内网 DNS 与域名。
///
/// 为什么需要它：TUN 模式下系统 DNS 被指向 TUN 接口自身，所有查询交给内核；内核只有
/// `dns-cn`（公共 DoH）、`dns-remote`（经代理的公共 DoH）和 `dns-fakeip`。于是**内网域名
/// 落到 fakeip**——fakeip 不校验域名是否真实存在，任何名字都给一个 `240.0.0.0/4` 的假 IP，
/// 而假 IP 段整段被路由进代理出口。结果是内网设备"一直在加载"：流量被送去国外节点，
/// 让它连你办公室的机器。
///
/// 真机实证（2026-07-30，某企业网 AD 域 `<域>`，域控兼 DNS 在 `172.16.16.7`）：
/// 经 TUN 查该域返回 `240.0.0.21`，直接问域控返回真实内网 IP；连一个根本不存在的
/// `definitely-not-real-abc123.internal` 经 TUN 也照样得到 `240.0.0.61`。
/// 路由层没问题（`route_exclude_address` 把 `172.16.0.0/12` 精确留给了物理网卡，
/// 实测 TCP 3389/389/135/445 全通），坏的只有 DNS。
public struct LANResolverSnapshot: Codable, Equatable, Sendable {
    /// 内网 DNS 服务器（仅私有网段地址）。
    public let servers: [String]
    /// 应当交给内网 DNS 解析的域名后缀（DHCP 下发的搜索域 / 作用域解析器的域）。
    public let searchDomains: [String]

    public init(servers: [String], searchDomains: [String]) {
        self.servers = servers
        self.searchDomains = searchDomains
    }

    public static let empty = LANResolverSnapshot(servers: [], searchDomains: [])

    /// 两者缺一即不可用：只有服务器没有域名不知道该分流什么，
    /// 只有域名没有服务器则无处可问。
    public var isUsable: Bool { !servers.isEmpty && !searchDomains.isEmpty }
}

public enum LANResolver {
    /// 解析 `scutil --dns` 的输出，挑出私有网段的 DNS 服务器与非反解的搜索域。
    ///
    /// - Parameter excluding: 要排除的服务器地址。**必须传入 TUN 自身地址**——
    ///   它（如 `172.19.0.1`）本身就落在 `172.16.0.0/12` 里，不排掉就会把内核自己
    ///   当成"内网 DNS"，形成自指：内网域名交给内核，内核再交给自己。
    public static func parse(scutilOutput: String, excluding: Set<String> = []) -> LANResolverSnapshot {
        var servers: [String] = []
        var domains: [String] = []

        for rawLine in scutilOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            if key.hasPrefix("nameserver") {
                guard isPrivateIPv4(value), !excluding.contains(value), !servers.contains(value) else { continue }
                servers.append(value)
            } else if key.hasPrefix("search domain") || key == "domain" {
                guard let domain = normalizedDomain(value), !domains.contains(domain) else { continue }
                domains.append(domain)
            }
        }

        return LANResolverSnapshot(servers: servers, searchDomains: domains)
    }

    /// 私有 IPv4（RFC1918 + 链路本地）。IPv6 不参与：内网 AD 环境几乎都是 IPv4，
    /// 而 fc00::/7 里塞进一个猜错的 DNS 只会让解析更糟。
    public static func isPrivateIPv4(_ host: String) -> Bool {
        var address = in_addr()
        guard host.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        let octet1 = (value >> 24) & 0xFF
        let octet2 = (value >> 16) & 0xFF
        switch octet1 {
        case 10: return true
        case 172: return (16...31).contains(octet2)
        case 192: return octet2 == 168
        case 169: return octet2 == 254
        default: return false
        }
    }

    /// 归一化搜索域；不该交给内网 DNS 的一律返回 nil。
    private static func normalizedDomain(_ value: String) -> String? {
        var domain = value.lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        while domain.hasPrefix(".") { domain.removeFirst() }
        guard !domain.isEmpty, !domain.contains(" ") else { return nil }

        // 反解区（`*.arpa`）由系统自己处理，交给内网 DNS 没有意义还会拖慢启动。
        if domain.hasSuffix(".arpa") || domain == "arpa" { return nil }
        // `.local` 是 mDNS/Bonjour 的地盘，走单播 DNS 问不到东西。
        if domain == "local" || domain.hasSuffix(".local") { return nil }
        // 顶级公共后缀不能整段劫持到内网 DNS，否则半个互联网的解析都被送进去。
        if !domain.contains(".") && !privateOnlyTopLevels.contains(domain) { return nil }
        return domain
    }

    /// 只在内网出现、不属于公共 DNS 命名空间的单标签后缀。
    /// 这类后缀作为搜索域时可以安全地整段交给内网 DNS。
    private static let privateOnlyTopLevels: Set<String> = ["lan", "intranet", "internal", "home", "corp", "private"]

    public typealias OutputProvider = @Sendable () async throws -> String
    public typealias PhysicalOutputProvider = @Sendable (_ interface: String) async throws -> String

    public static let defaultOutputProvider: OutputProvider = {
        try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/scutil"),
            arguments: ["--dns"],
            timeout: 5
        ).stdout
    }

    public static let defaultPhysicalOutputProvider: PhysicalOutputProvider = { interface in
        try await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/sbin/ipconfig"),
            arguments: ["getpacket", interface],
            timeout: 5
        ).stdout
    }

    /// TUN 接管后 `scutil --dns` 只会看到 TUN 自己。这里先用
    /// SystemConfiguration 取物理 PrimaryInterface，再读该接口的 DHCP 数据，
    /// 因此切 Wi-Fi / 热点时仍能拿到新网络的原始 DNS。
    public static func primaryPhysicalInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "kongshan.lan-resolver" as CFString, nil, nil),
              let state = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString)
                as? [String: Any],
              let interface = state["PrimaryInterface"] as? String,
              interface.hasPrefix("en") else {
            return nil
        }
        return interface
    }

    public static func parseDHCPPacket(_ output: String, excluding: Set<String> = []) -> LANResolverSnapshot {
        var servers: [String] = []
        var domains: [String] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = rawLine.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("domain_name_server") {
                for token in value.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                    where isPrivateIPv4(token) && !excluding.contains(token) && !servers.contains(token) {
                    servers.append(token)
                }
            } else if key.hasPrefix("domain_name") || key.hasPrefix("domain_search") {
                for token in value.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").inverted) {
                    guard let domain = normalizedDomain(token), !domains.contains(domain) else { continue }
                    domains.append(domain)
                }
            }
        }
        return LANResolverSnapshot(servers: servers, searchDomains: domains)
    }

    public static func probePhysicalService(
        excluding: Set<String> = [],
        interfaceProvider: @Sendable () -> String? = primaryPhysicalInterface,
        outputProvider: PhysicalOutputProvider = defaultPhysicalOutputProvider,
        query: DNSQuery = defaultDNSQuery
    ) async -> LANResolverSnapshot {
        guard let interface = interfaceProvider(),
              let output = try? await outputProvider(interface) else { return .empty }
        let parsed = parseDHCPPacket(output, excluding: excluding)
        guard parsed.searchDomains.isEmpty, !parsed.servers.isEmpty else { return parsed }
        let inferred = await inferDomains(fromServers: parsed.servers, query: query)
        return LANResolverSnapshot(servers: parsed.servers, searchDomains: inferred)
    }

    public enum QueryKind: Sendable {
        /// 反解（`dig -x`）。
        case reverse
        /// 正解 A 记录。
        case ipv4
    }

    /// 向指定 DNS 服务器发一次查询，返回答案列表（PTR 返回域名，A 返回 IP）。
    public typealias DNSQuery = @Sendable (_ argument: String, _ kind: QueryKind, _ server: String) async -> [String]

    public static let defaultDNSQuery: DNSQuery = { argument, kind, server in
        // 超时压到 1 秒、不重试：这是启动路径上的可选增强，宁可放弃也不能拖慢开代理。
        let arguments: [String]
        switch kind {
        case .reverse: arguments = ["+short", "+time=1", "+tries=1", "-x", argument, "@\(server)"]
        case .ipv4: arguments = ["+short", "+time=1", "+tries=1", "@\(server)", argument, "A"]
        }
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/dig"),
            arguments: arguments,
            timeout: 4
        ) else { return [] }
        return result.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 从内网 DNS 服务器**自身的 PTR 记录**推断内网域名。
    ///
    /// 为什么需要：很多企业网只下发 DNS 服务器、**不下发搜索域**（真机遇到的就是这样），
    /// 光看搜索域会一个域名都找不到，内网分流等于没开。
    ///
    /// 判据是 Active Directory 的固有结构：域控的反解就是 `<主机>.<AD 域>`，而 **AD 域名
    /// 本身会解析到域控的私有地址**。所以两步确认——
    /// 1. `PTR(<内网DNS>)` → `AD1.corp.example.com` → 候选域 `corp.example.com`
    /// 2. 在同一台服务器上正解 `corp.example.com` → 私有 IP ⇒ 接受
    ///
    /// 第 2 步是防误判的关键。公共 DNS 的反解也有父域（`114.114.114.114` →
    /// `public1.114dns.com`），但 `114dns.com` 解析出来是公网 IP，会被挡掉；
    /// 何况公共地址在第一步就已被 `isPrivateIPv4` 过滤。
    public static func inferDomains(
        fromServers servers: [String],
        query: DNSQuery = defaultDNSQuery
    ) async -> [String] {
        // 只问第一台私有 DNS：这是启动路径，最坏情况也只付两次 1 秒超时。
        guard let server = servers.first(where: isPrivateIPv4) else { return [] }

        let reverse = await query(server, .reverse, server)
        var domains: [String] = []
        for fqdn in reverse {
            guard let parent = parentDomain(of: fqdn),
                  let domain = normalizedDomain(parent),
                  !domains.contains(domain) else { continue }
            let addresses = await query(domain, .ipv4, server)
            guard addresses.contains(where: isPrivateIPv4) else { continue }
            domains.append(domain)
        }
        return domains
    }

    /// `AD1.corp.example.com.` → `corp.example.com`。只有一级标签（如 `router.`）时返回 nil。
    private static func parentDomain(of fqdn: String) -> String? {
        var value = fqdn.trimmingCharacters(in: .whitespaces)
        while value.hasSuffix(".") { value.removeLast() }
        let labels = value.split(separator: ".")
        guard labels.count >= 2 else { return nil }
        return labels.dropFirst().joined(separator: ".")
    }

    /// 读取当前解析器配置。**必须在 TUN 接管系统 DNS 之前调用**，
    /// 否则读到的只是内核自己的地址。失败返回空快照（功能降级，不阻塞启动）。
    public static func probe(
        excluding: Set<String> = [],
        outputProvider: OutputProvider = defaultOutputProvider,
        query: DNSQuery = defaultDNSQuery
    ) async -> LANResolverSnapshot {
        guard let output = try? await outputProvider() else { return .empty }
        let parsed = parse(scutilOutput: output, excluding: excluding)
        // 有搜索域就不必推断，省掉两次 DNS 往返。
        guard parsed.searchDomains.isEmpty, !parsed.servers.isEmpty else { return parsed }
        let inferred = await inferDomains(fromServers: parsed.servers, query: query)
        guard !inferred.isEmpty else { return parsed }
        return LANResolverSnapshot(servers: parsed.servers, searchDomains: inferred)
    }

    /// 把手动设置与自动探测合成最终生效值。
    ///
    /// 服务器：手填的优先——用户显式指定就该听他的，自动探测只是兜底。
    /// 域名后缀：取并集——自动探测常常不全（很多网络只下发一个搜索域，
    /// 而内网还有别的域），手填要能补，不能覆盖掉探测到的。
    public static func effective(settings: TunSettings, detected: LANResolverSnapshot) -> LANResolverSnapshot {
        guard settings.lanDNSEnabled else { return .empty }

        let manual = settings.lanDNSServer.trimmingCharacters(in: .whitespaces)
        let servers: [String]
        if manual.isEmpty {
            servers = detected.servers
        } else if isPrivateIPv4(manual) {
            servers = [manual]
        } else {
            // 手填了个非私有地址：不能把内网域名送去公网 DNS（既问不到，还泄漏内网域名）。
            // 退回自动探测，宁可少一个功能也别做错事。
            servers = detected.servers
        }

        var suffixes: [String] = []
        for candidate in detected.searchDomains + settings.lanDomainSuffixes {
            guard let domain = normalizedDomain(stripWildcard(candidate)), !suffixes.contains(domain) else { continue }
            suffixes.append(domain)
        }
        return LANResolverSnapshot(servers: servers, searchDomains: suffixes)
    }

    /// 用户习惯按绕过列表的写法填 `*.corp.local` / `.corp.local`，都当后缀处理。
    private static func stripWildcard(_ value: String) -> String {
        var domain = value.trimmingCharacters(in: .whitespaces)
        if domain.hasPrefix("*") { domain.removeFirst() }
        return domain
    }
}
