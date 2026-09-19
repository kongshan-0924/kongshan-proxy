import XCTest
@testable import KongshanCore

/// 订阅里的 `RULE-SET` / `GEOIP` / `MATCH` 与 `rule-providers` 的解析。
///
/// 背景（2026-09-18）：此前解析器只认单条规则，RULE-SET / GEOIP / MATCH 一律丢弃。
/// 一份只写 RULE-SET 的订阅（真实案例：18 条规则里 16 条 RULE-SET + 1 GEOIP + 1 MATCH）
/// 于是被判为「没有自带规则」，AI / 流媒体 / 广告 / 直连名单全部失效。
final class SubscriptionRuleSetParsingTests: XCTestCase {
    // MARK: - 单行解析

    func testParsesRuleSetReference() throws {
        let rule = try XCTUnwrap(SubscriptionRule.parse("RULE-SET,ai,AI 服务"))
        XCTAssertEqual(rule.kind, .ruleSet)
        XCTAssertEqual(rule.value, "ai")
        XCTAssertEqual(rule.target, "AI 服务")
        XCTAssertNil(rule.type, "规则集引用没有单条规则类型")
    }

    func testParsesGeoIPIgnoringNoResolveOption() throws {
        let rule = try XCTUnwrap(SubscriptionRule.parse("GEOIP,cn,DIRECT,no-resolve"))
        XCTAssertEqual(rule.kind, .geoIP)
        XCTAssertEqual(rule.value, "CN", "国家码统一大写")
        XCTAssertEqual(rule.target, "DIRECT")
    }

    /// MATCH 不是一条规则，而是兜底出口：`parse` 不认它，`parseMatch` 取目标。
    func testMatchIsNotARuleButAFinalTarget() {
        XCTAssertNil(SubscriptionRule.parse("MATCH,漏网之鱼"))
        XCTAssertEqual(SubscriptionRule.parseMatch("MATCH,漏网之鱼"), "漏网之鱼")
        XCTAssertNil(SubscriptionRule.parseMatch("DOMAIN,example.com,DIRECT"))
    }

    /// 单条规则的解析与身份格式必须与改动前一致——去重与界面身份都依赖它。
    func testSingleRulesAreUnchanged() throws {
        let rule = try XCTUnwrap(SubscriptionRule.parse("DOMAIN-SUFFIX,example.com,Proxy"))
        XCTAssertEqual(rule.kind, .single(.domainSuffix))
        XCTAssertEqual(rule.type, .domainSuffix)
        XCTAssertEqual(rule.id, "domainSuffix|example.com|Proxy")
    }

    /// sing-box 的域名规则区分大小写（2026-09-18 实测），浏览器送来的域名总是小写：
    /// 单条规则里的大写域名必须规整，否则就是永远匹配不上的死规则。进程名大小写有意义，不动。
    func testSingleDomainRulesAreLowercasedButProcessNamesAreNot() throws {
        XCTAssertEqual(SubscriptionRule.parse("DOMAIN-SUFFIX,DSCloud.Example,Proxy")?.value, "dscloud.example")
        XCTAssertEqual(SubscriptionRule.parse("DOMAIN-KEYWORD,TrackER,Proxy")?.value, "tracker")
        XCTAssertEqual(SubscriptionRule.parse("PROCESS-NAME,SomeApp,DIRECT")?.value, "SomeApp")
    }

    func testRejectsMalformedLines() {
        XCTAssertNil(SubscriptionRule.parse("RULE-SET,,Proxy"), "空规则集名")
        XCTAssertNil(SubscriptionRule.parse("RULE-SET,ai"), "缺目标")
        XCTAssertNil(SubscriptionRule.parse("RULE-SET,ai,"), "空目标")
    }

    // MARK: - 整份订阅

    private func yaml(rules: [String], providers: String) -> String {
        """
        proxies:
          - {name: A, type: trojan, server: a.example.com, port: 443, password: p}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [A]}
          - {name: Direct, type: select, proxies: [DIRECT, Proxy]}
          - {name: Final, type: select, proxies: [Proxy, DIRECT]}
        rule-providers:
        \(providers)
        rules:
        \(rules.map { "  - \($0)" }.joined(separator: "\n"))
        """
    }

    private let aiProvider = """
          ai:
            type: http
            behavior: classical
            format: yaml
            url: https://rules.example.com/clash/ai.yaml
            path: ./ruleset/ai.yaml
            interval: 43200
          cn:
            type: http
            behavior: domain
            url: https://rules.example.com/clash/cn.txt
            format: text
    """

    func testReadsRuleProvidersReferencedByRules() throws {
        let result = try ClashSubscriptionConverter.convert(
            yaml: yaml(rules: ["RULE-SET,ai,Proxy", "RULE-SET,cn,Direct", "MATCH,Final"], providers: aiProvider),
            sourceID: UUID()
        )
        XCTAssertEqual(result.ruleProviders.map(\.name), ["ai", "cn"])
        let ai = try XCTUnwrap(result.ruleProviders.first { $0.name == "ai" })
        XCTAssertEqual(ai.behavior, .classical)
        XCTAssertEqual(ai.format, .yaml)
        XCTAssertEqual(ai.interval, 43_200)
        XCTAssertEqual(ai.url.absoluteString, "https://rules.example.com/clash/ai.yaml")
        let cn = try XCTUnwrap(result.ruleProviders.first { $0.name == "cn" })
        XCTAssertEqual(cn.behavior, .domain)
        XCTAssertEqual(cn.format, .text)
        XCTAssertNil(cn.interval)
        XCTAssertEqual(result.matchTarget, "Final")
    }

    /// 顺序就是语义：首个命中生效。单条规则、RULE-SET、GEOIP 混排时必须保持原顺序。
    func testPreservesOrderAcrossMixedRuleKinds() throws {
        let result = try ClashSubscriptionConverter.convert(
            yaml: yaml(
                rules: ["DOMAIN,a.example.com,Direct", "RULE-SET,ai,Proxy", "DOMAIN-SUFFIX,b.example.com,Proxy",
                        "RULE-SET,cn,Direct", "GEOIP,CN,Direct", "MATCH,Final"],
                providers: aiProvider
            ),
            sourceID: UUID()
        )
        XCTAssertEqual(result.subscriptionRules.map(\.value),
                       ["a.example.com", "ai", "b.example.com", "cn", "CN"])
    }

    /// 没被任何 RULE-SET 引用的规则集不下载——白白占网络与磁盘。
    func testUnreferencedProvidersAreDropped() throws {
        let result = try ClashSubscriptionConverter.convert(
            yaml: yaml(rules: ["RULE-SET,ai,Proxy"], providers: aiProvider),
            sourceID: UUID()
        )
        XCTAssertEqual(result.ruleProviders.map(\.name), ["ai"])
    }

    /// 引用了不存在的规则集：丢掉这条 RULE-SET 并告警。引用不存在的规则集会让内核整份拒绝配置。
    func testDanglingRuleSetReferenceIsDroppedWithWarning() throws {
        let result = try ClashSubscriptionConverter.convert(
            yaml: yaml(rules: ["RULE-SET,ai,Proxy", "RULE-SET,nosuch,Proxy"], providers: aiProvider),
            sourceID: UUID()
        )
        XCTAssertEqual(result.subscriptionRules.map(\.value), ["ai"])
        XCTAssertTrue(result.warnings.contains { $0.contains("nosuch") }, "\(result.warnings)")
    }

    /// 不支持的规则集形态（mihomo 二进制 mrs、服务器本机 file）：跳过并说明原因，引用它的规则一并跳过。
    func testUnsupportedProviderFormatsAreSkippedWithReason() throws {
        let providers = """
              bin:
                type: http
                behavior: domain
                format: mrs
                url: https://rules.example.com/bin.mrs
              local:
                type: file
                behavior: classical
                path: ./local.yaml
        """
        let result = try ClashSubscriptionConverter.convert(
            yaml: yaml(rules: ["RULE-SET,bin,Proxy", "RULE-SET,local,Direct", "DOMAIN,x.example.com,Proxy"],
                       providers: providers),
            sourceID: UUID()
        )
        XCTAssertTrue(result.ruleProviders.isEmpty)
        XCTAssertEqual(result.subscriptionRules.map(\.value), ["x.example.com"])
        let warning = result.warnings.joined()
        XCTAssertTrue(warning.contains("format=mrs"), warning)
        XCTAssertTrue(warning.contains("type=file"), warning)
    }

    func testRejectsNonHTTPProviderURL() {
        let parsed = SubscriptionRuleProvider.parse(
            name: "x", entry: ["type": "http", "behavior": "domain", "url": "file:///etc/passwd"]
        )
        XCTAssertNil(parsed.provider)
        XCTAssertNotNil(parsed.reason)
    }

    /// MATCH 被取作兜底出口，不该算进「跳过/不支持」的规则数里。
    func testMatchIsNotCountedAsSkipped() throws {
        let result = try ClashSubscriptionConverter.convert(
            yaml: yaml(rules: ["RULE-SET,ai,Proxy", "MATCH,Final", "UNKNOWN-TYPE,x,Proxy"], providers: aiProvider),
            sourceID: UUID()
        )
        let compat = result.warnings.first { $0.contains("订阅兼容性") } ?? ""
        XCTAssertTrue(compat.contains("1 条由内置规则接管或不支持"), compat)
    }
}
