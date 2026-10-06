import Darwin
import Foundation
import os
import SystemConfiguration

/// 测速方式。
public enum SpeedTestMethod: String, Codable, CaseIterable, Sendable {
    /// 直连节点 server:port 做 TCP 握手计时。快、稳、不需要内核在跑，
    /// 但只验证服务器可达，不验证代理链路。默认。
    case tcpPing
    /// 经 Clash API 让内核用当前代理请求测试 URL，测真实链路延迟。需要内核在跑。
    case urlTest

    public var displayName: String {
        switch self {
        case .tcpPing: "TCP 握手（快，直连）"
        case .urlTest: "URL 测速（经代理）"
        }
    }
}

/// 直连 TCP 握手测速：**绑在物理网卡上**连 host:port，测握手耗时。
///
/// 旧实现用 Network 框架的 `NWConnection`，它默认跟随系统代理；开着 TUN 时就算绕开系统代理，
/// 包也会被 TUN 的默认路由接走。真机 2026-10-06 22:35 一次测速发出的 461 条连接**全部经当前节点
/// 当前节点转发**：测出来的是「经当前节点绕一圈」的延迟，几百条连接同时挤进当前节点还拖慢了正常上网。
///
/// 现在三件事都绕开：
/// - 用 BSD socket，系统代理只对上层框架生效，管不到它；
/// - `IP_BOUND_IF` 绑物理网卡（sing-box 自己也靠它避开 TUN），走网卡自己的路由，不进 TUN；
/// - 节点域名不问系统解析器（开 TUN 时它指向内核，会拿到假 IP），绑同一块网卡直接问国内公共 DNS。
///   解析耗时不计入延迟。
public enum TCPPinger {
    /// 节点域名直连解析默认问的公共 DNS（与内核解析节点域名的 `dns-bootstrap` 默认上游一致）。
    public static let defaultResolvers = ["223.5.5.5", "119.29.29.29"]

    public static func ping(
        host: String,
        port: Int,
        timeoutMilliseconds: Int = 3_000,
        resolvers: [String] = defaultResolvers
    ) async -> DelayResult {
        guard (1...65_535).contains(port) else { return .failure("端口无效") }
        return await withCheckedContinuation { (continuation: CheckedContinuation<DelayResult, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: pingBlocking(
                    host: host, port: port, timeoutMilliseconds: timeoutMilliseconds, resolvers: resolvers
                ))
            }
        }
    }

    /// 当前网络的网关会不会替目标完成握手（软路由的透明代理、部分公司网关）。是的话直连握手测到的是网关，
    /// 所有节点都是几毫秒，毫无意义。真机 2026-10-07 在一个经软路由透明代理上网的位置实测：直接问 223.5.5.5 也拿到 198.18 段的
    /// 假地址，10 个节点地址的握手全是 2～4 毫秒。
    ///
    /// 两条判据，任一成立即算：
    /// - 向文档保留地址 198.51.100.1（RFC 5737，公网不路由）同端口握手居然成功；
    /// - 直连问节点域名拿到 198.18.0.0/15（fake-ip 常用段）。
    /// 返回给用户看的原因；没发现时返回 nil。
    public static func gatewayInterception(
        sampleHost: String,
        samplePort: Int,
        resolvers: [String] = defaultResolvers
    ) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: gatewayInterceptionBlocking(
                    sampleHost: sampleHost, samplePort: samplePort, resolvers: resolvers
                ))
            }
        }
    }

    static let unroutableProbeAddress = "198.51.100.1"

    static func gatewayInterceptionBlocking(sampleHost: String, samplePort: Int, resolvers: [String]) -> String? {
        guard let interface = PhysicalInterface.primary(), (1...65_535).contains(samplePort) else { return nil }
        if case .success = DirectSocket.connectTime(
            to: IPLiteral(unroutableProbeAddress)!, port: samplePort,
            interfaceIndex: interface.index, timeoutMilliseconds: 800
        ) {
            return "向公网不存在的地址握手也成功了"
        }
        if IPLiteral(sampleHost) == nil,
           case let .success(addresses) = DirectDNS.resolve(host: sampleHost, servers: resolvers, interfaceIndex: interface.index),
           addresses.contains(where: \.isFakeIPRange) {
            return "节点域名被解析成了 198.18 段的假地址"
        }
        return nil
    }

    static func pingBlocking(host: String, port: Int, timeoutMilliseconds: Int, resolvers: [String]) -> DelayResult {
        let literal = IPLiteral(host)
        // 连本机回环不需要也不能绑网卡（物理网卡的路由表里没有 127/8）。
        if let literal, literal.isLoopback {
            return DirectSocket.connectTime(to: literal, port: port, interfaceIndex: nil, timeoutMilliseconds: timeoutMilliseconds)
        }
        guard let interface = PhysicalInterface.primary() else {
            return .failure("本机没有可用的物理网络")
        }
        let address: IPLiteral
        if let literal {
            address = literal
        } else {
            switch DirectDNS.resolve(host: host, servers: resolvers, interfaceIndex: interface.index) {
            case let .success(addresses):
                guard let first = addresses.first else { return .failure("直连 DNS 解析不到节点域名") }
                address = first
            case let .failure(reason):
                return .failure(reason.message)
            }
        }
        return DirectSocket.connectTime(
            to: address, port: port, interfaceIndex: interface.index, timeoutMilliseconds: timeoutMilliseconds
        )
    }
}

/// IPv4 / IPv6 字面量。
struct IPLiteral: Equatable, Sendable {
    enum Family: Sendable { case v4, v6 }
    let text: String
    let family: Family

    init?(_ text: String) {
        var v4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            self.text = text
            family = .v4
            return
        }
        var v6 = in6_addr()
        if text.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            self.text = text
            family = .v6
            return
        }
        return nil
    }

    var isLoopback: Bool {
        switch family {
        case .v4: text.hasPrefix("127.")
        case .v6: text == "::1"
        }
    }

    /// 198.18.0.0/15：fake-ip 常用段（RFC 2544 基准测试保留段，公网不该出现）。
    var isFakeIPRange: Bool {
        guard family == .v4 else { return false }
        let parts = text.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 198 && (parts[1] == 18 || parts[1] == 19)
    }
}

/// 当前出网的物理网卡。
public enum PhysicalInterface {
    public struct Info: Equatable, Sendable {
        public let name: String
        public let index: UInt32
    }

    /// 隧道 / 虚拟网卡前缀：它们不是「物理出口」，绑上去就又进了别人的隧道。
    static let virtualPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "gif", "stf", "lo", "awdl", "llw", "anpi"]

    /// 系统认定的主网卡（`State:/Network/Global/IPv4` 的 `PrimaryInterface`）；它不是物理网卡或取不到时，
    /// 退到第一块已启用、有 IPv4 地址的 `en*`。
    public static func primary() -> Info? {
        if let store = SCDynamicStoreCreate(nil, "kongshan.speedtest" as CFString, nil, nil),
           let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let name = global["PrimaryInterface"] as? String,
           isPhysical(name) {
            let index = if_nametoindex(name)
            if index != 0 { return Info(name: name, index: index) }
        }
        return firstActiveEthernet()
    }

    static func isPhysical(_ name: String) -> Bool {
        !name.isEmpty && !virtualPrefixes.contains { name.hasPrefix($0) }
    }

    private static func firstActiveEthernet() -> Info? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        var names: [String] = []
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            let flags = Int32(current.pointee.ifa_flags)
            guard name.hasPrefix("en"),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            names.append(name)
        }
        for name in names.sorted() {
            let index = if_nametoindex(name)
            if index != 0 { return Info(name: name, index: index) }
        }
        return nil
    }
}

/// 绑网卡的 BSD socket 操作（阻塞，调用方放到后台队列）。
enum DirectSocket {
    /// 非阻塞 connect + poll，返回握手耗时。
    static func connectTime(to address: IPLiteral, port: Int, interfaceIndex: UInt32?, timeoutMilliseconds: Int) -> DelayResult {
        let family = address.family == .v4 ? AF_INET : AF_INET6
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return .failure("无法创建 socket：\(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        if let interfaceIndex, !bind(fd, family: family, interfaceIndex: interfaceIndex) {
            return .failure("无法绑定物理网卡：\(String(cString: strerror(errno)))")
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let start = DispatchTime.now()
        let result = withSockaddr(address, port: port) { pointer, length in
            Darwin.connect(fd, pointer, length)
        }
        if result != 0 && errno != EINPROGRESS {
            return .failure(describe(errno))
        }
        if result != 0 {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, Int32(timeoutMilliseconds))
            if ready == 0 { return .failure("超时") }
            if ready < 0 { return .failure(describe(errno)) }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else {
                return .failure(describe(errno))
            }
            if socketError != 0 { return .failure(describe(socketError)) }
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return .success(Int(elapsed / 1_000_000))
    }

    /// `IP_BOUND_IF` / `IPV6_BOUND_IF`：只从这块网卡收发，走它自己的（作用域）路由表。
    static func bind(_ fd: Int32, family: Int32, interfaceIndex: UInt32) -> Bool {
        var index = interfaceIndex
        let size = socklen_t(MemoryLayout<UInt32>.size)
        if family == AF_INET {
            return setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index, size) == 0
        }
        return setsockopt(fd, IPPROTO_IPV6, IPV6_BOUND_IF, &index, size) == 0
    }

    static func withSockaddr<T>(
        _ address: IPLiteral,
        port: Int,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        switch address.family {
        case .v4:
            var storage = sockaddr_in()
            storage.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            storage.sin_family = sa_family_t(AF_INET)
            storage.sin_port = in_port_t(UInt16(port)).bigEndian
            _ = address.text.withCString { inet_pton(AF_INET, $0, &storage.sin_addr) }
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        case .v6:
            var storage = sockaddr_in6()
            storage.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            storage.sin6_family = sa_family_t(AF_INET6)
            storage.sin6_port = in_port_t(UInt16(port)).bigEndian
            _ = address.text.withCString { inet_pton(AF_INET6, $0, &storage.sin6_addr) }
            return withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
    }

    static func describe(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED: "Connection refused"
        case ENETUNREACH: "Network is unreachable"
        case EHOSTUNREACH: "No route to host"
        case ETIMEDOUT: "超时"
        default: String(cString: strerror(code))
        }
    }
}

/// 绑物理网卡的最小 DNS（UDP、只查 A 记录）。只给测速解析节点域名用。
enum DirectDNS {
    private static let cache = OSAllocatedUnfairLock<[String: (addresses: [IPLiteral], expires: Date)]>(initialState: [:])
    /// 一次测速几十上百个节点常共用几个域名；缓存两分钟，免得同一个域名问几十遍。
    static let cacheLifetime: TimeInterval = 120
    static let queryTimeoutMilliseconds = 1_500

    static func resolve(host: String, servers: [String], interfaceIndex: UInt32) -> Result<[IPLiteral], DirectDNSFailure> {
        let key = host.lowercased()
        if let cached = cache.withLock({ $0[key] }), cached.expires > Date() {
            return .success(cached.addresses)
        }
        let usable = servers.compactMap(IPLiteral.init).filter { $0.family == .v4 }
        guard !usable.isEmpty else { return .failure(DirectDNSFailure("没有可用的直连 DNS")) }
        var reasons: [String] = []
        for server in usable {
            switch query(host: host, server: server, interfaceIndex: interfaceIndex, timeoutMilliseconds: queryTimeoutMilliseconds) {
            case let .success(addresses) where !addresses.isEmpty:
                cache.withLock { $0[key] = (addresses, Date().addingTimeInterval(cacheLifetime)) }
                return .success(addresses)
            case .success:
                // 域名存在但没有 IPv4 地址：换一台问也一样。
                return .failure(DirectDNSFailure("节点域名没有 IPv4 地址"))
            case let .failure(reason):
                reasons.append("\(server.text) \(reason.message)")
            }
        }
        return .failure(DirectDNSFailure("直连 DNS 解析不了节点域名（\(reasons.joined(separator: "；"))）"))
    }

    static func query(host: String, server: IPLiteral, interfaceIndex: UInt32, timeoutMilliseconds: Int) -> Result<[IPLiteral], DirectDNSFailure> {
        let id = UInt16.random(in: 1...UInt16.max)
        guard let packet = message(id: id, host: host) else { return .failure(DirectDNSFailure("域名格式无效")) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failure(DirectDNSFailure("无法创建 socket")) }
        defer { close(fd) }
        guard DirectSocket.bind(fd, family: AF_INET, interfaceIndex: interfaceIndex) else {
            return .failure(DirectDNSFailure("无法绑定物理网卡"))
        }
        let sent = DirectSocket.withSockaddr(server, port: 53) { pointer, length in
            packet.withUnsafeBytes { sendto(fd, $0.baseAddress, packet.count, 0, pointer, length) }
        }
        guard sent == packet.count else { return .failure(DirectDNSFailure(DirectSocket.describe(errno))) }

        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
        var buffer = [UInt8](repeating: 0, count: 1_500)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { return .failure(DirectDNSFailure("超时")) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32((deadline - now) / 1_000_000) + 1)
            if ready == 0 { return .failure(DirectDNSFailure("超时")) }
            if ready < 0 {
                if errno == EINTR { continue }
                return .failure(DirectDNSFailure(DirectSocket.describe(errno)))
            }
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { continue }
            // ID 对不上的是别的（或伪造的）应答，丢掉继续等。
            switch parse(Array(buffer[0..<count]), id: id) {
            case .mismatched: continue
            case let .answer(addresses): return .success(addresses)
            case let .error(message): return .failure(DirectDNSFailure(message))
            }
        }
    }

    /// A 记录查询报文：头部 12 字节（递归）+ 问题。域名非法（空标签、超长）返回 nil。
    static func message(id: UInt16, host: String) -> [UInt8]? {
        let name = host.hasSuffix(".") ? String(host.dropLast()) : host
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !name.isEmpty, name.utf8.count <= 253, labels.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 63 }) else {
            return nil
        }
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        for label in labels {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        return bytes
    }

    enum Parsed: Equatable {
        case mismatched
        case answer([IPLiteral])
        case error(String)
    }

    /// 只取应答区的 A 记录（CNAME 链上的 A 也在应答区里）。
    static func parse(_ bytes: [UInt8], id: UInt16) -> Parsed {
        guard bytes.count >= 12 else { return .mismatched }
        guard UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == id, bytes[2] & 0x80 != 0 else { return .mismatched }
        let rcode = bytes[3] & 0x0F
        switch rcode {
        case 0: break
        case 3: return .error("域名不存在")
        case 2: return .error("DNS 服务器出错")
        case 5: return .error("DNS 服务器拒绝查询")
        default: return .error("DNS 返回错误码 \(rcode)")
        }
        let questions = Int(bytes[4]) << 8 | Int(bytes[5])
        let answers = Int(bytes[6]) << 8 | Int(bytes[7])
        var offset = 12
        for _ in 0..<questions {
            guard let next = skipName(bytes, offset), next + 4 <= bytes.count else { return .error("应答格式错误") }
            offset = next + 4
        }
        var addresses: [IPLiteral] = []
        for _ in 0..<answers {
            guard let next = skipName(bytes, offset), next + 10 <= bytes.count else { break }
            let type = Int(bytes[next]) << 8 | Int(bytes[next + 1])
            let length = Int(bytes[next + 8]) << 8 | Int(bytes[next + 9])
            let dataStart = next + 10
            guard dataStart + length <= bytes.count else { break }
            if type == 1, length == 4 {
                let text = bytes[dataStart..<(dataStart + 4)].map(String.init).joined(separator: ".")
                if let literal = IPLiteral(text) { addresses.append(literal) }
            }
            offset = dataStart + length
        }
        return .answer(addresses)
    }

    /// 跳过一个（可能压缩的）域名，返回其后的偏移。
    static func skipName(_ bytes: [UInt8], _ start: Int) -> Int? {
        var offset = start
        while offset < bytes.count {
            let length = Int(bytes[offset])
            if length == 0 { return offset + 1 }
            if length & 0xC0 == 0xC0 { return offset + 2 <= bytes.count ? offset + 2 : nil }
            offset += 1 + length
        }
        return nil
    }
}

struct DirectDNSFailure: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
