import Darwin
import Foundation

public enum KernelLogSource: Equatable, Sendable {
    case system
    case tun

    fileprivate var fileName: String {
        switch self {
        case .system: "sing-box.log"
        case .tun: "sing-box-tun.log"
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
    private var bufferedLines: [String] = []
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
        errorHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.maxBufferedLines = max(1, maxBufferedLines)
        self.maxFileBytes = max(1, maxFileBytes)
        self.externalTUNLogURL = externalTUNLogURL
        self.errorHandler = errorHandler
    }

    deinit {
        externalMonitor?.cancel()
        for handle in writeHandles.values {
            try? handle.close()
        }
    }

    public func append(_ line: SingBoxLogLine) throws {
        try append(line.text, source: .system)
    }

    public func append(_ text: String, source: KernelLogSource) throws {
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
    /// 文件是 0644、目录 `--x`，App 有读权限。
    public static let defaultExternalTUNLogURL = URL(
        fileURLWithPath: "/Library/Application Support/kongshan/helper/sing-box-tun.log"
    )

    public func exportText() throws -> String {
        var urls = [
            directory.appending(path: "sing-box.log.1"),
            directory.appending(path: "sing-box.log"),
            directory.appending(path: "sing-box-tun.log.1"),
            directory.appending(path: "sing-box-tun.log")
        ]
        urls.append(externalTUNLogURL)
        var sections: [String] = []
        for url in urls {
            let name = url.lastPathComponent
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // helper 那份可能有几十 MB，导出只取尾部，避免把导出文件撑爆。
            guard let data = try? readTail(of: url, limit: maxFileBytes) else { continue }
            let content = String(decoding: data, as: UTF8.self)
            sections.append("===== \(name) =====\n\(content)")
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

    private func rotateExternalFileIfNeeded(source: KernelLogSource) {
        guard source == externalMonitorSource else { return }
        let fileURL = directory.appending(path: source.fileName)
        guard fileSize(at: fileURL) >= maxFileBytes else { return }
        do {
            let archiveURL = fileURL.appendingPathExtension("1")
            if FileManager.default.fileExists(atPath: archiveURL.path) {
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
            try writer.truncate(atOffset: 0)
            try writer.close()
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
