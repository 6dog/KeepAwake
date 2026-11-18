import Foundation
import os
import Darwin

/// The only persistent event sink. Fields are sanitized before either file or system logging.
final class Diagnostics {
    static let shared = Diagnostics()
    struct Configuration {
        var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/KeepAwake", isDirectory: true)
        var fileLimit = 5 * 1024 * 1024
        var totalLimit = 50 * 1024 * 1024
        var retention: TimeInterval = 14 * 86400
    }
    private let configuration: Configuration
    private let queue = DispatchQueue(label: "KeepAwake.Diagnostics", qos: .utility)
    private let lock = NSLock()
    private let system = Logger(subsystem: "com.jesseyun.KeepAwake", category: "Diagnostics")
    private var sequence = 0
    private var file: URL?
    private var detailedUntil: TimeInterval = 0
    private var storageFailure: String?
    private let uptime: () -> TimeInterval
    let session = UUID().uuidString
    var directory: URL { configuration.directory }
    var isDetailed: Bool {
        lock.lock()
        let expired = detailedUntil > 0 && uptime() >= detailedUntil
        if expired { detailedUntil = 0 }
        let active = uptime() < detailedUntil
        lock.unlock()
        if expired { record("diagnostics", "detail_expired") }
        return active
    }
    var error: String? { lock.lock(); defer { lock.unlock() }; return storageFailure }

    init(configuration: Configuration = Configuration(), uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.configuration = configuration
        self.uptime = uptime
    }
    func setDetailed(_ enabled: Bool) {
        lock.lock(); detailedUntil = enabled ? uptime() + 1800 : 0; lock.unlock()
        record("diagnostics", "detail_changed", fields: ["enabled": String(enabled), "durationSeconds": enabled ? "1800" : "0"])
    }
    static func sanitize(_ text: String) -> String {
        var value = text.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        value = value.replacingOccurrences(of: #"/Users/[^/\s\"']+"#, with: "~", options: .regularExpression)
        value = value.replacingOccurrences(of: NSUserName(), with: "<user>")
        return String(value.prefix(2048))
    }
    func record(_ component: String, _ event: String, level: String = "info", operation: String? = nil, fields: [String: String] = [:]) {
        if level == "debug" && !isDetailed { return }
        let safe = fields.mapValues(Self.sanitize)
        let elapsed = uptime()
        queue.async {
            self.sequence += 1
            var row: [String: Any] = ["schema": 1, "time": ISO8601DateFormatter().string(from: Date()), "uptime": elapsed,
                                      "session": self.session, "sequence": self.sequence, "level": level,
                                      "component": component, "event": event, "fields": safe]
            if let operation { row["operation"] = operation }
            do {
                let line = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])
                try self.append(line)
            } catch {
                self.lock.lock(); self.storageFailure = Self.sanitize(error.localizedDescription); self.lock.unlock()
                self.system.error("File logging unavailable: \(Self.sanitize(error.localizedDescription), privacy: .public)")
            }
            if level == "error" {
                self.system.error("\(component, privacy: .public).\(event, privacy: .public) \(String(describing: safe), privacy: .public)")
            }
        }
    }
    func failure(_ component: String, _ event: String, _ error: Error, operation: String? = nil) {
        let ns = error as NSError
        var fields = ["message": error.localizedDescription, "domain": ns.domain, "code": String(ns.code)]
        if let display = error as? DisplayControlError {
            fields["stage"] = display.stage
            fields["code"] = display.code.map(String.init) ?? fields["code"]
        }
        if let power = error as? PowerFailure { fields["stage"] = power.stage; fields["code"] = String(power.code); fields["domain"] = "IOKit" }
        record(component, event, level: "error", operation: operation, fields: fields)
    }
    private func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func append(_ line: Data) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let current = file, !fm.fileExists(atPath: current.path) { file = nil }
        let currentSize = file.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        if file == nil || currentSize + line.count > configuration.fileLimit {
            file = directory.appendingPathComponent("events-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).jsonl")
            guard fm.createFile(atPath: file!.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: file!)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line)
        if line.count > configuration.totalLimit { throw CocoaError(.fileWriteOutOfSpace) }
        var retained: [(URL, Int)] = []
        for url in try files() {
            let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if url != file && Date().timeIntervalSince(info.contentModificationDate ?? Date()) > configuration.retention {
                try fm.removeItem(at: url)
            } else { retained.append((url, info.fileSize ?? 0)) }
        }
        var total = retained.reduce(0) { $0 + $1.1 }
        for (url, size) in retained where total > configuration.totalLimit && url != file {
            try fm.removeItem(at: url); total -= size
        }
        lock.lock(); storageFailure = nil; lock.unlock()
    }
    func flush() { queue.sync {} }
    /// Serialize copying with writes so each exported line is complete.
    func copyLogs(to target: URL) throws {
        try queue.sync {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: directory.path) { return }
            for source in try files() { try FileManager.default.copyItem(at: source, to: target.appendingPathComponent(source.lastPathComponent)) }
        }
    }
    private var marker: URL { directory.appendingPathComponent("active-session.json") }
    func beginSession() {
        queue.sync {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if let data = try? Data(contentsOf: marker), let old = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    record("lifecycle", "previous_session_unclean", level: "warning", fields: ["previousSession": old["session"] ?? "unknown"])
                }
                try JSONSerialization.data(withJSONObject: ["session": session]).write(to: marker, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
            } catch {
                lock.lock(); storageFailure = Self.sanitize(error.localizedDescription); lock.unlock()
            }
        }
        record("lifecycle", "started", fields: ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                                                  "os": ProcessInfo.processInfo.operatingSystemVersionString])
    }
    func endSession() {
        record("lifecycle", "clean_exit")
        queue.sync { try? FileManager.default.removeItem(at: marker) }
    }
}

final class InstanceLock {
    private var descriptor: Int32 = -1
    func acquire(at url: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/KeepAwake/instance.lock")) throws -> Bool {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EACCES) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno; close(fd)
            if code == EWOULDBLOCK { return false }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
        return true
    }
    deinit { if descriptor >= 0 { close(descriptor) } }
}
