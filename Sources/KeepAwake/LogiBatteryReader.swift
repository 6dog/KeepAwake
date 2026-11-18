import Darwin
import Foundation

struct LogiBatteryStatus {
    enum Availability {
        case loading
        case available
        case unavailable
    }

    let availability: Availability
    let percent: Int?
    let deviceStatus: String?
    let errorMessage: String?

    static let loading = LogiBatteryStatus(
        availability: .loading,
        percent: nil,
        deviceStatus: nil,
        errorMessage: nil
    )

    static func available(
        percent: Int,
        deviceStatus: String?
    ) -> LogiBatteryStatus {
        guard (0...100).contains(percent) else {
            return .unavailable("invalid battery percent")
        }

        return LogiBatteryStatus(
            availability: .available,
            percent: percent,
            deviceStatus: deviceStatus,
            errorMessage: nil
        )
    }

    static func unavailable(_ message: String) -> LogiBatteryStatus {
        LogiBatteryStatus(
            availability: .unavailable,
            percent: nil,
            deviceStatus: nil,
            errorMessage: message
        )
    }

    var tooltipTitle: String {
        switch availability {
        case .loading:
            return "正在读取 Logitech 电量"
        case .available:
            var title = "Logitech 电量 \(percent ?? 0)%"
            if let deviceStatus, !deviceStatus.isEmpty {
                title += " - \(Self.localizedDeviceStatus(deviceStatus))"
            }
            return title
        case .unavailable:
            return "Logitech 电量不可用：\(localizedErrorMessage)"
        }
    }

    private var localizedErrorMessage: String {
        guard let errorMessage, !errorMessage.isEmpty else {
            return "未知错误"
        }

        switch errorMessage {
        case "receiver not found":
            return "未找到接收器"
        case "mouse asleep or out of range":
            return "鼠标休眠或超出范围"
        case "no battery feature":
            return "设备不支持电量读取"
        case "invalid battery percent":
            return "设备返回了无效电量"
        default:
            if errorMessage.hasPrefix("open failed") {
                return "无法打开接收器"
            }
            return errorMessage
        }
    }

    private static func localizedDeviceStatus(_ status: String) -> String {
        switch status {
        case "discharging":
            return "放电中"
        case "charging", "recharging":
            return "充电中"
        case "charging slow":
            return "慢速充电"
        case "charging done", "almost full", "full":
            return "已充满"
        case "charging fast":
            return "快速充电"
        case "low":
            return "电量低"
        case "critical":
            return "严重低电量"
        case "error":
            return "电量状态错误"
        default:
            return status
        }
    }
}

final class LogiBatteryReader {
    private enum RunResult {
        case success(LogiBatteryStatus)
        case failure(String)
    }

    private struct Payload: Decodable {
        let ok: Bool
        let error: String?
        let percent: Int?
        let status: String?
    }

    private let tokenLock = NSLock()
    private var currentToken: CancellationToken?
    private let diagnostics: Diagnostics

    init(diagnostics: Diagnostics = .shared) { self.diagnostics = diagnostics }

    func cancel() { tokenLock.lock(); currentToken?.cancel(); tokenLock.unlock() }

    private let queue = DispatchQueue(label: "KeepAwake.LogiBatteryReader", qos: .utility)

    func read(completion: @escaping (LogiBatteryStatus) -> Void) {
        let token = CancellationToken()
        tokenLock.lock(); currentToken?.cancel(); currentToken = token; tokenLock.unlock()
        queue.async {
            let status = self.readSynchronously(token: token)
            DispatchQueue.main.async {
                completion(status)
            }
        }
    }

    private func readSynchronously(token: CancellationToken) -> LogiBatteryStatus {
        let operation = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        diagnostics.record("battery", "requested", operation: operation)
        guard let scriptURL = batteryScriptURL() else {
            diagnostics.record("battery", "script_missing", level: "error", operation: operation)
            return .unavailable("check_logi_battery.py not found")
        }
        var failures: [String] = []
        for pythonPath in pythonCandidates() {
            if token.isCancelled { return .unavailable("读取已取消") }
            let remaining = 20 - (ProcessInfo.processInfo.systemUptime - started)
            if remaining <= 0 { failures.append("整次读取超时"); break }
            switch run(scriptURL: scriptURL, pythonPath: pythonPath, timeout: min(10, remaining), token: token, operation: operation) {
            case .success(let status):
                diagnostics.record("battery", "completed", operation: operation, fields: ["percent": status.percent.map(String.init) ?? "unavailable", "error": status.errorMessage ?? "", "elapsed": String(ProcessInfo.processInfo.systemUptime - started)])
                return status
            case .failure(let message):
                failures.append("\((pythonPath as NSString).lastPathComponent): \(message)")
            }
        }

        let message = failures.isEmpty ? "python3 not found" : failures.joined(separator: "; ")
        diagnostics.record("battery", "failed", level: "error", operation: operation, fields: ["message": message])
        return .unavailable(Diagnostics.sanitize(message))
    }

    private func batteryScriptURL() -> URL? {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("check_logi_battery.py"))
        }

        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(sourceRoot.appendingPathComponent("Resources/check_logi_battery.py"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/check_logi_battery.py"))

        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    private func pythonCandidates() -> [String] {
        let environment = ProcessInfo.processInfo.environment
        var rawCandidates = [environment["LOGI_BATTERY_PYTHON"]].compactMap { $0 }

        if let versionsDirectory = try? FileManager.default.contentsOfDirectory(
            atPath: "/Library/Frameworks/Python.framework/Versions"
        ) {
            rawCandidates.append(contentsOf: versionsDirectory
                .sorted(by: >)
                .map { "/Library/Frameworks/Python.framework/Versions/\($0)/bin/python3" })
        }

        if let path = environment["PATH"] {
            rawCandidates.append(contentsOf: path
                .split(separator: ":")
                .map { "\($0)/python3" })
        }

        rawCandidates.append(contentsOf: [
            "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3"
        ])

        var seen = Set<String>()
        return rawCandidates.filter { path in
            guard !seen.contains(path), FileManager.default.isExecutableFile(atPath: path) else {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    private func run(scriptURL: URL, pythonPath: String, timeout: TimeInterval, token: CancellationToken, operation: String) -> RunResult {
        do {
            diagnostics.record("battery", "candidate", operation: operation, fields: ["python": pythonPath])
            let result = try CommandRunner().run(executable: URL(fileURLWithPath: pythonPath), arguments: [scriptURL.path, "--json"], directory: scriptURL.deletingLastPathComponent(), timeout: timeout, token: token)
            diagnostics.record("battery", "process_finished", operation: operation, fields: ["exitCode": String(result.exitCode), "stdoutBytes": String(result.output.count), "stderrBytes": String(result.errorOutput.count), "truncated": String(result.truncated)])
            guard !result.truncated else { return .failure("电量程序输出过长") }
            guard result.exitCode == 0 else {
                let reason = String(data: result.errorOutput, encoding: .utf8)?.split(whereSeparator: \.isNewline).last.map { Diagnostics.sanitize(String($0.prefix(512))) } ?? ""
                diagnostics.record("battery", "process_error", level: "error", operation: operation, fields: ["exitCode": String(result.exitCode), "reason": reason])
                return .failure("电量程序退出码 \(result.exitCode)" + (reason.isEmpty ? "" : "：\(reason)"))
            }
            do {
                let payload = try JSONDecoder().decode(Payload.self, from: result.output)
                guard payload.ok else { return .success(.unavailable(Diagnostics.sanitize(payload.error ?? "receiver not found"))) }
                guard let percent = payload.percent else { return .success(.unavailable("battery percent missing")) }
                return .success(.available(percent: percent, deviceStatus: payload.status))
            } catch {
                diagnostics.failure("battery", "decode_failed", error, operation: operation)
                return .failure("电量响应无法解析")
            }
        } catch {
            diagnostics.failure("battery", "process_failed", error, operation: operation)
            return .failure(Diagnostics.sanitize(error.localizedDescription))
        }
    }
}
