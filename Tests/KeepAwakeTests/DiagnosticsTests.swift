import XCTest
@testable import KeepAwake

final class DiagnosticsTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("KeepAwakeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func logger(fileLimit: Int = 2048, totalLimit: Int = 8192, clock: @escaping () -> TimeInterval = { 0 }) -> Diagnostics {
        var config = Diagnostics.Configuration()
        config.directory = root.appendingPathComponent("logs"); config.fileLimit = fileLimit; config.totalLimit = totalLimit
        return Diagnostics(configuration: config, uptime: clock)
    }
    private func records(_ log: Diagnostics) throws -> [[String: Any]] {
        log.flush()
        return try FileManager.default.contentsOfDirectory(at: log.directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }.flatMap {
            try Data(contentsOf: $0).split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
        }
    }
    func testRotationRemainsBoundedAndEveryLineIsValidJSON() throws {
        let log = logger()
        for n in 0..<100 { log.record("test", "event", fields: ["n": String(n), "value": String(repeating: "x", count: 150)]) }
        let rows = try records(log)
        XCTAssertFalse(rows.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: log.directory, includingPropertiesForKeys: [.fileSizeKey])
        let total = try files.reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertLessThanOrEqual(total, 8192)
        XCTAssertTrue(rows.allSatisfy { $0["session"] as? String == log.session })
    }
    func testUserPathsAreSanitizedBeforePersisting() throws {
        let log = logger()
        log.record("test", "private_path", fields: ["path": FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("private.txt").path])
        let rows = try records(log)
        let fields = rows.first?["fields"] as? [String: String]
        XCTAssertEqual(fields?["path"], "~/private.txt")
        XCTAssertEqual(Diagnostics.sanitize("/Users/another-person/foo"), "~/foo")
    }
    func testDetailedModeExpiresAndDoesNotPersistAfterRecreatingLogger() throws {
        var clock: TimeInterval = 0
        let log = logger(clock: { clock })
        log.record("test", "hidden", level: "debug")
        log.setDetailed(true); log.record("test", "visible", level: "debug")
        clock = 1801
        XCTAssertFalse(log.isDetailed)
        log.record("test", "hidden_again", level: "debug")
        let events = try records(log).compactMap { $0["event"] as? String }
        XCTAssertTrue(events.contains("visible")); XCTAssertFalse(events.contains("hidden")); XCTAssertFalse(events.contains("hidden_again"))
        XCTAssertFalse(logger().isDetailed)
    }
    func testUnwritableDestinationIsReportedWithoutThrowingOrBlocking() throws {
        let file = root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)
        var config = Diagnostics.Configuration(); config.directory = file
        let log = Diagnostics(configuration: config)
        log.record("test", "failure"); log.flush()
        XCTAssertNotNil(log.error)
    }
    func testUncleanSessionIsDistinguishedFromCleanExit() throws {
        let first = logger(); first.beginSession(); first.flush()
        let second = logger(); second.beginSession(); second.flush()
        XCTAssertTrue(try records(second).contains { $0["event"] as? String == "previous_session_unclean" })
        second.endSession()
        let third = logger(); third.beginSession(); third.flush()
        let rows = try records(third).filter { $0["session"] as? String == third.session }
        XCTAssertFalse(rows.contains { $0["event"] as? String == "previous_session_unclean" })
        third.endSession()
    }
    func testDiagnosticArchiveIncludesSnapshotAndCompleteSanitizedLogs() throws {
        let log = logger(); log.record("test", "marked", operation: "issue-123")
        let zip = root.appendingPathComponent("diagnostic.zip")
        try DiagnosticExporter(diagnostics: log).createArchive(to: zip, snapshot: ["path": FileManager.default.homeDirectoryForCurrentUser.path + "/data", "power.mode": "system"])
        let unpacked = root.appendingPathComponent("unpacked")
        let result = try CommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", zip.path, unpacked.path], timeout: 5)
        XCTAssertEqual(result.exitCode, 0)
        let package = unpacked.appendingPathComponent("KeepAwake诊断")
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: package.appendingPathComponent("state.json"))) as! [String: String]
        XCTAssertEqual(state["path"], "~/data")
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.appendingPathComponent("说明.txt").path))
        let logs = try FileManager.default.contentsOfDirectory(at: package.appendingPathComponent("logs"), includingPropertiesForKeys: nil)
        XCTAssertTrue(try logs.contains { try String(contentsOf: $0).contains("issue-123") })
    }
    func testSingleInstanceLockCanBeReacquiredAfterOwnerExits() throws {
        let path = root.appendingPathComponent("app.lock")
        var first: InstanceLock? = InstanceLock()
        XCTAssertTrue(try first!.acquire(at: path))
        let second = InstanceLock(); XCTAssertFalse(try second.acquire(at: path))
        first = nil
        XCTAssertTrue(try second.acquire(at: path))
    }
    func testRetentionRemovesOnlyOldOwnedLogFiles() throws {
        let log = logger()
        try FileManager.default.createDirectory(at: log.directory, withIntermediateDirectories: true)
        let old = log.directory.appendingPathComponent("events-old.jsonl")
        let unrelated = log.directory.appendingPathComponent("keep.txt")
        try Data().write(to: old); try Data().write(to: unrelated)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -15 * 86400)], ofItemAtPath: old.path)
        log.record("test", "cleanup"); log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
