import Compression
import Foundation

/// 内核日志的压缩归档。
///
/// **为什么要有它**：日志只有「当前 + 一份旧档」两个 5 MB 文件，TUN 模式下每分钟六七百行，
/// 不到 2 小时就整轮冲掉——真机 2026-10-02 想回查前一晚 23:18 的告警时，原始日志早已不在。
/// 文本日志压缩率约 10 倍，旧档在被覆盖前压成 `.gz` 留下来，48 小时内的都能回查，总量也有上限。
///
/// 产物是标准 gzip（DEFLATE + gzip 头尾），`gunzip` / `zcat` 直接能看。
public enum LogArchiver {
    public static let retention: TimeInterval = 48 * 3600
    public static let byteLimit = 64 * 1_024 * 1_024

    /// 把 `previous`（即将被覆盖的 `.1`）压成 `<baseName>.<时间戳>.gz`，返回归档路径。
    @discardableResult
    public static func archive(_ previous: URL, baseName: String, in directory: URL, at date: Date) throws -> URL {
        let data = try Data(contentsOf: previous)
        let destination = directory.appending(path: "\(baseName).\(stamp(date)).gz")
        try gzip(data, modified: date).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: destination.path
        )
        return destination
    }

    /// 删掉超过保留期的归档；剩下的仍超出总量上限就从最旧的删起。
    public static func prune(baseName: String, in directory: URL, now: Date) {
        let archives = list(baseName: baseName, in: directory)
        var kept: [(url: URL, size: Int)] = []
        for url in archives {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let modified = attributes?[.modificationDate] as? Date ?? now
            if now.timeIntervalSince(modified) > retention {
                try? FileManager.default.removeItem(at: url)
            } else {
                kept.append((url, (attributes?[.size] as? NSNumber)?.intValue ?? 0))
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for entry in kept where total > byteLimit {   // `kept` 按名字（即时间）从旧到新
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    /// 某个日志的全部归档，从旧到新。文件名里的时间戳定长，字典序即时间序。
    public static func list(baseName: String, in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix(baseName + ".") && $0.hasSuffix(".gz") }
            .sorted()
            .map { directory.appending(path: $0) }
    }

    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }

    // MARK: - gzip

    /// RFC 1952：10 字节头 + DEFLATE 数据 + CRC32 与原始长度（均为小端）。
    /// `COMPRESSION_ZLIB` 产出的正是不带 zlib 头尾的原始 DEFLATE。
    static func gzip(_ input: Data, modified: Date) throws -> Data {
        let deflated = try deflate(input)
        var output = Data([0x1F, 0x8B, 0x08, 0x00])
        output.append(littleEndian: UInt32(truncatingIfNeeded: Int(modified.timeIntervalSince1970)))
        output.append(contentsOf: [0x00, 0x03])   // 无额外标志；OS = Unix
        output.append(deflated)
        output.append(littleEndian: crc32(input))
        output.append(littleEndian: UInt32(truncatingIfNeeded: input.count))
        return output
    }

    static func deflate(_ input: Data) throws -> Data {
        if input.isEmpty { return Data([0x03, 0x00]) }   // 空输入的最短合法 DEFLATE 块
        // 文本日志只会变小；留足余量应付不可压缩的极端输入。
        let capacity = input.count + input.count / 8 + 4_096
        var buffer = Data(count: capacity)
        let written = buffer.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, input.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
        return buffer.prefix(written)
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes.bindMemory(to: UInt8.self) {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
