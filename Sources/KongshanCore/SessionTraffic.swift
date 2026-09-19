import Foundation

/// 一次接管会话的累计流量。
///
/// 数据源是 `/connections` 的 `uploadTotal`/`downloadTotal`——内核自启动以来的权威累计量。
/// 不能用别的算法替代：
/// - 把 `/traffic` 的速率乘采样间隔去积分，会漏掉两次采样之间开完又关掉的连接，
///   而且采样抖动会被持续放大；
/// - 累加每条活跃连接的 `upload`/`download`，短命连接同样统计不到，
///   连接一关它的字节就从列表里消失了。
///
/// 但内核计数器**每次内核重启都归零**（改设置、崩溃自愈、切配置都会重启内核），
/// 直接显示会让用户看到累计流量突然掉回去。这里在检测到计数器回退时，
/// 把上一次的读数结转进基线，于是"本次会话"的累计跨内核重启保持连续。
public struct SessionTrafficAccumulator: Equatable, Sendable {
    /// 此前各个内核实例的累计之和。
    private var uploadBase: Int64 = 0
    private var downloadBase: Int64 = 0
    /// 当前内核实例最近一次的读数。
    private var lastUpload: Int64 = 0
    private var lastDownload: Int64 = 0

    public init() {}

    public var upload: Int64 { uploadBase + lastUpload }
    public var download: Int64 { downloadBase + lastDownload }
    public var total: Int64 { upload + download }

    public mutating func record(uploadTotal: Int64, downloadTotal: Int64) {
        // 负数只可能来自解析异常，直接忽略——别让一次坏数据把基线搞乱。
        guard uploadTotal >= 0, downloadTotal >= 0 else { return }

        // 任一计数器回退即判定换了内核实例（重启会让两个都归零）。
        // 用「或」而不是「与」：空闲会话里可能上行有量、下行一直是 0，
        // 要求两个同时回退会漏判，那一段流量就白丢了。
        if uploadTotal < lastUpload || downloadTotal < lastDownload {
            uploadBase += lastUpload
            downloadBase += lastDownload
        }
        lastUpload = uploadTotal
        lastDownload = downloadTotal
    }

    /// 会话结束（停止接管）时归零。内核重启**不要**调用它——那正是要跨过去的场景。
    public mutating func reset() {
        self = SessionTrafficAccumulator()
    }
}
