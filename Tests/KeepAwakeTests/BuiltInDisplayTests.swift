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
    var disableFailures = 0
    var delayedDisablePolls = 0
    private var pendingDisablePolls = 0
    var enableFailures = 0
    var calls: [Bool] = []
    var restoredMirrors = 0
    func displays() throws -> [ManagedDisplay] {
        if failEnumeration { throw DisplayControlError(message: "missing symbol") }
        if pendingDisablePolls > 0 {
            pendingDisablePolls -= 1
            if pendingDisablePolls == 0 { panelOnline = false }
        }
        return [ManagedDisplay(id: panelID, identity: "internal", builtIn: true, online: panelOnline, active: panelOnline, physical: true, mirrors: mirror ? 10 : 0)] + (0..<externalCount).map {
            ManagedDisplay(id: UInt32(10 + $0), identity: "external\($0)", builtIn: false, online: true, active: true, physical: externalPhysical, mirrors: 0)
        }
    }
    func setBuiltInEnabled(_ enabled: Bool) throws {
        calls.append(enabled)
        if enabled && enableFailures > 0 { enableFailures -= 1; throw DisplayControlError(message: "temporary") }
        if !enabled && disableFailures > 0 { disableFailures -= 1; throw DisplayControlError(message: "temporary disable error") }
        if enabled { pendingDisablePolls = 0; panelOnline = true }
        else if !ignoreDisable {
            if delayedDisablePolls > 0 { pendingDisablePolls = delayedDisablePolls }
            else { panelOnline = false }
        }
        if !enabled { mirror = false }
    }
    func restoreMirror(_ source: String, to target: String) throws { restoredMirrors += 1; mirror = true }
}

final class BuiltInDisplayTests: XCTestCase {
    private var suite: String!
    private var prefs: UserDefaults!
    private var backend: FakeDisplayBackend!
    private var controller: BuiltInDisplayController!
    private var clock: Date!
    private var logRoot: URL!
    private var diagnostics: Diagnostics!
    override func setUp() {
        suite = "KeepAwakeTests.\(UUID().uuidString)"
        prefs = UserDefaults(suiteName: suite)!
        backend = FakeDisplayBackend()
        clock = Date()
        logRoot = FileManager.default.temporaryDirectory.appendingPathComponent("KeepAwakeDisplayTests-\(UUID().uuidString)")
        var config = Diagnostics.Configuration(); config.directory = logRoot
        diagnostics = Diagnostics(configuration: config)
        controller = makeController()
    }
    private func makeController() -> BuiltInDisplayController {
        BuiltInDisplayController(backend: backend, defaults: prefs, delay: 0.02, verificationDelay: 0.01, restoreDelay: 0.01, failureRetryDelay: 5, now: { [unowned self] in self.clock }, diagnostics: diagnostics)
    }
    override func tearDown() {
        controller.stop()
        prefs.removePersistentDomain(forName: suite)
        diagnostics.flush()
        try? FileManager.default.removeItem(at: logRoot)
    }
    private func drain(_ seconds: TimeInterval = 0.09) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func quit() -> Bool {
        var result: Bool?
        controller.prepareToQuit { result = $0 }
        let deadline = Date().addingTimeInterval(1)
        while result == nil && Date() < deadline { drain(0.01) }
        return result ?? false
    }
    func testLegacyForceOnMigratesToAutomaticOff() {
        prefs.set(true, forKey: BuiltInDisplayController.Key.automatic)
        prefs.set(true, forKey: BuiltInDisplayController.Key.forceOn)
        controller.stop(); controller = makeController()
        XCTAssertFalse(controller.automatic)
        XCTAssertNil(prefs.object(forKey: BuiltInDisplayController.Key.forceOn))
    }
    func testQuitCompletesInsideNestedMainQueueRunLoop() {
        controller.setAutomatic(true); drain()
        let finished = expectation(description: "nested termination loop completes")
        DispatchQueue.main.async {
            var result: Bool?
            self.controller.prepareToQuit { result = $0 }
            let end = Date().addingTimeInterval(0.5)
            while result == nil && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertEqual(result, true)
            XCTAssertTrue(self.backend.panelOnline)
            finished.fulfill()
        }
        wait(for: [finished], timeout: 1)
    }
    func testRecoveryTargetSurvivesDisappearanceAndAppRestartWithinSameBoot() {
        let target = BuiltInDisplayTarget(defaults: prefs, boot: "boot-a")
        let panel = ManagedDisplay(id: 17, identity: "panel", builtIn: true, online: true, active: true, physical: true, mirrors: 0)
        XCTAssertEqual(target.resolve(in: [panel], restoring: false), 17)
        let restarted = BuiltInDisplayTarget(defaults: prefs, boot: "boot-a")
        XCTAssertEqual(restarted.resolve(in: [], restoring: true), 17)
        XCTAssertNil(restarted.resolve(in: [], restoring: false))
        XCTAssertNil(BuiltInDisplayTarget(defaults: prefs, boot: "boot-b").resolve(in: [], restoring: true))
        XCTAssertNil(BuiltInDisplayTarget(defaults: prefs, boot: nil).resolve(in: [], restoring: true))
        let external = ManagedDisplay(id: 17, identity: "external", builtIn: false, online: true, active: true, physical: true, mirrors: 0)
        XCTAssertNil(restarted.resolve(in: [external], restoring: true))
        let changed = ManagedDisplay(id: 21, identity: "panel", builtIn: true, online: false, active: false, physical: true, mirrors: 0)
        XCTAssertEqual(restarted.resolve(in: [changed], restoring: true), 21)
        XCTAssertEqual(restarted.resolve(in: [], restoring: true), 21)
    }
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
    func testTurningAutomaticOffCancelsPendingDisable() {
        controller.setAutomatic(true)
        controller.setAutomatic(false); drain()
        XCTAssertTrue(backend.panelOnline)
        XCTAssertFalse(backend.calls.contains(false))
    }
    func testAutomaticOffRestoresAndSurvivesRestartAndHotplug() {
        controller.setAutomatic(true); drain()
        controller.setAutomatic(false); drain()
        controller.stop(); controller = makeController(); controller.start(); drain()
        backend.externalCount = 0; controller.refresh(); drain()
        backend.externalCount = 1; controller.refresh(); drain()
        XCTAssertFalse(controller.automatic)
        XCTAssertTrue(backend.panelOnline)
        controller.setAutomatic(true); drain()
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
    func testFalseSuccessRestoresAndAutomaticallyRetries() {
        backend.ignoreDisable = true
        controller.setAutomatic(true); drain()
        controller.refresh(); drain()
        XCTAssertEqual(backend.calls.filter { !$0 }.count, 1)
        XCTAssertTrue(backend.panelOnline)
        XCTAssertNotNil(controller.lastFailure)
        XCTAssertTrue(controller.status.contains("自动重试"))
        backend.ignoreDisable = false
        clock = clock.addingTimeInterval(6)
        controller.refresh(); drain()
        XCTAssertFalse(backend.panelOnline)
        XCTAssertNil(controller.lastFailure)
    }
    func testRestoreRetriesTransientErrors() {
        controller.setAutomatic(true); drain()
        backend.enableFailures = 2
        controller.setAutomatic(false); drain()
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
        XCTAssertTrue(quit())
        XCTAssertTrue(backend.panelOnline)
        XCTAssertTrue(controller.automatic)
    }
    func testQuitFailureKeepsRecoveryMarker() {
        controller.setAutomatic(true); drain()
        backend.enableFailures = 10
        XCTAssertFalse(quit())
        XCTAssertTrue(prefs.bool(forKey: BuiltInDisplayController.Key.owned))
    }
    func testNormalWakeCyclesDoNotPermanentlyPauseAfterThreeDisconnects() {
        controller.setAutomatic(true); drain()
        // Four wakes within the old one-minute window used to permanently pause the app.
        for _ in 0..<4 {
            clock = clock.addingTimeInterval(10)
            backend.panelOnline = true; controller.refresh(); drain()
            XCTAssertFalse(backend.panelOnline)
        }
        XCTAssertEqual(backend.calls.filter { !$0 }.count, 5)
        XCTAssertNil(controller.lastFailure)
    }
    func testRapidReenableLoopIsThrottledAndAutomaticallyResumes() {
        controller.setAutomatic(true); drain()
        for _ in 0..<3 { backend.panelOnline = true; controller.refresh(); drain() }
        XCTAssertTrue(backend.panelOnline)
        XCTAssertEqual(backend.calls.filter { !$0 }.count, 3)
        XCTAssertTrue(controller.status.contains("自动重试"))
        clock = clock.addingTimeInterval(6)
        controller.refresh(); drain()
        XCTAssertFalse(backend.panelOnline)
        XCTAssertNil(controller.lastFailure)
    }
    func testSlowWindowServerResultIsPolledWithoutResubmitting() {
        backend.delayedDisablePolls = 4
        controller.setAutomatic(true); drain()
        XCTAssertFalse(backend.panelOnline)
        XCTAssertEqual(backend.calls, [false])
        XCTAssertNil(controller.lastFailure)
    }
    func testTransientDisableErrorRecoversWithoutManualToggle() {
        backend.disableFailures = 1
        controller.setAutomatic(true); drain()
        XCTAssertTrue(controller.status.contains("自动重试"))
        XCTAssertTrue(controller.lastFailure?.contains("temporary disable error") == true)
        clock = clock.addingTimeInterval(6)
        controller.refresh(); drain()
        XCTAssertFalse(backend.panelOnline)
        XCTAssertNil(controller.lastFailure)
    }
    func testExternalUnplugDuringFailureBackoffRestoresImmediately() {
        backend.enableFailures = 3
        controller.setAutomatic(true); drain()
        controller.setAutomatic(false); drain()
        XCTAssertFalse(backend.panelOnline)
        backend.externalCount = 0
        controller.refresh(); drain()
        XCTAssertTrue(backend.panelOnline)
    }
    func testAutomaticOffDuringBackoffCancelsRetry() {
        backend.ignoreDisable = true
        controller.setAutomatic(true); drain()
        controller.setAutomatic(false); drain()
        backend.ignoreDisable = false
        clock = clock.addingTimeInterval(90)
        controller.refresh(); drain()
        XCTAssertTrue(backend.panelOnline)
        XCTAssertFalse(controller.automatic)
        XCTAssertNil(controller.lastFailure)
    }
    func testEnumerationErrorDuringVerificationDoesNotLeaveControllerStuck() {
        controller.setAutomatic(true)
        drain(0.025)
        backend.failEnumeration = true
        controller.refresh()
        backend.failEnumeration = false
        clock = clock.addingTimeInterval(6)
        controller.refresh(); drain()
        XCTAssertFalse(backend.panelOnline)
        XCTAssertNil(controller.lastFailure)
    }
    func testPollingAutomaticallyRetriesAfterCooldownWithoutManualRefresh() {
        controller.stop()
        controller = BuiltInDisplayController(backend: backend, defaults: prefs, delay: 0.01, verificationDelay: 0.005, restoreDelay: 0.005, failureRetryDelay: 5, pollingInterval: 0.02, now: { [unowned self] in self.clock }, diagnostics: diagnostics)
        backend.disableFailures = 1
        controller.start()
        controller.setAutomatic(true); drain()
        XCTAssertTrue(backend.panelOnline)
        XCTAssertNotNil(controller.lastFailure)
        backend.disableFailures = 0
        clock = clock.addingTimeInterval(6)
        drain() // Only the running poll timer can restart automation here.
        XCTAssertFalse(backend.panelOnline)
        XCTAssertNil(controller.lastFailure)
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
