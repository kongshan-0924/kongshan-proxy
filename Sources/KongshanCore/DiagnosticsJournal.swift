import Foundation

/// 取证日志：**只追加、不受界面「全部清除」影响**的告警存档。
///
/// 存在的理由是一次真实的失败。2026-09-01 排查发现 App 累计烧掉 21 小时 CPU（全机第二），
/// 而唯一记录在案的异常只占其中 0.20%——其余 99.8% 无从归因，因为
/// `runtime-events.json` 里的历史被消息页的「全部清除」一次性抹掉了。
/// 自诊断本身工作正常，是**它产出的证据不受保护**。
///
/// 因此这里刻意与运行事件环分开：
/// - 独立文件，`clearRuntimeEvents()` 碰不到它；
/// - **追加式 NDJSON**（一行一条）而非整体重写 JSON 数组：崩溃或断电最多丢最后一行，
///   不会把整个存档写成半截而全毁；
/// - 大小有界并轮转，不会无限增长。
public final class DiagnosticsJournal: @unchecked Sendable {
    /// 一条取证记录。字段名刻意取短——这个文件是要长期追加的。
    public struct Record: Codable, Equatable, Sendable {
        public let t: Date
        public let level: String
        public let title: String
        public let detail: String?

        public init(t: Date, level: String, title: String, detail: String?) {
            self.t = t
            self.level = level
            self.title = title
            self.detail = detail
        }
    }

    private let url: URL
    private let rotatedURL: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(
        directory: URL = AppIdentity.supportDirectory,
        fileName: String = "diagnostics.ndjson",
        maxBytes: Int = 1_048_576
    ) {
        self.url = directory.appending(path: fileName)
        self.rotatedURL = directory.appending(path: "\(fileName).1")
        self.maxBytes = maxBytes
    }

    public var fileURL: URL { url }

    /// 追加一条。**任何失败都只是静默返回**：取证记录写不进去，不该反过来打断
    /// 正在处理的那件事本身（记录 CPU 异常时抛错、把异常处理流程带崩，是最坏的结果）。
    /// **刻意是同步的**，不是异步任务。`finishSelfDiagnostics()` 会在退出流程里记下
    /// 最后一段异常——「一直烧到用户退出」那类场景唯一的证据就是它。
    /// 交给 detached Task 去写，进程正好在这时结束，那条记录就没了；
    /// 而告警本就稀疏（一天数条），一次几百字节的追加不值得为异步承担丢失风险。
    public func append(_ record: Record) {
        guard let line = encode(record) else { return }
        lock.lock()
        defer { lock.unlock() }
        rotateIfNeeded(adding: line.count)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            guard (try? handle.seekToEnd()) != nil else { return }
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// 读回全部记录（新的在后）。轮转过的那一份也一并读，否则刚跨过轮转点就查不到上一段。
    public func records() -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        return decode(at: rotatedURL) + decode(at: url)
    }

    private func encode(_ record: Record) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(record) else { return nil }
        data.append(0x0A)
        return data
    }

    private func decode(at url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(Record.self, from: Data(line))
        }
    }

    /// 超过上限就把当前文件顶替掉上一份轮转文件。只留两代——取证要的是"最近一段完整"，
    /// 不是无限历史；无限增长会变成另一个问题。
    private func rotateIfNeeded(adding incoming: Int) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size + incoming > maxBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }
}
