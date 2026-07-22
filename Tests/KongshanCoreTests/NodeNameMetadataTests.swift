import XCTest
@testable import KongshanCore

final class NodeNameMetadataTests: XCTestCase {
    func testExplicitFlagAndMultiplierWin() {
        let metadata = NodeNameMetadata.parse("🇯🇵 3x JP 高速")

        XCTAssertEqual(metadata.flag, "🇯🇵")
        XCTAssertEqual(metadata.regionCode, "JP")
        XCTAssertEqual(metadata.multiplier, 3)
        XCTAssertEqual(metadata.multiplierText, "3×")
    }

    func testInfersCommonRegionKeywords() {
        XCTAssertEqual(NodeNameMetadata.parse("Japan Premium").flag, "🇯🇵")
        XCTAssertEqual(NodeNameMetadata.parse("香港 HKT").flag, "🇭🇰")
        XCTAssertEqual(NodeNameMetadata.parse("Dmit 洛杉矶 H2").flag, "🇺🇸")
        XCTAssertEqual(NodeNameMetadata.parse("斐济住宅").flag, "🇫🇯")
    }

    func testParsesSupportedMultiplierForms() {
        XCTAssertEqual(NodeNameMetadata.parse("JP 3×").multiplierText, "3×")
        XCTAssertEqual(NodeNameMetadata.parse("香港 2倍").multiplierText, "2×")
        XCTAssertEqual(NodeNameMetadata.parse("倍率：1.5").multiplierText, "1.5×")
    }

    func testShortCountryCodeMustBeASeparateToken() {
        XCTAssertEqual(NodeNameMetadata.parse("JP Tokyo").regionCode, "JP")
        XCTAssertNil(NodeNameMetadata.parse("project-node").regionCode)
    }

    func testNameWithoutMetadataRemainsEmpty() {
        let metadata = NodeNameMetadata.parse("普通节点")

        XCTAssertNil(metadata.flag)
        XCTAssertNil(metadata.regionCode)
        XCTAssertNil(metadata.multiplier)
        XCTAssertNil(metadata.multiplierText)
    }
}
