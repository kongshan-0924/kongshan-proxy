import Foundation

public struct ConnectionLiveDetail: Identifiable, Equatable, Sendable {
    public let connection: ConnectionDetail
    public let uploadRate: Int64
    public let downloadRate: Int64

    public init(connection: ConnectionDetail, uploadRate: Int64, downloadRate: Int64) {
        self.connection = connection
        self.uploadRate = uploadRate
        self.downloadRate = downloadRate
    }

    public var id: String { connection.id }
    public var host: String { connection.host }
    public var process: String? { connection.process }
    public var rule: String { connection.rule }
    public var chains: [String] { connection.chains }
    public var network: String { connection.network }
    public var upload: Int64 { connection.upload }
    public var download: Int64 { connection.download }
    public var totalRate: Int64 { uploadRate + downloadRate }
}

public struct ConnectionRateTracker: Sendable {
    private struct Sample: Sendable {
        let upload: Int64
        let download: Int64
        let timestamp: Date
    }

    private var previous: [String: Sample] = [:]

    public init() {}

    public mutating func update(_ connections: [ConnectionDetail], at timestamp: Date) -> [ConnectionLiveDetail] {
        var next: [String: Sample] = [:]
        let live = connections.map { connection in
            let current = Sample(
                upload: connection.upload,
                download: connection.download,
                timestamp: timestamp
            )
            next[connection.id] = current
            guard let old = previous[connection.id] else {
                return ConnectionLiveDetail(connection: connection, uploadRate: 0, downloadRate: 0)
            }
            let elapsed = timestamp.timeIntervalSince(old.timestamp)
            guard elapsed > 0,
                  connection.upload >= old.upload,
                  connection.download >= old.download else {
                return ConnectionLiveDetail(connection: connection, uploadRate: 0, downloadRate: 0)
            }
            return ConnectionLiveDetail(
                connection: connection,
                uploadRate: Int64(Double(connection.upload - old.upload) / elapsed),
                downloadRate: Int64(Double(connection.download - old.download) / elapsed)
            )
        }
        previous = next
        return live
    }

    public mutating func reset() {
        previous.removeAll(keepingCapacity: false)
    }
}

public extension Array where Element == ConnectionLiveDetail {
    var totalUploadRate: Int64 { reduce(0) { $0 + $1.uploadRate } }
    var totalDownloadRate: Int64 { reduce(0) { $0 + $1.downloadRate } }
    var totalRate: Int64 { totalUploadRate + totalDownloadRate }
}
