import XCTest
@testable import KongshanCore

final class RoutingModelsTests: XCTestCase {
    func testForcedProxyBatchNormalizesDeduplicatesAndPreservesOneApplyPayload() throws {
        let existing = [CustomRouteRule(
            order: 0,
            type: .domainSuffix,
            value: "example.com",
            action: .proxy,
            proxyGroup: "手动选择"
        )]

        let batch = try ForcedProxyRuleBatch(
            domainInput: "*.Example.com\napi.example.com, example.net",
            ipInput: "203.0.113.8; 2001:db8::1",
            existingRules: existing,
            proxyGroup: "手动选择"
        )

        XCTAssertEqual(batch.rules.count, 5)
        XCTAssertEqual(batch.rules.map(\.value), [
            "example.com", "api.example.com", "example.net", "203.0.113.8/32", "2001:db8::1/128"
        ])
    }

    func testRouteEvaluatorUsesGeneratorPriorityOrder() {
        var settings = RoutingSettings.defaults
        settings.customRules = [
            CustomRouteRule(
                order: 0,
                type: .domainSuffix,
                value: "example.com",
                action: .proxy,
                proxyGroup: "AI"
            )
        ]
        let subscriptions = [SubscriptionRule(type: .domain, value: "api.example.com", target: "DIRECT")]

        let forced = RouteRuleEvaluator.evaluate(
            RouteTestInput(domain: "api.example.com"),
            settings: settings,
            subscriptionRules: subscriptions,
            primaryOutbound: "主策略"
        )
        XCTAssertEqual(forced.source, .custom)
        XCTAssertEqual(forced.action, .proxy)
        XCTAssertEqual(forced.target, "AI")

        let privateIP = RouteRuleEvaluator.evaluate(
            RouteTestInput(ip: "192.168.2.9"),
            settings: settings,
            subscriptionRules: subscriptions,
            primaryOutbound: "主策略"
        )
        XCTAssertEqual(privateIP.source, .bypass)
        XCTAssertEqual(privateIP.action, .direct)

        let fallback = RouteRuleEvaluator.evaluate(
            RouteTestInput(domain: "outside.example.net"),
            settings: settings,
            subscriptionRules: subscriptions,
            primaryOutbound: "主策略"
        )
        XCTAssertEqual(fallback.source, .final)
        XCTAssertEqual(fallback.target, "主策略")
    }
    func testDefaultsContainRequiredBypassEntriesAndAdsAreOff() {
        let settings = RoutingSettings.defaults

        XCTAssertEqual(settings.bypassDomains, ["localhost", "*.local", "*.cn"])
        XCTAssertEqual(settings.bypassCIDRs, [
            "127.0.0.0/8",
            "10.0.0.0/8",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "169.254.0.0/16",
            "::1/128",
            "fc00::/7",
            "fe80::/10"
        ])
        XCTAssertFalse(settings.blockAds)
        // 回环三项无条件在前（用户从绕过列表里删掉也要补回来，否则 App 访问内核控制接口会绕回代理），
        // 其余按用户配置顺序，且不重复。
        let entries = settings.systemProxyBypassEntries
        XCTAssertEqual(Array(entries.prefix(3)), RoutingSettings.mandatoryProxyBypass)
        XCTAssertEqual(Set(entries).count, entries.count, "绕过列表不该有重复项")
        for entry in settings.bypassDomains + settings.bypassCIDRs {
            XCTAssertTrue(entries.contains(entry), "用户配置的 \(entry) 丢失了")
        }
        var stripped = settings
        stripped.bypassDomains = []
        stripped.bypassCIDRs = []
        XCTAssertEqual(stripped.systemProxyBypassEntries, RoutingSettings.mandatoryProxyBypass)
    }

    func testFiveRuleTypesAndThreeActionsRoundTripThroughJSON() throws {
        let rules = [
            CustomRouteRule(order: 0, type: .domainSuffix, value: "example.com", action: .direct),
            CustomRouteRule(order: 1, type: .domainKeyword, value: "video", action: .proxy, proxyGroup: "自动选择"),
            CustomRouteRule(order: 2, type: .domain, value: "ads.example.com", action: .reject),
            CustomRouteRule(order: 3, type: .ipCIDR, value: "10.10.0.0/16", action: .direct),
            CustomRouteRule(order: 4, type: .processName, value: "curl", action: .proxy, proxyGroup: "手动选择")
        ]
        let settings = RoutingSettings(
            customRules: rules,
            bypassDomains: ["localhost"],
            bypassCIDRs: ["192.168.0.0/16"],
            blockAds: true
        )

        let decoded = try JSONDecoder().decode(
            RoutingSettings.self,
            from: JSONEncoder().encode(settings)
        )

        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(Set(decoded.customRules.map(\.type)), Set(CustomRuleType.allCases))
        XCTAssertEqual(Set(decoded.customRules.map(\.action)), Set(RouteAction.allCases))
    }

    func testValidationTrimsValuesAndProxyGroup() throws {
        let rule = CustomRouteRule(
            order: 0,
            type: .domainKeyword,
            value: "  example  ",
            action: .proxy,
            proxyGroup: "  自建  "
        )

        let validated = try rule.validated()

        XCTAssertEqual(validated.value, "example")
        XCTAssertEqual(validated.proxyGroup, "自建")
    }

    func testValidationNormalizesBareIPAddressToHostCIDR() throws {
        let ipv4 = try CustomRouteRule(
            order: 0,
            type: .ipCIDR,
            value: " 203.0.113.8 ",
            action: .proxy,
            proxyGroup: "手动选择"
        ).validated()
        let ipv6 = try CustomRouteRule(
            order: 1,
            type: .ipCIDR,
            value: "2001:db8::8",
            action: .proxy,
            proxyGroup: "手动选择"
        ).validated()

        XCTAssertEqual(ipv4.value, "203.0.113.8/32")
        XCTAssertEqual(ipv6.value, "2001:db8::8/128")
    }

    func testSSHProxyTargetsValidateExactAddressesPortsAndDeduplicate() throws {
        var settings = RoutingSettings.defaults
        settings.sshProxyTargets = [
            SSHProxyTarget(address: " 118.69.52.186 ", port: 22_235),
            SSHProxyTarget(address: "118.69.52.186", port: 22_235),
            SSHProxyTarget(address: "118.69.52.186", port: 22),
            SSHProxyTarget(address: "2001:0db8::1", port: 22)
        ]

        let validated = try settings.validated()

        XCTAssertEqual(validated.sshProxyTargets, [
            SSHProxyTarget(address: "118.69.52.186", port: 22_235),
            SSHProxyTarget(address: "118.69.52.186", port: 22),
            SSHProxyTarget(address: "2001:db8::1", port: 22)
        ])
        XCTAssertThrowsError(try SSHProxyTarget(address: "118.69.52.0/24").validated())
        XCTAssertThrowsError(try SSHProxyTarget(address: "127.0.0.1").validated())
    }

    func testSSHProxyTargetDoesNotChangeTunExclusionsForOtherTraffic() throws {
        var settings = RoutingSettings.defaults
        settings.tunExcludeCIDRs = ["192.168.0.0/16"]
        settings.sshProxyTargets = [SSHProxyTarget(address: "192.168.1.20", port: 22)]

        XCTAssertEqual(try settings.validated().effectiveTunExcludeCIDRs, ["192.168.0.0/16"])
    }

    func testForcedProxyRulesRemoveConflictingSystemBypassEntries() {
        var settings = RoutingSettings.defaults
        settings.bypassDomains += ["api.example.com", "*.internal.example.com"]
        settings.bypassCIDRs += ["203.0.113.0/24", "2001:db8::/32"]
        settings.customRules = [
            CustomRouteRule(
                order: 0,
                type: .domainSuffix,
                value: "service.cn",
                action: .proxy,
                proxyGroup: "手动选择"
            ),
            CustomRouteRule(
                order: 1,
                type: .domainSuffix,
                value: "example.com",
                action: .proxy,
                proxyGroup: "手动选择"
            ),
            CustomRouteRule(
                order: 2,
                type: .ipCIDR,
                value: "203.0.113.8/32",
                action: .proxy,
                proxyGroup: "手动选择"
            ),
            CustomRouteRule(
                order: 3,
                type: .ipCIDR,
                value: "2001:db8:1::/48",
                action: .proxy,
                proxyGroup: "手动选择"
            )
        ]

        let entries = settings.systemProxyBypassEntries(including: ["*.corp.example.com", "corp.example.com"])

        XCTAssertEqual(Array(entries.prefix(3)), RoutingSettings.mandatoryProxyBypass)
        XCTAssertFalse(entries.contains("*.cn"))
        XCTAssertFalse(entries.contains("api.example.com"))
        XCTAssertFalse(entries.contains("*.internal.example.com"))
        XCTAssertFalse(entries.contains("203.0.113.0/24"))
        XCTAssertFalse(entries.contains("2001:db8::/32"))
        XCTAssertFalse(entries.contains("*.corp.example.com"))
        XCTAssertTrue(entries.contains("*.local"))

        let directModeEntries = settings.systemProxyBypassEntries(
            including: ["*.corp.example.com"],
            respectingForcedProxyRules: false
        )
        XCTAssertTrue(directModeEntries.contains("*.cn"))
        XCTAssertTrue(directModeEntries.contains("203.0.113.0/24"))
        XCTAssertTrue(directModeEntries.contains("*.corp.example.com"))
    }

    func testForcedProxyCIDRRemovesOverlappingTunExclusionButKeepsLoopback() {
        var settings = RoutingSettings.defaults
        settings.customRules = [
            CustomRouteRule(
                order: 0,
                type: .ipCIDR,
                value: "10.20.30.40/32",
                action: .proxy,
                proxyGroup: "手动选择"
            )
        ]

        XCTAssertFalse(settings.effectiveTunExcludeCIDRs.contains("10.0.0.0/8"))
        XCTAssertTrue(settings.effectiveTunExcludeCIDRs.contains("127.0.0.0/8"))
        XCTAssertTrue(settings.effectiveTunExcludeCIDRs.contains("::1/128"))
    }

    func testValidationRejectsEmptyValueInvalidCIDRAndMissingProxyGroup() {
        XCTAssertThrowsError(try CustomRouteRule(
            order: 0,
            type: .domain,
            value: "  ",
            action: .direct
        ).validated()) { error in
            XCTAssertEqual(error as? RoutingValidationError, .emptyRuleValue)
        }

        XCTAssertThrowsError(try CustomRouteRule(
            order: 0,
            type: .ipCIDR,
            value: "10.0.0.1/99",
            action: .direct
        ).validated()) { error in
            XCTAssertEqual(error as? RoutingValidationError, .invalidCIDR("10.0.0.1/99"))
        }

        XCTAssertThrowsError(try CustomRouteRule(
            order: 0,
            type: .processName,
            value: "curl",
            action: .proxy,
            proxyGroup: ""
        ).validated()) { error in
            XCTAssertEqual(error as? RoutingValidationError, .missingProxyGroup)
        }
    }

    func testSettingsValidationRejectsInvalidBypassCIDR() {
        let settings = RoutingSettings(
            customRules: [],
            bypassDomains: ["localhost"],
            bypassCIDRs: ["not-a-cidr"],
            blockAds: false
        )

        XCTAssertThrowsError(try settings.validated()) { error in
            XCTAssertEqual(error as? RoutingValidationError, .invalidCIDR("not-a-cidr"))
        }
    }
}
