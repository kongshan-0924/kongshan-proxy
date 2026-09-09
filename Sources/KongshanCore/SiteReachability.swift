import Foundation

/// 一个待探测的站点。
public struct SiteProbeTarget: Equatable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let url: URL
    /// 这个站点挂了会影响什么，用于在界面上解释后果。
    public let impact: String

    public init(name: String, url: URL, impact: String) {
        self.name = name
        self.url = url
        self.impact = impact
    }
}

/// 探测结论。
///
/// **`challenged` 是本项目最关心的一类**：Cloudflare 判定当前出口 IP 需要人机验证时，
/// 会回 403 并带 `cf-mitigated: challenge`。浏览器能自己过验证，命令行客户端过不去——
/// 真机 2026-09-03～09-04 Codex 反复「正在重新连接」正是这一类，而界面上只显示"超时"，
/// 用户会以为是节点死了，反复换节点也没用。把它单列出来，才说得清"换节点有没有用"。
public enum SiteProbeOutcome: Equatable, Sendable {
    case ok(statusCode: Int)
    /// 需要人机验证（Cloudflare `cf-mitigated`）。附带原始标记值。
    case challenged(statusCode: Int, mitigation: String)
    /// 明确被拒（4xx/5xx，但不是人机验证）。
    case rejected(statusCode: Int)
    case failed(String)

    public var isUsable: Bool {
        if case .ok = self { return true }
        return false
    }
}

public struct SiteProbeResult: Equatable, Sendable, Identifiable {
    public var id: String { target.name }
    public let target: SiteProbeTarget
    public let outcome: SiteProbeOutcome
    /// 毫秒。失败时为 nil。
    public let elapsedMilliseconds: Int?

    public init(target: SiteProbeTarget, outcome: SiteProbeOutcome, elapsedMilliseconds: Int?) {
        self.target = target
        self.outcome = outcome
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

/// 站点可达性自测。
///
/// 为什么不用第三方「IP 风险分」：不同厂商算法差异极大，同一个 IP 在 A 家 20 分、B 家 80 分很常见，
/// 而且要把出口 IP 交给又一个第三方。直接问目标站点本身「我现在能不能用」，既准确又不外泄。
public enum SiteReachabilityProbe {
    /// 返回 (状态码, 响应头)。响应头的键**必须已转小写**，classify 按小写查找。
    public typealias Loader = @Sendable (URLRequest) async throws -> (Int, [String: String])

    /// 默认探测目标。选取依据：覆盖"被 Cloudflare 挑战"最常见的几个站点，
    /// 外加两个基准（一个 Cloudflare 自家站、一个非 Cloudflare 站），用来区分
    /// 「这个 IP 被特定站点挑战」和「整条链路都不通」。
    public static let defaultTargets: [SiteProbeTarget] = [
        SiteProbeTarget(
            name: "ChatGPT / Codex",
            url: URL(string: "https://chatgpt.com/backend-api/me")!,
            impact: "被挑战时 Codex 会反复「正在重新连接」直到超时"
        ),
        SiteProbeTarget(
            name: "Claude",
            url: URL(string: "https://claude.ai/")!,
            impact: "被挑战时网页与客户端都进不去"
        ),
        SiteProbeTarget(
            name: "Google",
            url: URL(string: "https://www.google.com/generate_204")!,
            impact: "基准：非 Cloudflare 站点，用来判断链路本身通不通"
        ),
        SiteProbeTarget(
            name: "Cloudflare",
            url: URL(string: "https://www.cloudflare.com/")!,
            impact: "基准：Cloudflare 自家站点通常不挑战，与上面两条对比即可分辨是不是 IP 信誉问题"
        )
    ]

    /// 纯函数：由状态码与响应头判定结论。**响应头的键须为小写。**
    ///
    /// `cf-mitigated` 只要存在就算被挑战，不看具体值——Cloudflare 目前用 `challenge`，
    /// 但值可能变；存在这个头本身就说明请求被拦下做了缓解处理。
    public static func classify(statusCode: Int, headers: [String: String]) -> SiteProbeOutcome {
        if let mitigation = headers["cf-mitigated"], !mitigation.isEmpty {
            return .challenged(statusCode: statusCode, mitigation: mitigation)
        }
        // 2xx、3xx 视为可用；401/403 在没有 cf-mitigated 时是"没登录/没权限"，
        // 说明请求**确实到达了服务端**，链路是通的，对本工具而言算可用。
        if (200..<400).contains(statusCode) || statusCode == 401 { return .ok(statusCode: statusCode) }
        return .rejected(statusCode: statusCode)
    }

    /// 并发探测全部目标。任何一个失败都不影响其余，顺序与 `targets` 一致。
    public static func run(
        targets: [SiteProbeTarget] = defaultTargets,
        timeout: TimeInterval = 12,
        loader: @escaping Loader = defaultLoader
    ) async -> [SiteProbeResult] {
        await withTaskGroup(of: (Int, SiteProbeResult).self) { group in
            for (index, target) in targets.enumerated() {
                group.addTask {
                    var request = URLRequest(url: target.url, timeoutInterval: timeout)
                    request.httpMethod = "GET"
                    // 不带自定义 UA：伪装成浏览器会让结论失真——我们要测的正是
                    // 「本客户端这种请求」在当前出口下会不会被拦。
                    let began = ContinuousClock.now
                    do {
                        let (status, headers) = try await loader(request)
                        let elapsed = began.duration(to: .now)
                        return (index, SiteProbeResult(
                            target: target,
                            outcome: classify(statusCode: status, headers: headers),
                            elapsedMilliseconds: Self.milliseconds(elapsed)
                        ))
                    } catch {
                        return (index, SiteProbeResult(
                            target: target,
                            outcome: .failed(error.localizedDescription),
                            elapsedMilliseconds: nil
                        ))
                    }
                }
            }
            var collected: [(Int, SiteProbeResult)] = []
            for await item in group { collected.append(item) }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let ms = Double(duration.components.seconds) * 1000
            + Double(duration.components.attoseconds) / 1e15
        return Int(ms.rounded())
    }

    public static let defaultLoader: Loader = { request in
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SiteProbeError.notHTTP }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            guard let key = key as? String, let value = value as? String else { continue }
            headers[key.lowercased()] = value
        }
        return (http.statusCode, headers)
    }
}

public enum SiteProbeError: Error, LocalizedError {
    case notHTTP

    public var errorDescription: String? {
        switch self {
        case .notHTTP: "响应不是 HTTP"
        }
    }
}
