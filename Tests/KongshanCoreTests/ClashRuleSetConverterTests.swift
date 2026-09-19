import XCTest
@testable import KongshanCore

/// Clash 规则集 → sing-box 规则集。
///
/// 实现前用真实订阅的 16 份规则集做过对照：以内核编译再反编译的结果为准，
/// 14 份与服务端自己生成的 sing-box 版本逐字一致；`cn` 仅关键词列表顺序不同（「或」关系，语义相同）；
/// `unban` 的差异是服务端保留了 11 个大写域名——而内核实测区分大小写，那 11 条在服务端版本里是死规则。
final class ClashRuleSetConverterTests: XCTestCase {
    private func convert(_ text: String, _ behavior: SubscriptionRuleProvider.Behavior = .classical,
                         _ format: SubscriptionRuleProvider.Format = .yaml) throws -> ClashRuleSetConverter.Result {
        try ClashRuleSetConverter.convert(Data(text.utf8), behavior: behavior, format: format)
    }

    // MARK: - classical

    func testClassicalMapsEverySupportedType() throws {
        let result = try convert("""
        # 注释行
        payload:
          - DOMAIN,exact.example.com
          - DOMAIN-SUFFIX,example.org
          - DOMAIN-KEYWORD,tracker
          - DOMAIN-REGEX,^ad[0-9]+\\\\.example\\\\.net$
          - IP-CIDR,10.1.0.0/16,no-resolve
          - IP-CIDR6,2001:db8::/32
          - PROCESS-NAME,SomeApp
          - PROCESS-PATH,/Applications/Some.app/Contents/MacOS/Some
        """)
        let c = result.content
        XCTAssertEqual(c.domain, ["exact.example.com"])
        XCTAssertEqual(c.domainSuffix, ["example.org"])
        XCTAssertEqual(c.domainKeyword, ["tracker"])
        XCTAssertEqual(c.domainRegex.count, 1)
        XCTAssertEqual(c.ipCIDR, ["10.1.0.0/16", "2001:db8::/32"], "no-resolve 选项要剥掉")
        XCTAssertEqual(c.processName, ["SomeApp"], "进程名大小写有意义，不能规整")
        XCTAssertEqual(c.processPath, ["/Applications/Some.app/Contents/MacOS/Some"])
        XCTAssertTrue(result.skipped.isEmpty)
    }

    /// **核心回归**：进程条件必须单独成条。与域名写进同一条，sing-box 会按「与」理解，
    /// 直连名单就只对名单里的进程生效——服务端曾因此踩坑。
    func testProcessConditionsAreSeparateRules() throws {
        let source = try convert("""
        payload:
          - DOMAIN-SUFFIX,example.org
          - IP-CIDR,10.0.0.0/8
          - PROCESS-NAME,SomeApp
          - PROCESS-PATH,/usr/bin/some
        """).content.singBoxSource()
        let rules = try XCTUnwrap(source["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 3)
        XCTAssertNotNil(rules[0]["domain_suffix"])
        XCTAssertNotNil(rules[0]["ip_cidr"], "域名与 IP 在 sing-box 里同属「或」组，可以同条")
        XCTAssertNil(rules[0]["process_name"])
        XCTAssertEqual(Set(rules[1].keys), ["process_name"])
        XCTAssertEqual(Set(rules[2].keys), ["process_path"])
    }

    /// 内核实测区分大小写：规则里的大写域名是死规则，必须规整成小写。
    func testDomainsAreLowercased() throws {
        let c = try convert("""
        payload:
          - DOMAIN-SUFFIX,DSCloud.Example
          - DOMAIN,Mixed.Example.COM
          - DOMAIN-KEYWORD,TrackER
        """).content
        XCTAssertEqual(c.domainSuffix, ["dscloud.example"])
        XCTAssertEqual(c.domain, ["mixed.example.com"])
        XCTAssertEqual(c.domainKeyword, ["tracker"])
    }

    /// 无法在规则集里等价表达的类型：跳过并计数，不静默丢，也不瞎猜。
    func testUnsupportedClassicalTypesAreCounted() throws {
        let result = try convert("""
        payload:
          - DOMAIN,a.example.com
          - DST-PORT,443
          - SRC-IP-CIDR,192.168.0.0/16
          - DST-PORT,80
          - IP-CIDR,not-a-cidr
        """)
        XCTAssertEqual(result.content.entryCount, 1)
        XCTAssertEqual(result.skipped["DST-PORT"], 2)
        XCTAssertEqual(result.skipped["SRC-IP-CIDR"], 1)
        XCTAssertEqual(result.skipped["IP-CIDR"], 1, "非法 CIDR 也算跳过")
    }

    func testDuplicatesAreRemovedKeepingFirstOrder() throws {
        let c = try convert("""
        payload:
          - DOMAIN-SUFFIX,b.example
          - DOMAIN-SUFFIX,a.example
          - DOMAIN-SUFFIX,B.example
        """).content
        XCTAssertEqual(c.domainSuffix, ["b.example", "a.example"])
    }

    // MARK: - domain / ipcidr 行为

    func testDomainBehaviorWildcardForms() throws {
        let c = try convert("""
        payload:
          - '+.plus.example'
          - '.dot.example'
          - '*.star.example'
          - exact.example
        """, .domain).content
        XCTAssertEqual(c.domainSuffix, ["plus.example", ".dot.example"], "+. 含本身；. 仅子域（sing-box 以点开头即仅子域）")
        XCTAssertEqual(c.domain, ["exact.example"])
        let regex = try XCTUnwrap(c.domainRegex.first)
        let pattern = try NSRegularExpression(pattern: regex)
        func matches(_ s: String) -> Bool {
            pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        XCTAssertTrue(matches("a.star.example"), "*. 匹配一级子域")
        XCTAssertFalse(matches("a.b.star.example"), "*. 不匹配多级子域")
        XCTAssertFalse(matches("star.example"), "*. 不匹配本身")
        XCTAssertFalse(matches("aXstar.example"), "点必须是字面量，不能被当成任意字符")
    }

    func testIPCIDRBehaviorAcceptsBareAddresses() throws {
        let result = try convert("""
        10.0.0.0/8
        1.2.3.4
        2001:db8::1
        garbage
        """, .ipcidr, .text)
        XCTAssertEqual(result.content.ipCIDR, ["10.0.0.0/8", "1.2.3.4/32", "2001:db8::1/128"])
        XCTAssertEqual(result.skipped["ipcidr"], 1)
    }

    func testTextFormatSkipsCommentsAndBlankLines() throws {
        let c = try convert("""
        # 头注释
        DOMAIN,a.example

        // 另一种注释
        DOMAIN-SUFFIX,b.example
        """, .classical, .text).content
        XCTAssertEqual(c.domain, ["a.example"])
        XCTAssertEqual(c.domainSuffix, ["b.example"])
    }

    // MARK: - DNS 版本与读回

    /// DNS 规则只能按域名匹配：IP 与进程条件都不能进去。
    func testDNSVariantContainsOnlyDomainConditions() throws {
        let c = try convert("""
        payload:
          - DOMAIN-SUFFIX,example.org
          - IP-CIDR,10.0.0.0/8
          - PROCESS-NAME,SomeApp
        """).content
        let dns = try XCTUnwrap(c.singBoxDNSSource())
        let rules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(Set(rules[0].keys), ["domain_suffix"])
    }

    func testDNSVariantIsNilWithoutDomainConditions() throws {
        let c = try convert("payload:\n  - IP-CIDR,10.0.0.0/8\n  - PROCESS-NAME,SomeApp").content
        XCTAssertNil(c.singBoxDNSSource())
    }

    func testRoundTripThroughSingBoxSource() throws {
        let original = try convert("""
        payload:
          - DOMAIN,a.example
          - DOMAIN-SUFFIX,b.example
          - IP-CIDR,10.0.0.0/8
          - PROCESS-NAME,SomeApp
        """).content
        XCTAssertEqual(RuleSetContent(singBoxSource: original.singBoxSource()), original)
    }

    // MARK: - 上限与不可信输入

    func testEntryLimitIsEnforced() {
        let text = "payload:\n" + (0..<5).map { "  - DOMAIN,a\($0).example" }.joined(separator: "\n")
        XCTAssertThrowsError(try ClashRuleSetConverter.convert(Data(text.utf8), behavior: .classical,
                                                               format: .yaml, entryLimit: 4))
    }

    /// 规则集文件同样是外部不可信输入，别名炸弹对它一样有效。
    func testAliasBombInRuleSetIsRejected() {
        var text = "a0: &a0 [x,x,x,x,x,x,x,x]\n"
        for level in 1...8 {
            text += "a\(level): &a\(level) [" + Array(repeating: "*a\(level - 1)", count: 8).joined(separator: ",") + "]\n"
        }
        text += "payload: []\n"
        XCTAssertThrowsError(try convert(text))
    }

    func testMissingPayloadIsAnError() {
        XCTAssertThrowsError(try convert("rules:\n  - DOMAIN,a.example"))
    }
}
