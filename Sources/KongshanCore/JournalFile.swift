import Foundation

/// 追加式 NDJSON 文件的读写与轮转。
///
/// 这套机制（**同步写、一行一条、轮转两代**）已经在 `DiagnosticsJournal` 上被真机验证过，
/// `MetricsJournal` 直接复用，不再各写一遍——轮转与截断这类地方各写一遍必然会漂，
/// 而漂出来的后果是"排查时才发现记录不全"，那时已经晚了。
///
/// 三条性质都是刻意的：
/// - **同步**：退出流程里记下的最后一段是"一直烧到用户退出"那类场景唯一的证据，
///   交给异步任务去写，进程正好这时结束就没了。
/// - **一行一条**：崩溃或断电最多毁掉最后一行，不会像整体重写 JSON 数组那样全毁。
/// - **只留两代**：取证要的是"最近一段完整"，不是无限历史；无限增长会变成另一个问题。
final class JournalFile: @unchecked Sendable {
    private let url: URL
    private let rotatedURL: URL
    private let maxBytes: Int
    private let lock = NSLock()

    init(url: URL, maxBytes: Int) {
        self.url = url
        self.rotatedURL = url.appendingPathExtension("1")
        self.maxBytes = maxBytes
    }

    var fileURL: URL { url }

    /// 追加一行。**任何失败都只是静默返回**：记录写不进去，不该反过来打断
    /// 正在处理的那件事本身。
    func append(_ line: Data) {
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

    /// 读回全部行（新的在后）。轮转过的那一份也一并读，
    /// 否则刚跨过轮转点就查不到上一段。
    func readLines() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return lines(at: rotatedURL) + lines(at: url)
    }

    private func lines(at url: URL) -> [Data] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: UInt8(0x0A)).map { Data($0) }
    }

    private func rotateIfNeeded(adding incoming: Int) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? Int) ?? 0
        guard size + incoming > maxBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }
}
