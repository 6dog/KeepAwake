import XCTest
@testable import KeepAwake

final class LoginItemTests: XCTestCase {
    func testDetectsMovedAppAndRepairsItsOwnLoginPath() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeepAwakeLoginTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("old.app"), second = root.appendingPathComponent("new.app"), plist = root.appendingPathComponent("agent.plist")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let original = LoginItemManager(appURL: first, agentURL: plist)
        try original.setEnabled(true); XCTAssertTrue(original.matchesCurrentApp)
        let moved = LoginItemManager(appURL: second, agentURL: plist)
        XCTAssertTrue(moved.exists); XCTAssertFalse(moved.matchesCurrentApp)
        try moved.setEnabled(true); XCTAssertTrue(moved.matchesCurrentApp)
        try moved.setEnabled(false); XCTAssertFalse(moved.exists)
    }
}
