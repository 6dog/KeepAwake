import XCTest
@testable import KeepAwake

final class LogiBatteryStatusTests: XCTestCase {
    func testAvailableStatusIncludesLocalizedChargingState() {
        let status = LogiBatteryStatus.available(percent: 75, deviceStatus: "charging")

        XCTAssertEqual(status.percent, 75)
        XCTAssertEqual(status.tooltipTitle, "Logitech 电量 75% - 充电中")
    }

    func testRejectsBatteryPercentAboveValidRange() {
        let status = LogiBatteryStatus.available(percent: 255, deviceStatus: nil)

        XCTAssertNil(status.percent)
        XCTAssertEqual(status.tooltipTitle, "Logitech 电量不可用：设备返回了无效电量")
    }

    func testRejectsNegativeBatteryPercent() {
        let status = LogiBatteryStatus.available(percent: -1, deviceStatus: nil)

        XCTAssertNil(status.percent)
        XCTAssertEqual(status.tooltipTitle, "Logitech 电量不可用：设备返回了无效电量")
    }
}
