import XCTest
@testable import KongshanCore

final class RoutingModelsTests: XCTestCase {
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
        XCTAssertEqual(settings.systemProxyBypassEntries, settings.bypassDomains + settings.bypassCIDRs)
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
