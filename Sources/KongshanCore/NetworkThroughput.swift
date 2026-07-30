import Darwin
import Foundation

/// 物理网卡的累计收发字节数。
public struct InterfaceCounters: Equatable, Sendable {
    public let inputBytes: UInt64
    public let outputBytes: UInt64

    public init(inputBytes: UInt64, outputBytes: UInt64) {
        self.inputBytes = inputBytes
        self.outputBytes = outputBytes
    }
}

/// 整机网络吞吐。
///
/// 与仪表盘的速率不是一回事：仪表盘读的是内核 `/traffic`，**只统计走代理的流量**。
/// 菜单栏要的是"这台机器现在网速多少"，所以直接读网卡计数器。
///
/// 只累计 `en*`（Wi-Fi 与有线）。三个理由：
/// - **不能把所有接口相加**：TUN 开着时一份流量会被数两遍——一次在 `utun`（明文），
///   一次在 `en0`（封装后的密文）。物理网卡上的字节才是真正进出这台机器的量。
/// - 回环 `lo0` 要排除：本机进程互相通信（包括应用自己连内核的控制接口）算不上网速。
/// - `awdl0`/`llw0`（隔空投送、点对点 Wi-Fi）与 `bridge*`（虚拟机桥接）都不是上网路径，
///   混进来会让读数莫名其妙地跳。
///
/// 用 `NET_RT_IFLIST2` 而不是 `getifaddrs`：后者给的 `if_data` 里计数器是 32 位的，
/// 千兆链路上大约 30 秒就绕回一圈；`if_msghdr2` 带的 `if_data64` 是 64 位，不必处理回绕。
public enum NetworkThroughput {
    /// 读取当前累计计数。失败返回 nil（功能降级，不该让菜单栏因此出错）。
    public static func physicalCounters() -> InterfaceCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        var input: UInt64 = 0
        var output: UInt64 = 0

        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr.self).pointee
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                defer { offset += messageLength }

                guard header.ifm_type == RTM_IFINFO2 else { continue }
                let message = base.advanced(by: offset).assumingMemoryBound(to: if_msghdr2.self).pointee

                // 接口名紧跟在消息头之后，是一个 sockaddr_dl。
                let dataLink = base
                    .advanced(by: offset + MemoryLayout<if_msghdr2>.size)
                    .assumingMemoryBound(to: sockaddr_dl.self).pointee
                guard isPhysicalEthernet(dataLink) else { continue }

                input &+= message.ifm_data.ifi_ibytes
                output &+= message.ifm_data.ifi_obytes
            }
        }

        guard input > 0 || output > 0 else { return nil }
        return InterfaceCounters(inputBytes: input, outputBytes: output)
    }

    /// 接口名是否为 `en<数字>`。`sockaddr_dl.sdl_data` 里前 `sdl_nlen` 个字节才是名字。
    private static func isPhysicalEthernet(_ dataLink: sockaddr_dl) -> Bool {
        let nameLength = Int(dataLink.sdl_nlen)
        guard nameLength >= 3, nameLength <= 16 else { return false }

        var name = ""
        withUnsafeBytes(of: dataLink.sdl_data) { raw in
            for index in 0..<nameLength {
                name.append(Character(UnicodeScalar(raw[index])))
            }
        }
        guard name.hasPrefix("en") else { return false }
        // `en` 之后必须全是数字，否则 `enX-something` 之类的虚拟接口会被误收。
        return name.dropFirst(2).allSatisfy(\.isNumber) && name.count > 2
    }
}

/// 由累计计数算出瞬时速率。
///
/// 与 `ConnectionRateTracker` 分开：那个算的是**单条连接**的速率、数据来自 Clash API；
/// 这个算的是**整机网卡**、数据来自内核计数器，两者的重启/回退语义完全不同。
public struct ThroughputRateCalculator: Sendable {
    private var previous: (counters: InterfaceCounters, timestamp: Date)?

    public init() {}

    /// 返回 (上行 B/s, 下行 B/s)。首次采样没有基线，返回 0。
    public mutating func rate(from counters: InterfaceCounters, at timestamp: Date) -> (upload: Int64, download: Int64) {
        defer { previous = (counters, timestamp) }
        guard let previous else { return (0, 0) }

        let elapsed = timestamp.timeIntervalSince(previous.timestamp)
        // 间隔过小除出来是尖峰；睡眠唤醒后间隔可能是几小时，算出来的"平均值"也没有意义。
        guard elapsed >= 0.2, elapsed <= 10 else { return (0, 0) }

        // 计数器只会单调增。变小说明接口被重置（拔插网线、切 Wi-Fi）——
        // 这一轮直接给 0，下一轮就以新基线正常计算。
        guard counters.inputBytes >= previous.counters.inputBytes,
              counters.outputBytes >= previous.counters.outputBytes else {
            return (0, 0)
        }

        let download = Double(counters.inputBytes - previous.counters.inputBytes) / elapsed
        let upload = Double(counters.outputBytes - previous.counters.outputBytes) / elapsed
        return (Int64(upload), Int64(download))
    }

    public mutating func reset() {
        previous = nil
    }
}
