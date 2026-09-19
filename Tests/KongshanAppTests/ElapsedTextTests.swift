import Foundation
import XCTest
@testable import kongshan

/// 启动耗时要写进事件——"切模式太慢"这类抱怨，先得有数才知道该优化哪一段。
@MainActor
final class ElapsedTextTests: XCTestCase {
    func testSubSecondUsesMilliseconds() {
        XCTAssertEqual(AppState.elapsedText(.milliseconds(430)), "430 毫秒")
        XCTAssertEqual(AppState.elapsedText(.milliseconds(999)), "999 毫秒")
    }

    func testSecondsAreShownWithOneDecimal() {
        XCTAssertEqual(AppState.elapsedText(.milliseconds(1000)), "1.0 秒")
        XCTAssertEqual(AppState.elapsedText(.milliseconds(2350)), "2.4 秒")
        XCTAssertEqual(AppState.elapsedText(.seconds(11)), "11.0 秒")
    }
}
