import Foundation

public enum ClashAPIError: Error, Equatable, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Clash API 返回了无效响应"
        case let .httpStatus(code): "Clash API 返回 HTTP \(code)"
        case .invalidPayload: "Clash API 返回的数据格式无效"
        }
    }
}

public enum DelayResult: Equatable, Sendable {
    case success(Int)
    case failure(String)
}

public actor ClashAPIClient {
    private let controller: URL
    private let secret: String
    private let session: URLSession

    public init(controller: URL, secret: String, session: URLSession = .shared) {
        self.controller = controller
        self.secret = secret
        self.session = session
    }

    public func health() async throws {
        let (data, _) = try await perform(request(path: ["version"]))
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["version"] as? String != nil else {
            throw ClashAPIError.invalidPayload
        }
    }

    public func select(node: String, in group: String = "手动选择") async throws {
        var request = request(path: ["proxies", group])
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": node], options: [.sortedKeys])
        _ = try await perform(request)
    }

    public func delay(
        node: String,
        testURL: URL,
        timeoutMilliseconds: Int = 5_000
    ) async throws -> Int {
        let endpoint = url(path: ["proxies", node, "delay"])
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ClashAPIError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: testURL.absoluteString),
            URLQueryItem(name: "timeout", value: String(timeoutMilliseconds))
        ]
        guard let url = components.url else { throw ClashAPIError.invalidResponse }
        var request = authenticatedRequest(url: url)
        request.timeoutInterval = TimeInterval(timeoutMilliseconds) / 1_000

        let (data, _) = try await perform(request)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let delay = payload["delay"] as? Int else {
            throw ClashAPIError.invalidPayload
        }
        return delay
    }

    public func delays(
        nodes: [String],
        testURL: URL,
        limit: Int = 8
    ) async -> [String: DelayResult] {
        let limit = max(1, min(limit, 8))
        var results: [String: DelayResult] = [:]
        var start = 0
        while start < nodes.count {
            let end = min(start + limit, nodes.count)
            let batch = Array(nodes[start..<end])
            await withTaskGroup(of: (String, DelayResult).self) { group in
                for node in batch {
                    group.addTask { [self] in
                        do {
                            return (node, .success(try await delay(node: node, testURL: testURL)))
                        } catch {
                            return (node, .failure(error.localizedDescription))
                        }
                    }
                }
                for await (node, result) in group { results[node] = result }
            }
            start = end
        }
        return results
    }

    private func request(path: [String]) -> URLRequest {
        authenticatedRequest(url: url(path: path))
    }

    private func url(path: [String]) -> URL {
        path.reduce(controller) { partial, component in partial.appending(path: component) }
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClashAPIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            throw ClashAPIError.httpStatus(http.statusCode)
        }
        return (data, http)
    }
}
