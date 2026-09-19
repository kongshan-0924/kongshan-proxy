import XCTest
@testable import KongshanCore

/// 规则页「命中测试」对订阅规则集的判定（第 9 点）。
/// 此前求值器只看单条规则：规则集订阅的每一次测试都会落到「最终规则」，结果与内核不符。
final class RuleSetRouteEvaluationTests: XCTestCase {
    private func content(_ lines: String) throws -> RuleSetContent {
        try ClashRuleSetConverter.convert(Data("payload:\n\(lines)".utf8), behavior: .classical, format: .yaml).content
    }

    private var contents: [String: RuleSetContent] {
        get throws {
            [
                "ai": try content("  - DOMAIN-SUFFIX,openai.example\n  - DOMAIN,chat.ai.example"),
                "proxy": try content("  - DOMAIN-SUFFIX,both.example\n  - IP-CIDR,203.0.113.0/24"),
                "cn": try content("  - DOMAIN-SUFFIX,both.example\n  - DOMAIN-SUFFIX,cn.example\n  - PROCESS-NAME,LocalApp"),
            ]
        }
    }

    private let rules = [
        SubscriptionRule(kind: .ruleSet, value: "ai", target: "AI"),
        SubscriptionRule(kind: .ruleSet, value: "proxy", target: "节点选择"),
        SubscriptionRule(kind: .ruleSet, value: "cn", target: "DIRECT"),
        SubscriptionRule(kind: .geoIP, value: "CN", target: "DIRECT"),
    ]

    private func evaluate(_ input: RouteTestInput, match: String? = "漏网之鱼",
                          contents: [String: RuleSetContent]? = nil, subscriptionRulesOn: Bool = true) throws -> RouteTestResult {
        var settings = RoutingSettings.defaults
        settings.useSubscriptionRules = subscriptionRulesOn
        return RouteRuleEvaluator.evaluate(
            input, settings: settings, subscriptionRules: rules,
            ruleSetContents: try contents ?? self.contents, matchTarget: match, primaryOutbound: "节点选择"
        )
    }

    func testRuleSetHitReportsWhichEntryMatched() throws {
        let result = try evaluate(RouteTestInput(domain: "api.openai.example"))
        XCTAssertEqual(result.source, .subscription)
        XCTAssertEqual(result.target, "AI")
        XCTAssertEqual(result.matchedValue, "规则集 ai：域名后缀 openai.example")
    }

    /// 顺序即语义：同时在 proxy 与 cn 里的域名，先命中的 proxy 生效（与内核一致）。
    func testEarlierRuleSetWins() throws {
        let result = try evaluate(RouteTestInput(domain: "www.both.example"))
        XCTAssertEqual(result.target, "节点选择")
        XCTAssertTrue(result.matchedValue.hasPrefix("规则集 proxy"))
    }

    func testIPAndProcessEntriesInRuleSets() throws {
        XCTAssertEqual(try evaluate(RouteTestInput(ip: "203.0.113.9")).target, "节点选择")
        let process = try evaluate(RouteTestInput(processName: "LocalApp"))
        XCTAssertEqual(process.action, .direct)
        XCTAssertEqual(process.matchedValue, "规则集 cn：进程 LocalApp")
    }

    /// 没就绪（内容缺失）的规则集视为未命中——内核里它也被跳过了。
    func testMissingContentIsTreatedAsNotMatching() throws {
        var partial = try contents
        partial["ai"] = nil
        XCTAssertEqual(try evaluate(RouteTestInput(domain: "api.openai.example"), contents: partial).source, .final)
    }

    /// 后缀要带点边界：`openai.example` 不能匹配 `notopenai.example`。
    func testSuffixRequiresLabelBoundary() throws {
        XCTAssertEqual(try evaluate(RouteTestInput(domain: "notopenai.example")).source, .final)
        XCTAssertEqual(try evaluate(RouteTestInput(domain: "openai.example")).target, "AI", "后缀也匹配本身")
    }

    /// mihomo 的 `.a.com` 只匹配子域；转换后以点开头的后缀保持这个语义。
    func testLeadingDotSuffixMatchesSubdomainsOnly() {
        XCTAssertTrue(RuleSetContent.suffix(".dot.example", matches: "a.dot.example"))
        XCTAssertFalse(RuleSetContent.suffix(".dot.example", matches: "dot.example"))
        XCTAssertTrue(RuleSetContent.suffix("dot.example", matches: "dot.example"))
    }

    /// 国家 IP 库归内核所有，本地不猜：GEOIP 永不在求值器里命中。
    func testGeoIPIsNeverGuessed() throws {
        XCTAssertEqual(try evaluate(RouteTestInput(ip: "1.0.1.1")).source, .final)
    }

    func testFinalUsesMatchTarget() throws {
        let result = try evaluate(RouteTestInput(domain: "unlisted.example"))
        XCTAssertEqual(result.source, .final)
        XCTAssertEqual(result.target, "漏网之鱼")
        XCTAssertEqual(result.matchedValue, "MATCH")
    }

    func testFinalFallsBackToPrimaryWithoutMatch() throws {
        let result = try evaluate(RouteTestInput(domain: "unlisted.example"), match: nil)
        XCTAssertEqual(result.target, "节点选择")
        XCTAssertEqual(result.matchedValue, "FINAL")
    }

    /// 关掉「应用订阅规则」时 MATCH 也不生效，与生成的配置一致。
    func testMatchIgnoredWhenSubscriptionRulesOff() throws {
        let result = try evaluate(RouteTestInput(domain: "api.openai.example"), subscriptionRulesOn: false)
        XCTAssertEqual(result.source, .final)
        XCTAssertEqual(result.target, "节点选择")
    }
}
