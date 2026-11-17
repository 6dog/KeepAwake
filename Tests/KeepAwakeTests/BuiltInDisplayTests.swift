import XCTest
@testable import KeepAwake

private final class FakeDisplayBackend: DisplayBackend {
    var panelOnline = true
    var externalCount = 1
    var externalPhysical = true
    var panelID: UInt32 = 1
    var mirror = true
    var failEnumeration = false
    var ignoreDisable = false
    var enableFailures = 0
    var calls: [Bool] = []
    var restoredMirrors = 0
    func displays() throws -> [ManagedDisplay] {
        if failEnumeration { throw DisplayControlError(message: "missing symbol") }
        return [ManagedDisplay(id: panelID, identity: "internal", builtIn: true, online: panelOnline, active: panelOnline, physical: true, mirrors: mirror ? 10 : 0)] + (0..<externalCount).map {
            ManagedDisplay(id: UInt32(10 + $0), identity: "external\($0)", builtIn: false, online: true, active: true, physical: externalPhysical, mirrors: 0)
        }
    }
    func setBuiltInEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if enabled && enableFailures > 0 { enableFailures -= 1; throw DisplayControlError(message: "temporary") }
        if enabled || !ignoreDisable { panelOnline = enabled }
        if !enabled { mirror = false }
    }
    func restoreMirror(_ source: String, to target: String) throws { restoredMirrors += 1; mirror = true }
}

final class BuiltInDisplayTests: XCTestCase {
    private var suite: String!
    private var prefs: UserDefaults!
    private var backend: FakeDisplayBackend!
    private var controller: BuiltInDisplayController!
    override func setUp() {
        suite = "KeepAwakeTests.\(UUID().uuidString)"
        prefs = UserDefaults(suiteName: suite)!
        backend = FakeDisplayBackend()
        controller = makeController()
    }
    private func makeController() -> BuiltInDisplayController {
        BuiltInDisplayController(backend: backend, defaults: prefs, delay: 0.02, verificationDelay: 0.01, restoreDelay: 0.01)
    }
    override func tearDown() {
        controller.stop()
        prefs.removePersistentDomain(forName: suite)
    }
    private func drain(_ seconds: TimeInterval = 0.09) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func testDefaultDoesNotDisable() {
        controller.refresh(); drain()
        XCTAssertTrue(backend.panelOnline)
        XCTAssertTrue(backend.calls.isEmpty)
    }
    func testAutomaticDisablesAndLastExternalDisconnectRestores() {
        controller.setAutomatic(true); drain()
        XCTAssertFalse(backend.panelOnline)
        backend.externalCount = 0
        controller.refresh(); drain()
        XCTAssertTrue(backend.panelOnline)
        XCTAssertFalse(prefs.bool(forKey: BuiltInDisplayController.Key.owned))
    }
    func testOneOfMultipleExternalDisplaysCanRemain() {
        backend.externalCount = 2
        controller.setAutomatic(true); drain()
        backend.externalCount = 1; controller.refresh(); drain()
        XCTAssertFalse(backend.panelOnline)
    }
    func testVirtualDisplayDoesNotTriggerDisable() {
        backend.externalPhysical = false
        controller.setAutomatic(true); drain()
        XCTAssertTrue(backend.panelOnline)
    }
    func testHotUnplugCancelsPendingDisable() {
        controller.setAutomatic(true)
        backend.externalCount = 0; controller.refresh(); drain()
        XCTAssertFalse(backend.calls.contains(false))
    }
    func testForceOnCancelsPendingDisable() {
        controller.setAutomatic(true)
        controller.setForceOn(true); drain()
        XCTAssertTrue(backend.panelOnline)
        XCTAssertFalse(backend.calls.contains(false))
    }
    func testForceOnRestoresAndSurvivesRestartAndHotplug() {
        controller.setAutomatic(true); drain()
        controller.setForceOn(true); drain()
        controller.stop(); controller = makeController(); controller.start(); drain()
        backend.externalCount = 0; controller.refresh(); drain()
        backend.externalCount = 1; controller.refresh(); drain()
        XCTAssertTrue(controller.automatic)
        XCTAssertTrue(controller.forceOn)
        XCTAssertTrue(backend.panelOnline)
        controller.setForceOn(false); drain()
        XCTAssertFalse(backend.panelOnline)
    }
    func testTurningAutomaticOffRestoresMirror() {
        controller.setAutomatic(true); drain()
        controller.setAutomatic(false); drain()
        XCTAssertTrue(backend.panelOnline)
        XCTAssertEqual(backend.restoredMirrors, 1)
    }
    func testWakeReappliesAutomaticRuleWithNewPanelID() {
        controller.setAutomatic(true); drain()
        backend.panelID = 77; backend.panelOnline = true
        controller.refresh(); drain()
        XCTAssertFalse(backend.panelOnline)
    }
    func testMissingSymbolsDoNotDisable() {
        backend.failEnumeration = true
        controller.setAutomatic(true); drain()
        XCTAssertFalse(controller.available)
        XCTAssertTrue(backend.calls.isEmpty)
        XCTAssertTrue(controller.status.contains("missing symbol"))
    }
    func testFalseSuccessPausesAutomaticControlAndRestores() {
        backend.ignoreDisable = true
        controller.setAutomatic(true); drain()
        controller.refresh(); drain()
        XCTAssertEqual(backend.calls.filter { !$0 }.count, 1)
        XCTAssertTrue(backend.panelOnline)
    }
    func testRestoreRetriesTransientErrors() {
        controller.setAutomatic(true); drain()
        backend.enableFailures = 2
        controller.setForceOn(true); drain()
        XCTAssertTrue(backend.panelOnline)
        XCTAssertEqual(backend.calls.filter { $0 }.count, 3)
    }
    func testCrashMarkerRestoresBeforeAutomaticRule() {
        backend.panelOnline = false
        prefs.set(true, forKey: BuiltInDisplayController.Key.owned)
        prefs.set(true, forKey: BuiltInDisplayController.Key.automatic)
        controller.start(); drain()
        XCTAssertEqual(backend.calls.prefix(2), [true, false])
    }
    func testQuitRestoresAndDoesNotErasePreferences() {
        controller.setAutomatic(true); drain()
        XCTAssertTrue(controller.prepareToQuit())
        XCTAssertTrue(backend.panelOnline)
        XCTAssertTrue(controller.automatic)
    }
    func testQuitFailureKeepsRecoveryMarker() {
        controller.setAutomatic(true); drain()
        backend.enableFailures = 10
        XCTAssertFalse(controller.prepareToQuit())
        XCTAssertTrue(prefs.bool(forKey: BuiltInDisplayController.Key.owned))
    }
    func testRepeatedWakeStopsAfterThreeDisconnects() {
        controller.setAutomatic(true); drain()
        for _ in 0..<4 { backend.panelOnline = true; controller.refresh(); drain() }
        XCTAssertEqual(backend.calls.filter { !$0 }.count, 3)
        XCTAssertTrue(backend.panelOnline)
    }
    func testPhysicalClassifierFailsClosedForAirPlayVirtualAndMissingData() {
        let physical: NSDictionary = ["kCGDisplayIsVirtualDevice": false, "kCGDisplayIsAirPlay": false, "IODisplayLocation": "IOService:/dispext0/AppleCLCD2"]
        XCTAssertTrue(SkyLightDisplayBackend.isPhysical(physical))
        for key in ["kCGDisplayIsVirtualDevice", "kCGDisplayIsAirPlay"] {
            let bad = physical.mutableCopy() as! NSMutableDictionary
            bad[key] = true
            XCTAssertFalse(SkyLightDisplayBackend.isPhysical(bad))
        }
        XCTAssertFalse(SkyLightDisplayBackend.isPhysical(nil))
        XCTAssertFalse(SkyLightDisplayBackend.isPhysical(["IODisplayLocation": "IOService:/virtual"]))
    }
}
