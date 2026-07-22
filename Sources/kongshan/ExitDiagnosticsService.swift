import Foundation
import KongshanCore

struct ExitDiagnosticsReport: Equatable, Sendable {
    let exit: ExitIPInfo
    let resolvers: [DNSResolverInfo]
    let dns: DNSLeakAssessment
    let checkedAt: Date
}

struct ExitDiagnosticsService: Sendable {
    typealias Loader = @Sendable (URLRequest) async throws -> Data

    private let loader: Loader
    private let now: @Sendable () -> Date

    init(
        loader: @escaping Loader = Self.defaultLoader,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.loader = loader
        self.now = now
    }

    func run(remoteDoH: String) async throws -> ExitDiagnosticsReport {
        let configURL = URL(string: "https://am.i.mullvad.net/config")!
        let config = try JSONDecoder().decode(
            ServiceConfig.self,
            from: try await load(configURL)
        )
        let exitURL = config.ipv4URL.appending(path: "json")

        async let exitData = load(exitURL)
        async let resolverData = loadResolvers(domain: config.dnsLeakDomain)
        let exit = try await JSONDecoder().decode(ExitIPInfo.self, from: exitData)
        let resolvers = DNSLeakAnalyzer.deduplicated(try await resolverData)
        return ExitDiagnosticsReport(
            exit: exit,
            resolvers: resolvers,
            dns: DNSLeakAnalyzer.assess(exit: exit, resolvers: resolvers, remoteDoH: remoteDoH),
            checkedAt: now()
        )
    }

    private func loadResolvers(domain: String) async throws -> [DNSResolverInfo] {
        try await withThrowingTaskGroup(of: [DNSResolverInfo].self) { group in
            for _ in 0..<3 {
                group.addTask {
                    let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                    guard let url = URL(string: "https://\(token).\(domain)") else {
                        throw ExitDiagnosticsServiceError.invalidConfiguration
                    }
                    var request = URLRequest(url: url, timeoutInterval: 10)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    return try JSONDecoder().decode([DNSResolverInfo].self, from: try await loader(request))
                }
            }
            var combined: [DNSResolverInfo] = []
            for try await result in group { combined.append(contentsOf: result) }
            return combined
        }
    }

    private func load(_ url: URL) async throws -> Data {
        try await loader(URLRequest(url: url, timeoutInterval: 10))
    }

    private static func defaultLoader(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw ExitDiagnosticsServiceError.invalidResponse
        }
        return data
    }
}

private struct ServiceConfig: Decodable {
    let dnsLeakDomain: String
    let ipv4URL: URL

    private enum CodingKeys: String, CodingKey {
        case dnsLeakDomain = "dns_leak_domain"
        case ipv4URL = "ipv4_url"
    }
}

private enum ExitDiagnosticsServiceError: Error {
    case invalidConfiguration
    case invalidResponse
}
