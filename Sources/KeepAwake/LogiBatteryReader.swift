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
        LogiBatteryStatus(
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

    private let queue = DispatchQueue(label: "KeepAwake.LogiBatteryReader", qos: .utility)

    func read(completion: @escaping (LogiBatteryStatus) -> Void) {
        queue.async {
            let status = self.readSynchronously()
            DispatchQueue.main.async {
                completion(status)
            }
        }
    }

    private func readSynchronously() -> LogiBatteryStatus {
        guard let scriptURL = batteryScriptURL() else {
            return .unavailable("check_logi_battery.py not found")
        }

        var failures: [String] = []
        for pythonPath in pythonCandidates() {
            switch run(scriptURL: scriptURL, pythonPath: pythonPath) {
            case .success(let status):
                return status
            case .failure(let message):
                failures.append("\((pythonPath as NSString).lastPathComponent): \(message)")
            }
        }

        return .unavailable(failures.isEmpty ? "python3 not found" : failures.joined(separator: "; "))
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
        let rawCandidates = [
            environment["LOGI_BATTERY_PYTHON"],
            "/Library/Frameworks/Python.framework/Versions/3.14/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }

        var seen = Set<String>()
        return rawCandidates.filter { path in
            guard !seen.contains(path), FileManager.default.isExecutableFile(atPath: path) else {
                return false
            }
            seen.insert(path)
            return true
        }
    }

    private func run(scriptURL: URL, pythonPath: String) -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptURL.path, "--json"]
        process.currentDirectoryURL = scriptURL.deletingLastPathComponent()

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return .failure(error.localizedDescription)
        }

        if finished.wait(timeout: .now() + .seconds(10)) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + .seconds(2)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + .seconds(1))
            }
            return .failure("timed out")
        }

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        let stderrText = String(data: stderrData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            return .failure(stderrText?.isEmpty == false ? stderrText! : "exit \(process.terminationStatus)")
        }

        do {
            let payload = try JSONDecoder().decode(Payload.self, from: stdoutData)
            guard payload.ok else {
                return .success(.unavailable(payload.error ?? "receiver not found"))
            }
            guard let percent = payload.percent else {
                return .success(.unavailable("battery percent missing"))
            }
            return .success(.available(
                percent: percent,
                deviceStatus: payload.status
            ))
        } catch {
            let stdoutText = String(data: stdoutData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(stdoutText?.isEmpty == false ? stdoutText! : error.localizedDescription)
        }
    }
}
