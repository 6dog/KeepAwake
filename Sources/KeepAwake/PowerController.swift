import Foundation
import IOKit.pwr_mgt

enum PowerMode: String, CaseIterable, Identifiable {
    case system, preventSleep, displayOn
    var id: String { rawValue }
    var title: String { switch self { case .system: return "跟随系统"; case .preventSleep: return "仅防休眠"; case .displayOn: return "屏幕常亮" } }
    var explanation: String {
        switch self {
        case .system: return "按 macOS 设置自动熄屏与睡眠"
        case .preventSleep: return "电脑保持运行，屏幕可以自动熄灭"
        case .displayOn: return "保持启用的屏幕亮起，同时防止电脑自动睡眠"
        }
    }
    static func saved(in defaults: UserDefaults, diagnostics: Diagnostics? = nil) -> PowerMode {
        if let value = defaults.string(forKey: "powerMode"), let mode = PowerMode(rawValue: value) { return mode }
        let display = defaults.object(forKey: "keepDisplayAwake") != nil ? defaults.bool(forKey: "keepDisplayAwake") : defaults.string(forKey: "awakeMode") != "allowDisplaySleep"
        let system = defaults.object(forKey: "preventSystemSleep") != nil ? defaults.bool(forKey: "preventSystemSleep") : defaults.string(forKey: "awakeMode") == "allowDisplaySleep"
        let mode: PowerMode = display ? .displayOn : (system ? .preventSleep : .system)
        defaults.set(mode.rawValue, forKey: "powerMode")
        diagnostics?.record("settings", "power_mode_migrated", fields: ["mode": mode.rawValue, "legacyDisplay": String(display), "legacySystem": String(system)])
        return mode
    }
}
protocol PowerBackend {
    func create(display: Bool) throws -> UInt32
    func release(_ id: UInt32) throws
}
struct PowerFailure: LocalizedError {
    let stage: String
    let code: Int32
    var errorDescription: String? { "\(stage)失败（IOKit \(code)）" }
}
final class IOKitPowerBackend: PowerBackend {
    func create(display: Bool) throws -> UInt32 {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName((display ? kIOPMAssertionTypePreventUserIdleDisplaySleep : kIOPMAssertionTypePreventUserIdleSystemSleep) as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn), "Keep Awake - \(display ? "Display" : "System") awake" as CFString, &id)
        guard result == kIOReturnSuccess else { throw PowerFailure(stage: "创建防休眠断言", code: result) }
        return id
    }
    func release(_ id: UInt32) throws {
        let result = IOPMAssertionRelease(id)
        guard result == kIOReturnSuccess else { throw PowerFailure(stage: "释放防休眠断言", code: result) }
    }
}
final class PowerController {
    private let backend: PowerBackend
    private let defaults: UserDefaults
    private let diagnostics: Diagnostics
    private(set) var displayID: UInt32 = 0
    private(set) var systemID: UInt32 = 0
    private(set) var lastError: String?
    var mode: PowerMode { displayID != 0 ? .displayOn : (systemID != 0 ? .preventSleep : .system) }
    var snapshot: [String: String] { ["mode": mode.rawValue, "displayAssertion": String(displayID), "systemAssertion": String(systemID), "error": lastError ?? ""] }
    init(backend: PowerBackend = IOKitPowerBackend(), defaults: UserDefaults = .standard, diagnostics: Diagnostics = .shared) {
        self.backend = backend; self.defaults = defaults; self.diagnostics = diagnostics
    }
    @discardableResult func apply(_ target: PowerMode, persist: Bool = true, trigger: String = "user") -> Bool {
        let operation = UUID().uuidString
        diagnostics.record("power", "requested", operation: operation, fields: ["target": target.rawValue, "before": mode.rawValue, "trigger": trigger])
        var created: [UInt32] = []
        do {
            if target != .system && systemID == 0 { systemID = try create(display: false, operation: operation); created.append(systemID) }
            if target == .displayOn && displayID == 0 { displayID = try create(display: true, operation: operation); created.append(displayID) }
        } catch {
            // Roll back only new assertions, never discard a previously working configuration.
            for id in created.reversed() {
                do { try release(id, operation: operation); if displayID == id { displayID = 0 }; if systemID == id { systemID = 0 } }
                catch { diagnostics.failure("power", "rollback_failed", error, operation: operation) }
            }
            return failed(error, operation)
        }
        do {
            if target != .displayOn && displayID != 0 { try release(displayID, operation: operation); displayID = 0 }
            if target == .system && systemID != 0 { try release(systemID, operation: operation); systemID = 0 }
            lastError = nil
            if persist { defaults.set(target.rawValue, forKey: "powerMode") }
            diagnostics.record("power", "applied", operation: operation, fields: snapshot)
            return true
        } catch { return failed(error, operation) }
    }
    static func systemSummary() -> [String: String] {
        var value: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsStatus(&value)
        guard result == kIOReturnSuccess, let dictionary = value?.takeRetainedValue() as? [String: Any] else { return ["queryCode": String(result)] }
        return dictionary.reduce(into: [String: String]()) { result, pair in
            if let number = pair.value as? NSNumber { result[pair.key] = number.stringValue }
        }
    }
    private func create(display: Bool, operation: String) throws -> UInt32 {
        let id = try backend.create(display: display)
        diagnostics.record("power", "assertion_created", operation: operation, fields: ["kind": display ? "display" : "system", "id": String(id)])
        return id
    }
    private func release(_ id: UInt32, operation: String) throws {
        try backend.release(id)
        diagnostics.record("power", "assertion_released", operation: operation, fields: ["id": String(id)])
    }
    private func failed(_ error: Error, _ operation: String) -> Bool {
        lastError = error.localizedDescription
        diagnostics.failure("power", "failed", error, operation: operation)
        diagnostics.record("power", "actual_state", operation: operation, fields: snapshot)
        return false
    }
}
