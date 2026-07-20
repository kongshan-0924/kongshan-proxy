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
    private let errorHandler: @Sendable (String) -> Void
    private var bufferedLines: [String] = []
    private var externalMonitorSource: KernelLogSource?
    private var externalMonitor: DispatchSourceFileSystemObject?

    public init(
        directory: URL = AppIdentity.supportDirectory
            .appending(path: "logs", directoryHint: .isDirectory),
        maxBufferedLines: Int = KernelLogStore.defaultBufferedLineLimit,
        maxFileBytes: Int = KernelLogStore.defaultFileByteLimit,
        errorHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.maxBufferedLines = max(1, maxBufferedLines)
        self.maxFileBytes = max(1, maxFileBytes)
        self.errorHandler = errorHandler
    }

    deinit {
        externalMonitor?.cancel()
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
            try rotate(fileURL)
        }
        try append(data, to: fileURL)
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
            try rotate(fileURL)
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

    public func exportText() throws -> String {
        let names = [
            "sing-box.log.1",
            "sing-box.log",
            "sing-box-tun.log.1",
            "sing-box-tun.log"
        ]
        var sections: [String] = []
        for name in names {
            let url = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            let content = String(decoding: data, as: UTF8.self)
            sections.append("===== \(name) =====\n\(content)")
        }
        if sections.isEmpty { return "kongshan 日志导出\n（没有可用的内核日志）\n" }
        return sections.joined(separator: "\n")
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

    private func rotate(_ fileURL: URL) throws {
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

    private func append(_ data: Data, to fileURL: URL) throws {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
            return
        }

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
