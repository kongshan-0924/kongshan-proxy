import Foundation
import XCTest
@testable import KongshanCore

/// 订阅规则集的下载、编译与缓存。下载器是假的（计数、可注入失败），编译器是真的内置内核——
/// 编译本身就是格式校验，这一环必须真跑。
final class SubscriptionRuleSetServiceTests: XCTestCase {
    private final class FakeServer: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String: String] = [:]
        private var failing: Set<String> = []
        private(set) var requests: [String] = []

        func serve(_ path: String, _ body: String) { lock.withLock { bodies[path] = body } }
        func fail(_ path: String) { lock.withLock { _ = failing.insert(path) } }
        func recover(_ path: String) { lock.withLock { _ = failing.remove(path) } }
        var requestCount: Int { lock.withLock { requests.count } }

        func download(_ url: URL, _ limit: Int) throws -> Data {
            try lock.withLock {
                requests.append(url.path)
                if failing.contains(url.path) { throw URLError(.timedOut) }
                guard let body = bodies[url.path] else { throw SubscriptionRuleSetError.invalidStatus(404) }
                let data = Data(body.utf8)
                if data.count > limit { throw SubscriptionRuleSetError.tooLarge(limit: limit) }
                return data
            }
        }
    }

    private let binary = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "Vendor/sing-box/sing-box")
    private var root: URL!
    private var server: FakeServer!
    private var service: SubscriptionRuleSetService!
    private let sourceID = UUID()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appending(path: "sub-rulesets-\(UUID().uuidString)")
        let storage = Storage(rootDirectory: root)
        try await storage.prepare()
        server = FakeServer()
        let server = server!
        service = SubscriptionRuleSetService(
            storage: storage,
            downloader: { url, limit in try server.download(url, limit) },
            compiler: SubscriptionRuleSetService.coreCompiler(binaryURL: binary)
        )
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func provider(_ name: String, interval: TimeInterval? = 43_200,
                          path: String? = nil) -> SubscriptionRuleProvider {
        SubscriptionRuleProvider(
            name: name, url: URL(string: "https://rules.example.com\(path ?? "/\(name).yaml")")!,
            behavior: .classical, format: .yaml, interval: interval
        )
    }

    private let mixed = "payload:\n  - DOMAIN-SUFFIX,example.org\n  - IP-CIDR,10.0.0.0/8\n  - PROCESS-NAME,SomeApp\n"
    private let ipOnly = "payload:\n  - IP-CIDR,10.0.0.0/8\n"

    /// 下载（缺的与过期的）。旧测试里的「首次准备」统一走它。
    private func download(_ providers: [SubscriptionRuleProvider], now: Date = Date(),
                          sourceID: UUID? = nil) async -> SubscriptionRuleSetService.Result {
        await service.refresh(providers: providers, sourceID: sourceID ?? self.sourceID, force: false, now: now)
    }

    // MARK: - 首次下载

    func testFirstDownloadCompilesAndReportsTags() async throws {
        server.serve("/direct.yaml", mixed)
        let result = await download([provider("direct")])
        let prepared = try XCTUnwrap(result.prepared["direct"], "\(result.warnings)")
        XCTAssertEqual(prepared.routeTag, "sub-direct")
        XCTAssertEqual(prepared.dnsTag, "sub-direct-dns")
        XCTAssertEqual(prepared.entryCount, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.routeFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(prepared.dnsFile).path))
        XCTAssertEqual(result.updated, ["direct"])
        // 读回的源码仍把进程条件单独成条
        let source = try JSONSerialization.jsonObject(with: Data(contentsOf: prepared.sourceFile)) as? [String: Any]
        XCTAssertEqual(RuleSetContent(singBoxSource: try XCTUnwrap(source)).processName, ["SomeApp"])
    }

    /// 只有 IP / 进程条件的规则集，DNS 版本是空规则集（DNS 规则只能按域名匹配）。
    /// 总是有 DNS 版本，配置才与内容无关：内容变了只换文件、不用改配置。
    func testDomainlessRuleSetGetsEmptyDNSVariant() async throws {
        server.serve("/ips.yaml", ipOnly)
        let result = await download([provider("ips")])
        let prepared = try XCTUnwrap(result.prepared["ips"])
        let empty = try await compiledEmptyRuleSet()
        XCTAssertEqual(prepared.dnsTag, "sub-ips-dns")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(prepared.dnsFile)), empty)
    }

    private func compiledEmptyRuleSet() async throws -> Data {
        let source = root.appending(path: "empty-check.json")
        let output = root.appending(path: "empty-check.srs")
        try Data(#"{"version":1,"rules":[]}"#.utf8).write(to: source)
        try await SubscriptionRuleSetService.coreCompiler(binaryURL: binary)(source, output)
        return try Data(contentsOf: output)
    }

    /// 只读缓存：没缓存的只报「缺」，不下载、不告警、不建目录。
    func testCachedReadsWithoutTouchingDiskOrNetwork() async {
        let result = await service.cached(providers: [provider("direct")], sourceID: sourceID)
        XCTAssertTrue(result.prepared.isEmpty)
        XCTAssertEqual(result.missing, ["direct"])
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        XCTAssertEqual(server.requestCount, 0)
        let directory = root.appending(path: "rule-sets/subscription/\(sourceID.uuidString.lowercased())")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "只读路径不该建目录")
    }

    func testCachedReportsStaleAndExpiry() async throws {
        server.serve("/direct.yaml", mixed)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await download([provider("direct")], now: t0)
        let result = await service.cached(providers: [provider("direct")], sourceID: sourceID,
                                          now: t0.addingTimeInterval(86_400))
        XCTAssertEqual(result.stale, ["direct"])
        XCTAssertEqual(result.prepared["direct"]?.expiresAt, t0.addingTimeInterval(43_200))
        XCTAssertEqual(server.requestCount, 1)
    }

    // MARK: - 生成配置：占位

    /// 没缓存的在正式路径放空规则集占位：配置照样能引用，不联网、不等下载。
    func testConfigurationGetsPlaceholdersForMissingSets() async throws {
        let result = await service.prepareForConfiguration(providers: [provider("direct")], sourceID: sourceID)
        let prepared = try XCTUnwrap(result.prepared["direct"])
        XCTAssertTrue(prepared.isPlaceholder)
        XCTAssertEqual(prepared.entryCount, 0)
        XCTAssertEqual(prepared.routeTag, "sub-direct")
        XCTAssertEqual(prepared.dnsTag, "sub-direct-dns")
        let empty = try await compiledEmptyRuleSet()
        XCTAssertEqual(try Data(contentsOf: prepared.routeFile), empty)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(prepared.dnsFile)), empty)
        XCTAssertEqual(result.missing, ["direct"], "要报给调用方安排后台下载")
        XCTAssertEqual(server.requestCount, 0)
    }

    /// 占位与正式文件同路径：下载完成后原地替换，内核据此自动重载，配置不用改。
    func testDownloadReplacesPlaceholderInPlace() async throws {
        server.serve("/direct.yaml", mixed)
        let first = await service.prepareForConfiguration(providers: [provider("direct")], sourceID: sourceID)
        let placeholder = try XCTUnwrap(first.prepared["direct"])
        let fetched = await download([provider("direct")])
        let downloaded = try XCTUnwrap(fetched.prepared["direct"])
        let empty = try await compiledEmptyRuleSet()
        XCTAssertEqual(downloaded.routeFile, placeholder.routeFile)
        XCTAssertEqual(downloaded.dnsFile, placeholder.dnsFile)
        XCTAssertFalse(downloaded.isPlaceholder)
        XCTAssertNotEqual(try Data(contentsOf: downloaded.routeFile), empty)
        let again = await service.prepareForConfiguration(providers: [provider("direct")], sourceID: sourceID)
        let next = try XCTUnwrap(again.prepared["direct"])
        XCTAssertFalse(next.isPlaceholder)
        XCTAssertEqual(next.entryCount, 3)
    }

    /// 占位只在文件不存在时创建：哪怕元数据丢了（或下载刚好在写），也绝不拿空文件盖掉正式文件。
    func testPlaceholderNeverOverwritesExistingFile() async throws {
        server.serve("/direct.yaml", mixed)
        let fetched = await download([provider("direct")])
        let downloaded = try XCTUnwrap(fetched.prepared["direct"])
        let before = try Data(contentsOf: downloaded.routeFile)
        try FileManager.default.removeItem(
            at: downloaded.routeFile.deletingPathExtension().appendingPathExtension("meta.json")
        )
        let result = await service.prepareForConfiguration(providers: [provider("direct")], sourceID: sourceID)
        XCTAssertEqual(result.missing, ["direct"])
        XCTAssertEqual(try Data(contentsOf: downloaded.routeFile), before)
    }

    /// 把编译卡在闸门前：此时临时目录已建好、源码已写入——正是并发操作最容易踩到的窗口。
    private final class CompileGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isReached = false
        private var isReleased = false
        var reached: Bool { lock.withLock { isReached } }
        func release() { lock.withLock { isReleased = true } }
        func wait() async throws {
            lock.withLock { isReached = true }
            let deadline = ContinuousClock.now + .seconds(5)
            while !lock.withLock({ isReleased }), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func gatedService(_ gate: CompileGate) -> SubscriptionRuleSetService {
        let server = server!
        let compile = SubscriptionRuleSetService.coreCompiler(binaryURL: binary)
        return SubscriptionRuleSetService(
            storage: Storage(rootDirectory: root),
            downloader: { url, limit in try server.download(url, limit) },
            compiler: { source, output in
                try await gate.wait()
                try await compile(source, output)
            }
        )
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("等待超时") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 第一轮刷新停在编译前时插进第二轮：第二轮必须排队，
    /// 否则它的孤儿清理会删掉第一轮正在用的临时目录，第一轮就失败了。
    func testConcurrentRefreshesDoNotClobberEachOther() async throws {
        server.serve("/a.yaml", mixed)
        server.serve("/b.yaml", mixed)
        let providers = [provider("a"), provider("b")]
        let gate = CompileGate()
        let service = gatedService(gate)
        let sourceID = sourceID
        let first = Task { await service.refresh(providers: providers, sourceID: sourceID, force: true) }
        try await waitUntil { gate.reached }
        let second = Task { await service.refresh(providers: providers, sourceID: sourceID, force: true) }
        try await Task.sleep(for: .milliseconds(150))
        gate.release()
        let (a, b) = await (first.value, second.value)
        XCTAssertTrue(a.warnings.isEmpty, "\(a.warnings)")
        XCTAssertTrue(b.warnings.isEmpty, "\(b.warnings)")
        XCTAssertEqual(Set(a.prepared.keys), ["a", "b"])
        XCTAssertEqual(Set(b.prepared.keys), ["a", "b"])
    }

    /// 删除订阅的清理排在进行中的下载之后：既不把下载弄失败，删完也不会被写回来。
    func testRemoveCacheWaitsForRunningDownload() async throws {
        server.serve("/a.yaml", mixed)
        let providers = [provider("a")]
        let gate = CompileGate()
        let service = gatedService(gate)
        let sourceID = sourceID
        let refresh = Task { await service.refresh(providers: providers, sourceID: sourceID, force: true) }
        try await waitUntil { gate.reached }
        let removal = Task { await service.removeCache(sourceID: sourceID) }
        try await Task.sleep(for: .milliseconds(150))
        gate.release()
        let result = await refresh.value
        await removal.value
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)")
        let directory = root.appending(path: "rule-sets/subscription/\(sourceID.uuidString.lowercased())")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testOrphanCachesOfDeletedSubscriptionsAreRemoved() async throws {
        server.serve("/a.yaml", mixed)
        let other = UUID()
        _ = await download([provider("a")])
        _ = await download([provider("a")], sourceID: other)
        let base = root.appending(path: "rule-sets/subscription")
        try FileManager.default.createDirectory(at: base.appending(path: "not-a-uuid"), withIntermediateDirectories: true)
        let removed = await service.removeOrphanCaches(keeping: [sourceID])
        XCTAssertEqual(removed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appending(path: sourceID.uuidString.lowercased()).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.appending(path: other.uuidString.lowercased()).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.appending(path: "not-a-uuid").path), "不认识的东西不碰")
    }

    // MARK: - 缓存优先：生成配置时永不刷新

    /// **核心约束**：有缓存就直接用，哪怕早已过期——生成配置（包括开机自动恢复）绝不卡在联网刷新上。
    func testConfigurationUsesStaleCacheWithoutNetwork() async throws {
        server.serve("/direct.yaml", mixed)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await download([provider("direct")], now: t0)
        XCTAssertEqual(server.requestCount, 1)

        let muchLater = t0.addingTimeInterval(30 * 86_400)
        let result = await service.prepareForConfiguration(providers: [provider("direct")], sourceID: sourceID,
                                                           now: muchLater)
        XCTAssertEqual(server.requestCount, 1, "生成配置不得因为过期而联网")
        XCTAssertNotNil(result.prepared["direct"])
        XCTAssertEqual(result.stale, ["direct"], "过期的要报出来，交给后台刷新")
    }

    // MARK: - 后台刷新

    func testRefreshOnlyDownloadsStaleOnes() async throws {
        server.serve("/fresh.yaml", mixed)
        server.serve("/old.yaml", mixed)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let providers = [provider("fresh", interval: 86_400), provider("old", interval: 3_600)]
        _ = await download(providers, now: t0)
        XCTAssertEqual(server.requestCount, 2)

        let result = await service.refresh(providers: providers, sourceID: sourceID, force: false,
                                           now: t0.addingTimeInterval(7_200))
        XCTAssertEqual(result.updated, ["old"])
        XCTAssertEqual(server.requestCount, 3)
    }

    /// 刷新失败时继续用旧缓存——规则集只是分流依据，旧的也比没有强。
    func testRefreshFailureKeepsUsingCache() async throws {
        server.serve("/direct.yaml", mixed)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await download([provider("direct")], now: t0)
        server.fail("/direct.yaml")
        let result = await service.refresh(providers: [provider("direct")], sourceID: sourceID, force: true, now: t0)
        XCTAssertNotNil(result.prepared["direct"])
        XCTAssertTrue(result.updated.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("继续使用缓存") }, "\(result.warnings)")
    }

    /// 同一原因的失败合并成一行：断一次网，十几份规则集各报一行只会淹没真正的信息
    ///（2026-09-19 真机：日志里 16 条几乎一样的「更新失败」）。
    func testSameReasonFailuresAreSummarizedInOneLine() async throws {
        let names = ["a", "b", "c"]
        for name in names { server.serve("/\(name).yaml", mixed) }
        let providers = names.map { provider($0) }
        _ = await download(providers)
        for name in names { server.fail("/\(name).yaml") }
        let result = await service.refresh(providers: providers, sourceID: sourceID, force: true)
        XCTAssertEqual(result.warnings.count, 1, "\(result.warnings)")
        let line = try XCTUnwrap(result.warnings.first)
        XCTAssertTrue(line.hasPrefix("3 份规则集更新失败，继续使用缓存："), line)
        XCTAssertTrue(line.hasSuffix("（a、b、c）"), line)
        XCTAssertEqual(result.prepared.count, 3, "失败的都继续用缓存")
    }

    func testSummaryNamesSingleFailureAndCapsListedNames() {
        XCTAssertEqual(
            SubscriptionRuleSetService.summarize(["超时": ["ai"]], outcome: "不可用"),
            ["规则集「ai」不可用：超时"]
        )
        XCTAssertEqual(
            SubscriptionRuleSetService.summarize(["超时": ["1", "2", "3", "4", "5", "6", "7"]], outcome: "不可用"),
            ["7 份规则集不可用：超时（1、2、3、4、5 等）"]
        )
    }

    /// 内容格式坏了（编译不过）不能覆盖掉能用的旧缓存。
    func testBrokenUpdateDoesNotReplaceGoodCache() async throws {
        server.serve("/direct.yaml", mixed)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = await download([provider("direct")], now: t0)
        let before = try Data(contentsOf: try XCTUnwrap(first.prepared["direct"]).routeFile)
        server.serve("/direct.yaml", "not: [valid")
        let result = await service.refresh(providers: [provider("direct")], sourceID: sourceID, force: true, now: t0)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(result.prepared["direct"]).routeFile), before)
    }

    /// 订阅把同名规则集改指向别的地址：旧缓存作废。
    func testChangedURLInvalidatesCache() async throws {
        server.serve("/v1/direct.yaml", mixed)
        server.serve("/v2/direct.yaml", ipOnly)
        _ = await download([provider("direct", path: "/v1/direct.yaml")])
        let result = await download([provider("direct", path: "/v2/direct.yaml")])
        XCTAssertEqual(server.requestCount, 2)
        XCTAssertEqual(result.prepared["direct"]?.entryCount, 1)
    }

    /// 订阅刷新后删掉了某个规则集：它的文件要清掉，不留孤儿。
    func testOrphanedRuleSetFilesAreRemoved() async throws {
        server.serve("/a.yaml", mixed)
        server.serve("/b.yaml", mixed)
        let first = await download([provider("a"), provider("b")])
        let bFile = try XCTUnwrap(first.prepared["b"]).routeFile
        _ = await download([provider("a")])
        XCTAssertFalse(FileManager.default.fileExists(atPath: bFile.path))
    }

    // MARK: - 不可信输入

    /// 规则集名来自订阅，是不可信输入：不能拼出目录外的路径。
    func testHostileProviderNameCannotEscapeDirectory() {
        for name in ["../../etc/x", "a/b", "..", ".", "名称", String(repeating: "a", count: 200)] {
            let stem = SubscriptionRuleSetService.fileStem(for: name)
            XCTAssertFalse(stem.contains("/"), name)
            XCTAssertFalse(stem.contains(".."), name)
            XCTAssertFalse(stem.hasPrefix("."), name)
            XCTAssertLessThanOrEqual(stem.count, 64, name)
        }
        XCTAssertEqual(SubscriptionRuleSetService.fileStem(for: "local-intranet"), "local-intranet", "安全名原样保留")
        XCTAssertNotEqual(SubscriptionRuleSetService.fileStem(for: "名称a"), SubscriptionRuleSetService.fileStem(for: "名称b"),
                          "不安全名取摘要，不同名不能撞")
    }

    func testOversizedDownloadIsRejected() async {
        server.serve("/big.yaml", "payload:\n" + String(repeating: "  - DOMAIN,a.example\n", count: 1_000_000))
        let result = await download([provider("big")])
        XCTAssertNil(result.prepared["big"])
        XCTAssertTrue(result.warnings.contains { $0.contains("big") })
    }

    func testRefreshIntervalHasFloorAndDefault() {
        XCTAssertEqual(SubscriptionRuleSetService.refreshInterval(for: provider("a", interval: 60)), 3_600, "过短的周期要抬到一小时")
        XCTAssertEqual(SubscriptionRuleSetService.refreshInterval(for: provider("a", interval: nil)), 86_400)
        XCTAssertEqual(SubscriptionRuleSetService.refreshInterval(for: provider("a", interval: 43_200)), 43_200)
    }

    func testRemoveCacheDeletesSourceDirectory() async throws {
        server.serve("/a.yaml", mixed)
        let result = await download([provider("a")])
        let file = try XCTUnwrap(result.prepared["a"]).routeFile
        await service.removeCache(sourceID: sourceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }
}
