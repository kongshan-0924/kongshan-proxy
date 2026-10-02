import Darwin
import Foundation

public enum KernelLogSource: Hashable, Sendable {
    case system
    case tun
    /// TUN 内核日志的**折叠副本**，由 App 从 Clash API 日志流写入。
    ///
    /// 助手启动的 TUN 内核把日志直写进助手目录（`defaultExternalTUNLogURL`），App 无法逐行过滤；
    /// 断网刷屏时那份文件几分钟就被截断一轮，断网前后的上下文随之丢失（真机 2026-09-26）。
    /// 这份副本经 `KernelLogFolder` 折叠，才留得住复盘要看的那一段。
    /// 与 `.tun` 分开：`.tun` 是未装助手时的回退路径，由内核进程在外部直接追加。
    case tunStream

    fileprivate var fileName: String {
        switch self {
        case .system: "sing-box.log"
        case .tun: "sing-box-tun.log"
        case .tunStream: "sing-box-tun-stream.log"
        }
    }
}

public actor KernelLogStore {
    public static let defaultBufferedLineLimit = 2_000
    public static let defaultFileByteLimit = 5 * 1_024 * 1_024

    public nonisolated let directory: URL

    private let maxBufferedLines: Int
    private let maxFileBytes: Int
    private let externalTUNLogURL: URL
    private let errorHandler: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private var bufferedLines: [String] = []
    /// 每个来源一台折叠器：刷屏状态跨调用保持。
    private var folders: [KernelLogSource: KernelLogFolder] = [:]
    /// 管道分块送来的半行，按「来源 + 管道」分开拼：stdout 与 stderr 的块会交错到达。
    private var partialLines: [String: String] = [:]
    /// 半行的长度上限。超过仍无换行就当整行处理，防止异常输出把内存撑大。
    private static let maxPartialLineBytes = 64 * 1_024
    private var externalMonitorSource: KernelLogSource?
    private var externalMonitor: DispatchSourceFileSystemObject?
    /// 缓存写文件句柄，避免每条日志都 open/seek/close。
    /// sing-box info 级别在繁忙时段每秒数十条，旧实现每条都 FileHandle(forWritingTo:) + seekToEnd + close，
    /// IO 开销非必要。句柄在 actor 内串行访问，安全。轮转时关闭并重新打开。
    private var writeHandles: [KernelLogSource: FileHandle] = [:]

    public init(
        directory: URL = AppIdentity.supportDirectory
            .appending(path: "logs", directoryHint: .isDirectory),
        maxBufferedLines: Int = KernelLogStore.defaultBufferedLineLimit,
        maxFileBytes: Int = KernelLogStore.defaultFileByteLimit,
        externalTUNLogURL: URL = KernelLogStore.defaultExternalTUNLogURL,
        errorHandler: @escaping @Sendable (String) -> Void = { _ in },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.directory = directory
        self.maxBufferedLines = max(1, maxBufferedLines)
        self.maxFileBytes = max(1, maxFileBytes)
        self.externalTUNLogURL = externalTUNLogURL
        self.errorHandler = errorHandler
        self.now = now
    }

    deinit {
        externalMonitor?.cancel()
        for handle in writeHandles.values {
            try? handle.close()
        }
    }

    /// 用户态内核的管道输出。`readabilityHandler` 给的是**数据块**而不是行：
    /// 一块可能含多行，也可能在行中间截断。先拼成整行再交给折叠器，末尾的半行留到下一块。
    public func append(_ line: SingBoxLogLine) throws {
        let channel = line.stream == .standardOutput ? "stdout" : "stderr"
        let key = "\(KernelLogSource.system.fileName)#\(channel)"
        var lines = ((partialLines.removeValue(forKey: key) ?? "") + line.text)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let tail = lines.removeLast()
        if !tail.isEmpty {
            if tail.utf8.count > Self.maxPartialLineBytes {
                lines.append(tail)
            } else {
                partialLines[key] = tail
            }
        }
        try write(lines: lines, source: .system, at: now())
    }

    /// 整段文本（按行切分，末尾不带换行也视为完整的一行）。
    public func append(_ text: String, source: KernelLogSource) throws {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        try write(lines: lines, source: source, at: now())
    }

    /// TUN 内核日志流的副本（见 `KernelLogSource.tunStream`）。按内核日志的格式落盘，
    /// 时间取 App 收到该行的时刻——日志流本身不带时间。
    public func appendStream(_ entries: [CoreLogEntry]) throws {
        guard !entries.isEmpty else { return }
        var folder = folders[.tunStream] ?? KernelLogFolder()
        var output: [String] = []
        for entry in entries {
            let line = KernelLogFolder.timestamp(entry.receivedAt) + " " + entry.level.fileLabel + " " + entry.message
            output += folder.process(line, at: entry.receivedAt)
        }
        folders[.tunStream] = folder
        try writeRaw(output, source: .tunStream)
    }

    /// 内核停止时调用：写出拼了一半的尾行，仍在折叠就补一条总结。
    /// 不调用也不丢数据——只是总结要等下一代内核的第一行才写出。
    public func finish(source: KernelLogSource) throws {
        let prefix = "\(source.fileName)#"
        let pending = partialLines.keys.filter { $0.hasPrefix(prefix) }.sorted()
        var lines: [String] = []
        for key in pending {
            if let tail = partialLines.removeValue(forKey: key) { lines.append(tail) }
        }
        let date = now()
        var folder = folders[source] ?? KernelLogFolder()
        var output: [String] = []
        for line in lines { output += folder.process(line, at: date) }
        output += folder.finish(at: date)
        folders[source] = folder
        try writeRaw(output, source: source)
    }

    private func write(lines: [String], source: KernelLogSource, at date: Date) throws {
        guard !lines.isEmpty else { return }
        var folder = folders[source] ?? KernelLogFolder()
        var output: [String] = []
        for line in lines { output += folder.process(line, at: date) }
        folders[source] = folder
        try writeRaw(output, source: source)
    }

    private func writeRaw(_ lines: [String], source: KernelLogSource) throws {
        guard !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n"
        appendToBuffer(text)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let fileURL = directory.appending(path: source.fileName)
        var data = Data(text.utf8)
        if data.count > maxFileBytes {
            data = Data(data.suffix(maxFileBytes))
        }

        let existingSize = fileSize(at: fileURL)
        if existingSize > 0, existingSize + data.count > maxFileBytes {
            try rotate(fileURL, source: source)
        }
        try append(data, to: fileURL, source: source)
    }

    public func recentLines() -> [String] {
        bufferedLines
    }

    public func clearRecentLines() {
        bufferedLines.removeAll(keepingCapacity: false)
    }

    public func prepareForExternalAppend(source: KernelLogSource) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory.appending(path: source.fileName)
        if fileSize(at: fileURL) >= maxFileBytes {
            try rotate(fileURL, source: source)
        }
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    public func startExternalRotationMonitoring(source: KernelLogSource) throws {
        if externalMonitorSource == source, externalMonitor != nil { return }
        stopExternalRotationMonitoring(source: externalMonitorSource)
        try prepareForExternalAppend(source: source)

        let fileURL = directory.appending(path: source.fileName)
        let descriptor = Darwin.open(fileURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )
        monitor.setEventHandler { [weak self] in
            Task { await self?.rotateExternalFileIfNeeded(source: source) }
        }
        monitor.setCancelHandler { Darwin.close(descriptor) }
        externalMonitorSource = source
        externalMonitor = monitor
        monitor.resume()
    }

    public func stopExternalRotationMonitoring(source: KernelLogSource?) {
        guard source == nil || source == externalMonitorSource else { return }
        externalMonitor?.cancel()
        externalMonitor = nil
        externalMonitorSource = nil
    }

    /// TUN 内核由 helper 以 root 起，**日志写在 helper 自己的目录**
    /// （`HelperConstants.stateDirectory`），不在 App 的 logs 目录里。
    /// 导出时若不去那边读，TUN 全程的内核日志就一条都拿不到——
    /// 真机 2026-09-02 复盘时才发现，30 小时 TUN 会话在导出里完全是空白。
    /// 文件是 0640 root:admin、目录 `--x`，App 以管理员账户运行时有读权限；读不到就跳过这一段。
    public static let defaultExternalTUNLogURL = URL(
        fileURLWithPath: "/Library/Application Support/kongshan/helper/sing-box-tun.log"
    )

    public func exportText() throws -> String {
        let ownFiles = [
            "sing-box.log.1", "sing-box.log",
            "sing-box-tun.log.1", "sing-box-tun.log",
            "sing-box-tun-stream.log.1", "sing-box-tun-stream.log"
        ]
        var sources: [(url: URL, limit: Int, title: String)] = ownFiles.map {
            (directory.appending(path: $0), maxFileBytes, $0)
        }
        // 助手那份由内核直写、未经折叠，而 `sing-box-tun-stream.log` 已有同一内核的折叠副本：
        // 只取尾部 1 MB，用来补上日志流连上之前的启动输出与致命错误。
        sources.append((
            externalTUNLogURL,
            min(maxFileBytes, 1_024 * 1_024),
            "\(externalTUNLogURL.lastPathComponent)（助手原始输出，仅尾部）"
        ))
        var sections: [String] = []
        for source in sources {
            guard FileManager.default.fileExists(atPath: source.url.path) else { continue }
            guard let data = try? readTail(of: source.url, limit: source.limit) else { continue }
            let content = String(decoding: data, as: UTF8.self)
            sections.append("===== \(source.title) =====\n\(content)")
        }
        // 更早的压缩归档不进导出（体积），只列出来，需要时到 logs/ 里用 gunzip 查看。
        let archives = [KernelLogSource.system, .tun, .tunStream]
            .flatMap { LogArchiver.list(baseName: $0.fileName, in: directory) }
            .map(\.lastPathComponent)
        if !archives.isEmpty {
            sections.append("===== 压缩归档（未展开，共 \(archives.count) 份）=====\n" + archives.joined(separator: "\n"))
        }
        if sections.isEmpty { return "kongshan 日志导出\n（没有可用的内核日志）\n" }
        return sections.joined(separator: "\n")
    }

    /// 只读文件尾部。大文件（helper 的 TUN 日志真机见过 63 MB）整份读进内存
    /// 既慢又可能顶爆内存，而排查要看的本来就是最近这一段。
    private func readTail(of url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size > UInt64(limit) { try handle.seek(toOffset: size - UInt64(limit)) }
        else { try handle.seek(toOffset: 0) }
        return try handle.readToEnd() ?? Data()
    }

    private func appendToBuffer(_ text: String) {
        bufferedLines.append(contentsOf: text.split(whereSeparator: \.isNewline).map(String.init))
        if bufferedLines.count > maxBufferedLines {
            bufferedLines.removeFirst(bufferedLines.count - maxBufferedLines)
        }
    }

    private func fileSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.intValue
    }

    private func rotate(_ fileURL: URL, source: KernelLogSource) throws {
        // 轮转前先关闭缓存句柄：rotate 会删掉原文件，句柄会指向已删除的 inode，
        // 后续写会写到旧 inode（"幽灵文件"），新文件不会被写入。
        if let handle = writeHandles.removeValue(forKey: source) {
            try? handle.close()
        }
        let archiveURL = fileURL.appendingPathExtension("1")
        if FileManager.default.fileExists(atPath: archiveURL.path) {
            archivePrevious(archiveURL, source: source)
            try FileManager.default.removeItem(at: archiveURL)
        }
        let existing = try Data(contentsOf: fileURL)
        try Data(existing.suffix(maxFileBytes)).write(to: archiveURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: archiveURL.path
        )
        try FileManager.default.removeItem(at: fileURL)
    }

    /// `.1` 即将被新一轮覆盖：先压缩留档（见 `LogArchiver`）。归档失败只上报，不挡滚动——
    /// 挡住滚动等于让当前日志无限增长。
    private func archivePrevious(_ previous: URL, source: KernelLogSource) {
        do {
            try LogArchiver.archive(previous, baseName: source.fileName, in: directory, at: now())
        } catch {
            errorHandler("日志归档失败：\(error.localizedDescription)")
        }
        LogArchiver.prune(baseName: source.fileName, in: directory, now: now())
    }

    private func rotateExternalFileIfNeeded(source: KernelLogSource) {
        guard source == externalMonitorSource else { return }
        let fileURL = directory.appending(path: source.fileName)
        guard fileSize(at: fileURL) >= maxFileBytes else { return }
        do {
            let archiveURL = fileURL.appendingPathExtension("1")
            if FileManager.default.fileExists(atPath: archiveURL.path) {
                archivePrevious(archiveURL, source: source)
                try FileManager.default.removeItem(at: archiveURL)
            }
            let reader = try FileHandle(forReadingFrom: fileURL)
            defer { try? reader.close() }
            let size = try reader.seekToEnd()
            try reader.seek(toOffset: size > UInt64(maxFileBytes) ? size - UInt64(maxFileBytes) : 0)
            let tail = try reader.readToEnd() ?? Data()
            try Data(tail.suffix(maxFileBytes)).write(to: archiveURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: archiveURL.path
            )

            let writer = try FileHandle(forWritingTo: fileURL)
            defer { try? writer.close() }
            try writer.truncate(atOffset: 0)
        } catch {
            errorHandler("TUN 日志轮转失败：\(error.localizedDescription)")
        }
    }

    private func append(_ data: Data, to fileURL: URL, source: KernelLogSource) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
            return
        }

        // O3: 复用缓存句柄，避免每条日志都 open/seek/close。
        // 句柄在 actor 内串行访问；rotate 时已 close 并清缓存，这里会重新打开。
        let handle: FileHandle
        if let cached = writeHandles[source] {
            handle = cached
        } else {
            let newHandle = try FileHandle(forWritingTo: fileURL)
            try newHandle.seekToEnd()
            writeHandles[source] = newHandle
            handle = newHandle
        }
        try handle.write(contentsOf: data)
    }
}

extension CoreLogLevel {
    /// 与内核日志文件一致的级别标签（`KernelLogFolder` 靠 ` ERROR ` 识别失败行）。
    var fileLabel: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}
