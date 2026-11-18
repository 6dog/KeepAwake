import XCTest
@testable import KeepAwake

final class CommandRunnerTests: XCTestCase {
    func testLargeOutputDoesNotDeadlockAndIsBounded() throws {
        let result = try CommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import os; os.write(1,b'x'*1000000); os.write(2,b'y'*1000000)"], timeout: 5, outputLimit: 2048)
        XCTAssertEqual(result.exitCode, 0); XCTAssertEqual(result.output.count, 2048); XCTAssertEqual(result.errorOutput.count, 2048); XCTAssertTrue(result.truncated)
    }
    func testTimeoutTerminatesUnresponsiveChildWithinBudget() {
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try CommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time; time.sleep(60)"], timeout: 0.1))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 4)
    }
    func testCancellationStopsInFlightOperation() {
        let token = CancellationToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { token.cancel() }
        XCTAssertThrowsError(try CommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-c", "import time; time.sleep(60)"], timeout: 10, token: token)) { error in
            XCTAssertEqual(error as? CommandFailure, .cancelled)
        }
    }
    func testPrecancelledOperationDoesNotLaunch() {
        let token = CancellationToken(); token.cancel()
        XCTAssertThrowsError(try CommandRunner().run(executable: URL(fileURLWithPath: "/missing"), arguments: [], timeout: 1, token: token)) { XCTAssertEqual($0 as? CommandFailure, .cancelled) }
    }
    func testExitCodeAndShortOutputArePreserved() throws {
        let result = try CommandRunner().run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo failure >&2; exit 7"], timeout: 2)
        XCTAssertEqual(result.exitCode, 7); XCTAssertTrue(String(data: result.errorOutput, encoding: .utf8)!.contains("failure"))
    }
}
