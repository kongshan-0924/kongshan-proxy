import XCTest
@testable import KongshanCore

/// F3：订阅是外部不可信输入，解析前必须封顶。
///
/// 2026-09-17 审计探针实测：8 路扇出嵌套 6 层、**290 字节**的 YAML，
/// `Yams.load` 展开出 210 万个元素、耗时 0.74 秒；每多一层 ×8，嵌套 8 层即 1.3 亿个元素。
final class SubscriptionInputLimitsTests: XCTestCase {
    private func bomb(depth: Int, fanout: Int = 8) -> String {
        var text = "a0: &a0 [" + Array(repeating: "x", count: fanout).joined(separator: ",") + "]\n"
        for level in 1...depth {
            text += "a\(level): &a\(level) ["
                + Array(repeating: "*a\(level - 1)", count: fanout).joined(separator: ",") + "]\n"
        }
        return text + "proxies: []\n"
    }

    // MARK: - 别名炸弹

    func testAliasBombIsRejectedBeforeParsing() {
        for depth in [4, 6, 8, 10] {
            XCTAssertThrowsError(
                try ClashSubscriptionConverter.convert(yaml: bomb(depth: depth), sourceID: UUID()),
                "深度 \(depth) 的别名炸弹必须在解析前被拒"
            ) { error in
                guard case SubscriptionConversionError.tooManyAliasReferences = error else {
                    return XCTFail("应因别名引用过多被拒，实际：\(error)")
                }
            }
        }
    }

    /// **不能按 `*` 裸数**：Clash 规则里 `*.google.com` 这种通配域名到处都是，
    /// 裸数会把正常订阅全部误杀。必须先认锚点定义再数引用。
    func testWildcardDomainRulesAreNotCountedAsAliases() {
        var yaml = "proxies:\n  - {name: A, type: trojan, server: a.com, port: 443, password: p}\nrules:"
        for index in 0..<500 { yaml += "\n  - DOMAIN-SUFFIX,*.site\(index).com,DIRECT" }
        XCTAssertTrue(SubscriptionInputLimits.anchorNames(in: yaml).isEmpty)
        XCTAssertEqual(SubscriptionInputLimits.aliasReferenceCount(in: yaml), 0, "500 个通配符不该被当成别名")
        XCTAssertNoThrow(try SubscriptionInputLimits.validate(yaml: yaml))
    }

    func testAliasCountBoundaryIsExact() {
        func document(references: Int) -> String {
            var text = "base: &base value\n"
            for index in 0..<references { text += "k\(index): *base\n" }
            return text
        }
        let limit = SubscriptionInputLimits.aliasReferenceLimit
        XCTAssertNoThrow(try SubscriptionInputLimits.validate(yaml: document(references: limit)))
        XCTAssertThrowsError(try SubscriptionInputLimits.validate(yaml: document(references: limit + 1)))
    }

    /// 只有被定义过的锚点才算引用——`*未定义` 不是别名，不该计数。
    func testUndefinedAnchorReferenceIsNotCounted() {
        XCTAssertEqual(SubscriptionInputLimits.aliasReferenceCount(in: "k: *nosuch\n"), 0)
    }

    // MARK: - 体积

    func testOversizedDocumentIsRejected() {
        let huge = String(repeating: "#", count: SubscriptionInputLimits.documentByteLimit + 1)
        XCTAssertThrowsError(try SubscriptionInputLimits.validate(yaml: huge)) { error in
            guard case SubscriptionConversionError.documentTooLarge = error else {
                return XCTFail("应因体积超限被拒，实际：\(error)")
            }
        }
    }

    func testTypicalSubscriptionSizePasses() {
        // 真实机场订阅约 100–500 KB，必须远在上限之内。
        XCTAssertNoThrow(try SubscriptionInputLimits.validate(yaml: String(repeating: "a", count: 512 * 1024)))
    }
}
