import XCTest
@testable import KeepAwake

private final class FakePower: PowerBackend {
    var next: UInt32 = 1
    var active = Set<UInt32>()
    var failDisplay = false
    var failRelease = false
    func create(display: Bool) throws -> UInt32 {
        if display && failDisplay { throw PowerFailure(stage: "create", code: -1) }
        let id = next; next += 1; active.insert(id); return id
    }
    func release(_ id: UInt32) throws {
        if failRelease { throw PowerFailure(stage: "release", code: -2) }
        active.remove(id)
    }
}
final class PowerControllerTests: XCTestCase {
    private var prefs: UserDefaults!
    private var suite: String!
    private var logRoot: URL!
    private var diagnostics: Diagnostics!
    override func setUp() {
        suite = "KeepAwake.PowerTests.\(UUID().uuidString)"; prefs = UserDefaults(suiteName: suite)!
        logRoot = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        var config = Diagnostics.Configuration(); config.directory = logRoot
        diagnostics = Diagnostics(configuration: config)
    }
    override func tearDown() { prefs.removePersistentDomain(forName: suite); diagnostics.flush(); try? FileManager.default.removeItem(at: logRoot) }
    func testMigrationPreservesAllOldCombinations() {
        for (display, system, expected) in [(false,false,PowerMode.system),(false,true,.preventSleep),(true,false,.displayOn),(true,true,.displayOn)] {
            prefs.removeObject(forKey: "powerMode"); prefs.set(display, forKey: "keepDisplayAwake"); prefs.set(system, forKey: "preventSystemSleep")
            XCTAssertEqual(PowerMode.saved(in: prefs), expected)
        }
    }
    func testModesCreateOnlyRequiredAssertionsAndReleaseOnSystemMode() {
        let backend = FakePower()
        let c = PowerController(backend: backend, defaults: prefs, diagnostics: diagnostics)
        XCTAssertTrue(c.apply(.displayOn)); XCTAssertEqual(backend.active.count, 2)
        XCTAssertTrue(c.apply(.preventSleep)); XCTAssertEqual(backend.active.count, 1)
        XCTAssertEqual(c.mode, .preventSleep)
        XCTAssertTrue(c.apply(.system)); XCTAssertTrue(backend.active.isEmpty)
    }
    func testCreationFailureRollsBackNewAssertionAndDoesNotPersistTarget() {
        let backend = FakePower(); backend.failDisplay = true
        let c = PowerController(backend: backend, defaults: prefs, diagnostics: diagnostics)
        XCTAssertFalse(c.apply(.displayOn)); XCTAssertTrue(backend.active.isEmpty)
        XCTAssertEqual(c.mode, .system); XCTAssertNil(prefs.string(forKey: "powerMode")); XCTAssertNotNil(c.lastError)
    }
    func testFailedUpgradePreservesExistingSystemAssertion() {
        let backend = FakePower(); let c = PowerController(backend: backend, defaults: prefs, diagnostics: diagnostics)
        XCTAssertTrue(c.apply(.preventSleep)); let original = c.systemID
        backend.failDisplay = true
        XCTAssertFalse(c.apply(.displayOn)); XCTAssertEqual(c.systemID, original); XCTAssertEqual(c.mode, .preventSleep)
    }
    func testReleaseFailureKeepsActualStateForRetry() {
        let backend = FakePower(); let c = PowerController(backend: backend, defaults: prefs, diagnostics: diagnostics)
        XCTAssertTrue(c.apply(.displayOn)); backend.failRelease = true
        XCTAssertFalse(c.apply(.system)); XCTAssertEqual(c.mode, .displayOn); XCTAssertEqual(backend.active.count, 2)
        backend.failRelease = false
        XCTAssertTrue(c.apply(.system)); XCTAssertTrue(backend.active.isEmpty)
    }
    func testExitDoesNotOverwriteSavedMode() {
        let c = PowerController(backend: FakePower(), defaults: prefs, diagnostics: diagnostics)
        c.apply(.displayOn); c.apply(.system, persist: false)
        XCTAssertEqual(prefs.string(forKey: "powerMode"), PowerMode.displayOn.rawValue)
    }
}
