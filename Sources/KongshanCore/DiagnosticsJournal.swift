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

    private let file: JournalFile

    public init(
        directory: URL = AppIdentity.supportDirectory,
        fileName: String = "diagnostics.ndjson",
        maxBytes: Int = 1_048_576
    ) {
        self.file = JournalFile(url: directory.appending(path: fileName), maxBytes: maxBytes)
    }

    public var fileURL: URL { file.fileURL }

    /// **刻意是同步的**，不是异步任务。`finishSelfDiagnostics()` 会在退出流程里记下
    /// 最后一段异常——「一直烧到用户退出」那类场景唯一的证据就是它。
    public func append(_ record: Record) {
        guard let line = encode(record) else { return }
        file.append(line)
    }

    public func records() -> [Record] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return file.readLines().compactMap { try? decoder.decode(Record.self, from: $0) }
    }

    private func encode(_ record: Record) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(record) else { return nil }
        data.append(0x0A)
        return data
    }


}
