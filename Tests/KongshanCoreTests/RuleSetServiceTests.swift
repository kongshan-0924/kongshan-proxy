import Foundation
import XCTest
@testable import KongshanCore

final class RuleSetServiceTests: XCTestCase {
    func testSuccessfulDownloadsReplaceAllRequestedCaches() async throws {
        let fixture = try makeFixture(old: Data("old".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = ValidationRecorder()
        let service = RuleSetService(
            storage: fixture.storage,
            loader: { url in HTTPDownload(data: Data("new-\(url.lastPathComponent)".utf8), statusCode: 200) },
            validator: { url in try recorder.record(Data(contentsOf: url)) }
        )

        let result = try await service.prepare(includeAds: true, forceRefresh: true)

        XCTAssertEqual(result.ruleSets.geositeCN, cacheURL("geosite-cn", in: fixture.root))
        XCTAssertEqual(result.ruleSets.geoipCN, cacheURL("geoip-cn", in: fixture.root))
        XCTAssertEqual(result.ruleSets.ads, cacheURL("geosite-category-ads-all", in: fixture.root))
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(try String(contentsOf: result.ruleSets.geositeCN, encoding: .utf8), "new-geosite-cn.srs")
        XCTAssertEqual(try String(contentsOf: result.ruleSets.geoipCN, encoding: .utf8), "new-geoip-cn.srs")
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(result.ruleSets.ads), encoding: .utf8), "new-geosite-category-ads-all.srs")
        XCTAssertEqual(recorder.values.count, 3)
    }

    func testCacheFirstReturnsCacheWithoutDownloadingOrRevalidating() async throws {
        // 缓存优先：有缓存且非强制刷新时，启动路径不发起下载、也不重复校验（省时间）。
        let fixture = try makeFixture(old: Data("cached".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = ValidationRecorder()
        let service = RuleSetService(
            storage: fixture.storage,
            loader: { _ in
                XCTFail("有缓存且非强制刷新时不应发起下载")
                return HTTPDownload(data: Data(), statusCode: 200)
            },
            validator: { url in try recorder.record(Data(contentsOf: url)) }
        )

        let result = try await service.prepare(includeAds: false)

        XCTAssertEqual(try Data(contentsOf: result.ruleSets.geositeCN), Data("cached".utf8))
        XCTAssertEqual(recorder.values.count, 0)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testHTTPFailureUsesCacheOnlyAfterValidatingItAgain() async throws {
        let fixture = try makeFixture(old: Data("valid-old".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = ValidationRecorder()
        let service = RuleSetService(
            storage: fixture.storage,
            loader: { _ in HTTPDownload(data: Data("server-error".utf8), statusCode: 503) },
            validator: { url in try recorder.record(Data(contentsOf: url)) }
        )

        let result = try await service.prepare(includeAds: false, forceRefresh: true)

        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertTrue(result.warnings.allSatisfy { $0.contains("缓存") })
        XCTAssertEqual(recorder.values, [Data("valid-old".utf8), Data("valid-old".utf8)])
    }

    func testEmptyDownloadUsesOldCacheWithoutOverwritingIt() async throws {
        let fixture = try makeFixture(old: Data("valid-old".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = RuleSetService(
            storage: fixture.storage,
            loader: { _ in HTTPDownload(data: Data(), statusCode: 200) },
            validator: { _ in }
        )

        let result = try await service.prepare(includeAds: false, forceRefresh: true)

        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertEqual(try Data(contentsOf: result.ruleSets.geositeCN), Data("valid-old".utf8))
        XCTAssertEqual(try Data(contentsOf: result.ruleSets.geoipCN), Data("valid-old".utf8))
    }

    func testInvalidDownloadDoesNotOverwriteValidatedCache() async throws {
        let fixture = try makeFixture(old: Data("valid-old".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = ValidationRecorder(rejecting: Data("invalid-new".utf8))
        let service = RuleSetService(
            storage: fixture.storage,
            loader: { _ in HTTPDownload(data: Data("invalid-new".utf8), statusCode: 200) },
            validator: { url in try recorder.record(Data(contentsOf: url)) }
        )

        let result = try await service.prepare(includeAds: false, forceRefresh: true)

        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertEqual(try Data(contentsOf: result.ruleSets.geositeCN), Data("valid-old".utf8))
        XCTAssertEqual(recorder.values, [
            Data("invalid-new".utf8), Data("valid-old".utf8),
            Data("invalid-new".utf8), Data("valid-old".utf8)
        ])
    }

    func testInvalidCacheIsNotUsedAfterDownloadFailure() async throws {
        let fixture = try makeFixture(old: Data("invalid-old".utf8))
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let recorder = ValidationRecorder(rejecting: Data("invalid-old".utf8))
        let service = RuleSetService(
            storage: fixture.storage,
            loader: { _ in throw URLError(.notConnectedToInternet) },
            validator: { url in try recorder.record(Data(contentsOf: url)) }
        )

        do {
            _ = try await service.prepare(includeAds: false, forceRefresh: true)
            XCTFail("Expected unusable cache failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("geosite-cn"))
            XCTAssertTrue(error.localizedDescription.contains("缓存"))
        }
        XCTAssertEqual(recorder.values, [Data("invalid-old".utf8)])
    }

    func testFailureWithoutCacheIsReported() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let service = RuleSetService(
            storage: fixture.storage,
            loader: { _ in throw URLError(.timedOut) },
            validator: { _ in }
        )

        do {
            _ = try await service.prepare(includeAds: false, forceRefresh: true)
            XCTFail("Expected missing cache failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("geosite-cn"))
            XCTAssertTrue(error.localizedDescription.contains("缓存"))
        }
    }

    func testDefaultValidatorAcceptsRuleSetCompiledByBundledCore() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let binaryData = try await compiledRuleSet(in: fixture.root)
        let service = RuleSetService(
            storage: fixture.storage,
            binaryURL: singBoxURL,
            loader: { _ in HTTPDownload(data: binaryData, statusCode: 200) }
        )

        let result = try await service.prepare(includeAds: false, forceRefresh: true)

        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: result.ruleSets.geositeCN), binaryData)
    }

    private func makeFixture(old: Data? = nil) throws -> (root: URL, storage: Storage) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let storage = Storage(rootDirectory: root)
        let directory = root.appending(path: "rule-sets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let old {
            for tag in ["geosite-cn", "geoip-cn", "geosite-category-ads-all"] {
                try old.write(to: cacheURL(tag, in: root))
            }
        }
        return (root, storage)
    }

    private func cacheURL(_ tag: String, in root: URL) -> URL {
        root.appending(path: "rule-sets/\(tag).srs")
    }

    private func compiledRuleSet(in directory: URL) async throws -> Data {
        let source = directory.appending(path: "source.json")
        let output = directory.appending(path: "compiled.srs")
        try Data(#"{"version":3,"rules":[{"domain_suffix":["example.com"]}]}"#.utf8).write(to: source)
        let result = try await ProcessRunner.run(
            executable: singBoxURL,
            arguments: ["rule-set", "compile", source.path, "-o", output.path],
            timeout: 10
        )
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        return try Data(contentsOf: output)
    }

    private var singBoxURL: URL {
        packageRoot.appending(path: "Vendor/sing-box/sing-box")
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class ValidationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let rejectedValue: Data?
    private var recordedValues: [Data] = []

    init(rejecting rejectedValue: Data? = nil) {
        self.rejectedValue = rejectedValue
    }

    var values: [Data] {
        lock.withLock { recordedValues }
    }

    func record(_ value: Data) throws {
        try lock.withLock {
            recordedValues.append(value)
            if value == rejectedValue { throw ValidationError.rejected }
        }
    }

    private enum ValidationError: Error {
        case rejected
    }
}
