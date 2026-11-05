import Foundation
import KongshanCore

/// 仓库根目录与本机架构的内置内核。各测试文件原先各抄一份、写死内核路径，
/// 在 Intel 上一换内核路径就连锁失败一百多例（2026-10-25 审计 B3）。
enum TestPaths {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var vendoredKernel: URL { packageRoot.appending(path: VendoredKernel.relativePath) }
}
