import XCTest
@testable import HelperProtocol

/// §5.2 对端身份判定纯逻辑：覆盖每个拒绝分支 + 放行条件。
final class HelperTrustEvaluationTests: XCTestCase {
    private let trust = HelperTrustConfig(
        clientExecutablePath: "/Applications/kongshan.app/Contents/MacOS/kongshan"
    )
    private let expectedPath = "/Applications/kongshan.app/Contents/MacOS/kongshan"
    private let expectedIdentifier = HelperConstants.clientSigningIdentifier

    // MARK: - 放行

    func testAllChecksPassWithoutCDHashPinIsTrusted() {
        let identity = HelperClientIdentity(
            signatureValid: true,
            signingIdentifier: expectedIdentifier,
            executablePath: expectedPath,
            cdHashHex: "abcdef0123456789"
        )
        XCTAssertTrue(HelperTrustEvaluation.isTrusted(identity: identity, trust: trust))
    }

    func testCDHashPinnedAndMatchedIsTrusted() {
        let pinned = HelperTrustConfig(
            clientExecutablePath: expectedPath,
            pinnedCDHashHex: "ABCDEF0123456789"
        )
        let identity = HelperClientIdentity(
            signatureValid: true,
            signingIdentifier: expectedIdentifier,
            executablePath: expectedPath,
            cdHashHex: "abcdef0123456789"  // 小写，应与 pinned 大写匹配
        )
        XCTAssertTrue(HelperTrustEvaluation.isTrusted(identity: identity, trust: pinned))
    }

    // MARK: - 拒绝分支（§1.2 拒绝优先，任一不过即 false）

    func testInvalidSignatureRejected() {
        let identity = HelperClientIdentity(
            signatureValid: false,
            signingIdentifier: expectedIdentifier,
            executablePath: expectedPath,
            cdHashHex: nil
        )
        XCTAssertFalse(HelperTrustEvaluation.isTrusted(identity: identity, trust: trust))
    }

    func testWrongIdentifierRejected() {
        let identity = HelperClientIdentity(
            signatureValid: true,
            signingIdentifier: "com.evil.app",
            executablePath: expectedPath,
            cdHashHex: nil
        )
        XCTAssertFalse(HelperTrustEvaluation.isTrusted(identity: identity, trust: trust))
    }

    func testNilIdentifierRejected() {
        let identity = HelperClientIdentity(
            signatureValid: true,
            signingIdentifier: nil,
            executablePath: expectedPath,
            cdHashHex: nil
        )
        XCTAssertFalse(HelperTrustEvaluation.isTrusted(identity: identity, trust: trust))
    }

    func testWrongExecutablePathRejected() {
        let identity = HelperClientIdentity(
            signatureValid: true,
            signingIdentifier: expectedIdentifier,
            executablePath: "/Applications/evil.app/Contents/MacOS/evil",
            cdHashHex: nil
        )
        XCTAssertFalse(HelperTrustEvaluation.isTrusted(identity: identity, trust: trust))
    }

    func testNilExecutablePathRejected() {
        let identity = HelperClientIdentity(
            signatureValid: true,
            signingIdentifier: expectedIdentifier,
            executablePath: nil,
            cdHashHex: nil
        )
        XCTAssertFalse(HelperTrustEvaluation.isTrusted(identity: identity, trust: trust))
    }

    func testCDHashPinnedButMismatchedRejected() {
        let pinned = HelperTrustConfig(
            clientExecutablePath: expectedPath,
            pinnedCDHashHex: "abcdef0123456789"
        )
        let identity = HelperClientIdentity(
            signatureValid: true,
            signingIdentifier: expectedIdentifier,
            executablePath: expectedPath,
            cdHashHex: "deadbeef"
        )
        XCTAssertFalse(HelperTrustEvaluation.isTrusted(identity: identity, trust: pinned))
    }

    func testCDHashPinnedButIdentityHasNoCDHashRejected() {
        let pinned = HelperTrustConfig(
            clientExecutablePath: expectedPath,
            pinnedCDHashHex: "abcdef0123456789"
        )
        let identity = HelperClientIdentity(
            signatureValid: true,
            signingIdentifier: expectedIdentifier,
            executablePath: expectedPath,
            cdHashHex: nil
        )
        XCTAssertFalse(HelperTrustEvaluation.isTrusted(identity: identity, trust: pinned))
    }

    func testEmptyPinnedCDHashTreatedAsUnpinned() {
        // pinnedCDHashHex 为空字符串视为不钉（与 nil 同），其他条件满足则放行。
        let pinned = HelperTrustConfig(
            clientExecutablePath: expectedPath,
            pinnedCDHashHex: ""
        )
        let identity = HelperClientIdentity(
            signatureValid: true,
            signingIdentifier: expectedIdentifier,
            executablePath: expectedPath,
            cdHashHex: nil
        )
        XCTAssertTrue(HelperTrustEvaluation.isTrusted(identity: identity, trust: pinned))
    }
}

/// §5.3 请求分发纯逻辑：未鉴权一律拒、各请求在各状态下正确分发。
final class HelperDecisionTests: XCTestCase {
    // MARK: - 未鉴权：所有请求一律拒（§1.2，连 status 都不回）

    func testUnauthenticatedStatusRejected() {
        let decision = HelperDecision.decide(request: .status, isTrusted: false, hasConfigFD: false, kernelRunning: false)
        XCTAssertEqual(decision, .reject(message: "unauthorized"))
    }

    func testUnauthenticatedStartTunRejected() {
        let decision = HelperDecision.decide(request: .startTun, isTrusted: false, hasConfigFD: true, kernelRunning: false)
        XCTAssertEqual(decision, .reject(message: "unauthorized"))
    }

    func testUnauthenticatedStopTunRejected() {
        let decision = HelperDecision.decide(request: .stopTun, isTrusted: false, hasConfigFD: false, kernelRunning: true)
        XCTAssertEqual(decision, .reject(message: "unauthorized"))
    }

    // MARK: - status

    func testStatusWhenTrustedRepliesStatus() {
        let decision = HelperDecision.decide(request: .status, isTrusted: true, hasConfigFD: false, kernelRunning: false)
        XCTAssertEqual(decision, .replyStatus)
    }

    // MARK: - startTun

    func testStartTunWithoutConfigFDRejected() {
        let decision = HelperDecision.decide(request: .startTun, isTrusted: true, hasConfigFD: false, kernelRunning: false)
        XCTAssertEqual(decision, .reject(message: "missing config fd"))
    }

    func testStartTunWithFDWhenIdleStartsKernel() {
        let decision = HelperDecision.decide(request: .startTun, isTrusted: true, hasConfigFD: true, kernelRunning: false)
        XCTAssertEqual(decision, .startKernel)
    }

    func testStartTunWithFDWhenRunningRejected() {
        let decision = HelperDecision.decide(request: .startTun, isTrusted: true, hasConfigFD: true, kernelRunning: true)
        XCTAssertEqual(decision, .reject(message: "kernel already running"))
    }

    func testStartTunWithoutFDWhenRunningRejectsForFDFirst() {
        // 无 FD 优先于 kernelRunning 检查（先 guard hasConfigFD）。
        let decision = HelperDecision.decide(request: .startTun, isTrusted: true, hasConfigFD: false, kernelRunning: true)
        XCTAssertEqual(decision, .reject(message: "missing config fd"))
    }

    // MARK: - stopTun

    func testStopTunWhenIdleRejected() {
        let decision = HelperDecision.decide(request: .stopTun, isTrusted: true, hasConfigFD: false, kernelRunning: false)
        XCTAssertEqual(decision, .reject(message: "no kernel running"))
    }

    func testStopTunWhenRunningStopsKernel() {
        let decision = HelperDecision.decide(request: .stopTun, isTrusted: true, hasConfigFD: false, kernelRunning: true)
        XCTAssertEqual(decision, .stopKernel)
    }
}

/// §5.4 trust.json 缺失/损坏 → helper 拒绝。通过验证 HelperTrustConfig 的解码行为
/// 间接覆盖（helper 的 loadTrustConfig 用 JSONDecoder 解码，失败返回 nil → 一律拒绝）。
final class HelperTrustConfigDecodingTests: XCTestCase {
    func testValidTrustConfigDecodes() throws {
        let json = #"{"clientExecutablePath":"/Applications/kongshan.app/Contents/MacOS/kongshan","pinnedCDHashHex":null}"#
        let config = try JSONDecoder().decode(HelperTrustConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.clientExecutablePath, "/Applications/kongshan.app/Contents/MacOS/kongshan")
        XCTAssertNil(config.pinnedCDHashHex)
    }

    func testTrustConfigWithoutCDHashFieldDecodesWithNil() throws {
        // 旧版/精简 trust.json 不含 pinnedCDHashHex，应解码为 nil（不钉 cdhash）。
        let json = #"{"clientExecutablePath":"/Applications/kongshan.app/Contents/MacOS/kongshan"}"#
        let config = try JSONDecoder().decode(HelperTrustConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.clientExecutablePath, "/Applications/kongshan.app/Contents/MacOS/kongshan")
        XCTAssertNil(config.pinnedCDHashHex)
    }

    func testCorruptedJSONThrows() {
        let corrupted = #"{"clientExecutablePath": broken json"#
        XCTAssertThrowsError(try JSONDecoder().decode(HelperTrustConfig.self, from: Data(corrupted.utf8)))
    }

    func testMissingClientExecutablePathThrows() {
        // 缺必需字段 clientExecutablePath → 解码失败 → helper 视作 trust 损坏，拒绝。
        let json = #"{"pinnedCDHashHex":null}"#
        XCTAssertThrowsError(try JSONDecoder().decode(HelperTrustConfig.self, from: Data(json.utf8)))
    }

    func testEmptyDataThrows() {
        // trust.json 为空文件 → 解码失败 → helper 拒绝。
        XCTAssertThrowsError(try JSONDecoder().decode(HelperTrustConfig.self, from: Data()))
    }
}
