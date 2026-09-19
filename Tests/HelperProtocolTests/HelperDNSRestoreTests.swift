import XCTest
@testable import HelperProtocol

/// F1：App 异常退出后由助手还原系统 DNS。
///
/// 这段逻辑**以 root 执行、输入来自用户可写的 JSON 文件**，所以每个拒绝分支都得守住。
final class HelperDNSRestoreTests: XCTestCase {
    private let known: Set<String> = ["Wi-Fi", "Thunderbolt Bridge", "LAN"]

    private func snapshot(_ services: [(String, [String])], version: Int? = 1) -> HelperDNSRestore.Snapshot {
        HelperDNSRestore.Snapshot(
            version: version,
            services: services.map { .init(name: $0.0, servers: $0.1) }
        )
    }

    // MARK: - 服务名解析

    func testParsesServiceNamesIncludingDisabledOnes() {
        let output = """
        An asterisk (*) denotes that a network service is disabled.
        Wi-Fi
        *Thunderbolt Bridge
        LAN
        """
        // 被禁用的服务照样要能还原：禁用不等于不存在，它上面一样可能留着指向已死 TUN 的 DNS。
        XCTAssertEqual(HelperNetworkServices.allNames(from: output), known)
    }

    func testIgnoresBlankLinesAndHeader() {
        XCTAssertEqual(HelperNetworkServices.allNames(from: "An asterisk (*) denotes\n\n  \n"), [])
    }

    // MARK: - 放行

    func testRestoresServersForKnownService() {
        let commands = HelperDNSRestore.restoreArguments(
            snapshot: snapshot([("Wi-Fi", ["192.168.1.1", "8.8.8.8"])]),
            knownServiceNames: known
        )
        XCTAssertEqual(commands, [["-setdnsservers", "Wi-Fi", "192.168.1.1", "8.8.8.8"]])
    }

    /// 快照里空列表代表"接管前就没有手动 DNS"，还原成 `Empty`（与 App 侧写法一致）。
    func testEmptyServerListRestoresToEmptyKeyword() {
        let commands = HelperDNSRestore.restoreArguments(
            snapshot: snapshot([("LAN", [])]),
            knownServiceNames: known
        )
        XCTAssertEqual(commands, [["-setdnsservers", "LAN", "Empty"]])
    }

    func testAcceptsIPv6Literals() {
        let commands = HelperDNSRestore.restoreArguments(
            snapshot: snapshot([("Wi-Fi", ["2001:4860:4860::8888"])]),
            knownServiceNames: known
        )
        XCTAssertEqual(commands.count, 1)
    }

    // MARK: - 拒绝

    /// 服务名必须逐字命中实时列表——这一条同时挡住"不存在的服务"和"把选项塞进服务名"。
    func testUnknownServiceIsSkipped() {
        XCTAssertTrue(HelperDNSRestore.restoreArguments(
            snapshot: snapshot([("Nope", ["8.8.8.8"])]),
            knownServiceNames: known
        ).isEmpty)
    }

    func testOptionInjectionViaServiceNameIsSkipped() {
        XCTAssertTrue(HelperDNSRestore.restoreArguments(
            snapshot: snapshot([("-setairportpower", ["8.8.8.8"])]),
            knownServiceNames: known
        ).isEmpty)
    }

    /// 任一地址非法 → **整条服务跳过**，不做部分执行：留下一半正确的 DNS 比不动更难排查。
    func testAnyInvalidServerSkipsWholeService() {
        for bad in ["8.8.8.8 ", "not-an-ip", "8.8.8.8:53", "192.168.1.0/24", "-setdnsservers", ""] {
            XCTAssertTrue(
                HelperDNSRestore.restoreArguments(
                    snapshot: snapshot([("Wi-Fi", ["1.1.1.1", bad])]),
                    knownServiceNames: known
                ).isEmpty,
                "「\(bad)」不该被当成合法 DNS 地址"
            )
        }
    }

    func testUnsupportedSnapshotVersionRestoresNothing() {
        XCTAssertTrue(HelperDNSRestore.restoreArguments(
            snapshot: snapshot([("Wi-Fi", ["8.8.8.8"])], version: 99),
            knownServiceNames: known
        ).isEmpty, "格式变了而助手没跟上时，宁可不动也不要按旧理解写系统设置")
    }

    func testDuplicateServiceEntriesAreAppliedOnce() {
        let commands = HelperDNSRestore.restoreArguments(
            snapshot: snapshot([("Wi-Fi", ["1.1.1.1"]), ("Wi-Fi", ["8.8.8.8"])]),
            knownServiceNames: known
        )
        XCTAssertEqual(commands, [["-setdnsservers", "Wi-Fi", "1.1.1.1"]])
    }

    /// 真实快照的多余字段（capturedAt 等）不能让解码失败。
    func testDecodesRealSnapshotShape() throws {
        let json = """
        {"capturedAt":811259756.502829,"services":[{"name":"LAN","servers":[]}],"version":1}
        """
        let decoded = try JSONDecoder().decode(HelperDNSRestore.Snapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.services.count, 1)
        XCTAssertEqual(decoded.version, 1)
    }
}
