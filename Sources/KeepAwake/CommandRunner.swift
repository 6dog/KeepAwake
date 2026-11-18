import Foundation
import Darwin

final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
struct CommandResult {
    let output: Data
    let errorOutput: Data
    let exitCode: Int32
    let truncated: Bool
}
enum CommandFailure: LocalizedError {
    case cancelled, timedOut
    var errorDescription: String? { self == .cancelled ? "操作已取消" : "子进程超时" }
}
/// Nonblocking, bounded pipe reads avoid deadlock even when a child floods stderr/stdout.
struct CommandRunner {
    func run(executable: URL, arguments: [String], directory: URL? = nil, timeout: TimeInterval,
             token: CancellationToken = CancellationToken(), outputLimit: Int = 65536) throws -> CommandResult {
        if token.isCancelled { throw CommandFailure.cancelled }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments; process.currentDirectoryURL = directory
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        try process.run()
        defer {
            try? out.fileHandleForReading.close(); try? out.fileHandleForWriting.close()
            try? err.fileHandleForReading.close(); try? err.fileHandleForWriting.close()
        }
        for handle in [out.fileHandleForReading, err.fileHandleForReading] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            _ = fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK)
        }
        var stdout = Data(), stderr = Data(), truncated = false
        func drain(_ handle: FileHandle, into data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<32 {
                let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                if count <= 0 { return }
                let keep = min(count, max(0, outputLimit - data.count))
                if keep > 0 { data.append(contentsOf: buffer.prefix(keep)) }
                if keep < count { truncated = true }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var failure: CommandFailure?
        while true {
            drain(out.fileHandleForReading, into: &stdout)
            drain(err.fileHandleForReading, into: &stderr)
            if !process.isRunning { break }
            if token.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline {
                failure = token.isCancelled ? .cancelled : .timedOut
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                    drain(out.fileHandleForReading, into: &stdout); drain(err.fileHandleForReading, into: &stderr)
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                    let end = ProcessInfo.processInfo.systemUptime + 1
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.01) }
                }
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        drain(out.fileHandleForReading, into: &stdout); drain(err.fileHandleForReading, into: &stderr)
        if let failure { throw failure }
        return CommandResult(output: stdout, errorOutput: stderr, exitCode: process.terminationStatus, truncated: truncated)
    }
}

final class DiagnosticExporter {
    private let diagnostics: Diagnostics
    init(diagnostics: Diagnostics = .shared) { self.diagnostics = diagnostics }
    func export(to destination: URL, snapshot: [String: String], completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try self.createArchive(to: destination, snapshot: snapshot) }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func createArchive(to destination: URL, snapshot: [String: String]) throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("KeepAwake-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temporary) }
        let package = temporary.appendingPathComponent("KeepAwake诊断", isDirectory: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        try diagnostics.copyLogs(to: package.appendingPathComponent("logs", isDirectory: true))
        let safe = snapshot.mapValues(Diagnostics.sanitize)
        try JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]).write(to: package.appendingPathComponent("state.json"))
        let readme = """
        Keep Awake 本地诊断包
        state.json：导出时的版本、相关设置、最近一次屏幕状态和本程序的防休眠断言。
        logs/：JSONL 事件日志。按 session（运行会话）、operation（操作编号）、sequence（顺序）关联。
        requested / decision / applied / verified / failed / retry 说明从请求到实际结果的过程。
        previous_session_unclean 仅表示上次未正常结束，不能单独证明崩溃。
        设备标识和用户目录已脱敏；未采集屏幕内容、录音或其他应用的活动详情。
        日志中可能出现你手动标记的问题编号，可将编号与问题发生时间一同用于排查。
        本文件由本机生成，不会自动上传。
        """
        try Data(readme.utf8).write(to: package.appendingPathComponent("说明.txt"))
        let zip = temporary.appendingPathComponent("diagnostic.zip")
        let result = try CommandRunner().run(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", package.path, zip.path], timeout: 20)
        guard result.exitCode == 0 else { throw CocoaError(.fileWriteUnknown) }
        try Data(contentsOf: zip, options: .mappedIfSafe).write(to: destination, options: .atomic)
        diagnostics.record("diagnostics", "exported")
    }
}
