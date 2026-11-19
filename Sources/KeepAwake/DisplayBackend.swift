import AppKit
import CoreGraphics
import Darwin

struct ManagedDisplay: Equatable {
    let id: CGDirectDisplayID
    let identity: String
    let builtIn: Bool
    let online: Bool
    let active: Bool
    let physical: Bool
    let mirrors: CGDirectDisplayID

    var usableExternal: Bool { !builtIn && online && physical && (active || mirrors != 0) }
}

struct DisplayControlError: LocalizedError {
    let message: String
    var stage: String = "display"
    var code: Int32? = nil
    var errorDescription: String? { message }
}

protocol DisplayBackend {
    func displays() throws -> [ManagedDisplay]
    func setBuiltInEnabled(_ enabled: Bool) throws
    func restoreMirror(_ source: String, to target: String) throws
}

/// A software-disabled panel can disappear from even SkyLight after the last cable is removed.
/// Remember only a confirmed built-in ID, scoped to this boot so IDs are never reused across boots.
final class BuiltInDisplayTarget {
    private let defaults: UserDefaults
    private let boot: String?
    private let key = "builtInDisplayRecoveryTarget"
    init(defaults: UserDefaults, boot: String?) { self.defaults = defaults; self.boot = boot }
    func resolve(in screens: [ManagedDisplay], restoring: Bool) -> CGDirectDisplayID? {
        if let panel = screens.first(where: \.builtIn) {
            if let boot {
                let saved = defaults.dictionary(forKey: key)
                if saved?["boot"] as? String != boot || saved?["id"] as? Int != Int(panel.id) {
                    defaults.set(["boot": boot, "id": Int(panel.id)], forKey: key)
                    defaults.synchronize()
                }
            }
            return panel.id
        }
        guard restoring, let boot, let saved = defaults.dictionary(forKey: key),
              saved["boot"] as? String == boot, let value = saved["id"] as? Int,
              value > 0, value <= Int(UInt32.max) else { return nil }
        let id = UInt32(value)
        // A currently enumerated external display must never be mistaken for the panel.
        guard !screens.contains(where: { $0.id == id }) else { return nil }
        return id
    }
}

/// Private entry points are optional at runtime; missing symbols must never prevent app launch.
final class SkyLightDisplayBackend: DisplayBackend {
    private typealias List = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> CGError
    private typealias Enable = @convention(c) (CGDisplayConfigRef?, UInt32, Bool) -> CGError
    private typealias Info = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    private let target: BuiltInDisplayTarget
    private let diagnostics: Diagnostics
    init(defaults: UserDefaults = .standard, diagnostics: Diagnostics = .shared) {
        var size = 0
        var boot: String?
        if sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 {
                boot = String(cString: buffer)
            }
        }
        target = BuiltInDisplayTarget(defaults: defaults, boot: boot)
        self.diagnostics = diagnostics
    }
    private let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)

    private func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?, as type: T.Type) throws -> T {
        guard let handle, let pointer = dlsym(handle, name) else {
            throw DisplayControlError(message: "当前系统不支持屏幕控制（缺少 \(name)）")
        }
        return unsafeBitCast(pointer, to: type)
    }

    func displays() throws -> [ManagedDisplay] {
        let list = try symbol("CGSGetDisplayList", in: sky, as: List.self)
        // Check both control symbols before offering automation.
        _ = try symbol("CGSConfigureDisplayEnabled", in: sky, as: Enable.self)
        let info = try symbol("CoreDisplay_DisplayCreateInfoDictionary", in: core, as: Info.self)
        var capacity = 16
        while capacity <= 1024 {
            var ids = [UInt32](repeating: 0, count: capacity)
            var count: UInt32 = 0
            try check(list(UInt32(capacity), &ids, &count), stage: "enumerate")
            if count < capacity {
                let screens: [ManagedDisplay] = ids.prefix(Int(count)).compactMap { id in
                    let builtIn = CGDisplayIsBuiltin(id) != 0
                    let vendor = CGDisplayVendorNumber(id)
                    let model = CGDisplayModelNumber(id)
                    guard builtIn || vendor != 0 || model != 0 else { return nil }
                    let dictionary = info(id)?.takeRetainedValue() as NSDictionary?
                    let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
                    let identity = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? "\(vendor):\(model):\(CGDisplaySerialNumber(id))"
                    return ManagedDisplay(
                        id: id, identity: identity, builtIn: builtIn,
                        online: CGDisplayIsOnline(id) != 0, active: CGDisplayIsActive(id) != 0,
                        physical: builtIn || Self.isPhysical(dictionary), mirrors: CGDisplayMirrorsDisplay(id)
                    )
                }
                _ = target.resolve(in: screens, restoring: false)
                return screens
            }
            capacity *= 2
        }
        throw DisplayControlError(message: "显示器列表过大，已停止自动控制")
    }

    static func isPhysical(_ info: NSDictionary?) -> Bool {
        guard let info,
              let virtual = info["kCGDisplayIsVirtualDevice"] as? NSNumber,
              let airPlay = info["kCGDisplayIsAirPlay"] as? NSNumber,
              !virtual.boolValue, !airPlay.boolValue,
              let location = info["IODisplayLocation"] as? String,
              location.hasPrefix("IOService:"),
              !location.localizedCaseInsensitiveContains("virtual"),
              !location.localizedCaseInsensitiveContains("sidecar") else { return false }
        return true
    }

    func setBuiltInEnabled(_ enabled: Bool) throws {
        // Prefer a fresh SkyLight ID; restore from the same-boot saved target if it vanishes.
        let current = try displays()
        guard let panelID = target.resolve(in: current, restoring: enabled) else {
            throw DisplayControlError(message: "未找到内置屏幕，请保持笔记本开盖")
        }
        if let panel = current.first(where: { $0.id == panelID }), panel.online == enabled { return }
        if enabled && !current.contains(where: \.builtIn) {
            diagnostics.record("display", "restore_using_saved_target", fields: ["id": String(panelID)])
        }
        if !enabled && !current.contains(where: \.usableExternal) {
            throw DisplayControlError(message: "没有可用的实体外接屏，已取消关闭内置屏幕")
        }
        let set = try symbol("CGSConfigureDisplayEnabled", in: sky, as: Enable.self)
        try transaction { config in
            if !enabled {
                // Mirroring can be rooted in either screen. Detach every member of this pair.
                for display in current where display.id == panelID || display.mirrors == panelID {
                    if display.mirrors != 0 { try self.check(CGConfigureDisplayMirrorOfDisplay(config, display.id, 0), stage: "unmirror") }
                }
            }
            try self.check(set(config, panelID, enabled), stage: enabled ? "enable" : "disable")
        }
    }

    func restoreMirror(_ source: String, to target: String) throws {
        let current = try displays()
        guard let a = current.first(where: { $0.identity == source && $0.online }),
              let b = current.first(where: { $0.identity == target && $0.online }) else { return }
        if a.mirrors == b.id { return }
        try transaction { try self.check(CGConfigureDisplayMirrorOfDisplay($0, a.id, b.id), stage: "restore_mirror") }
    }

    private func transaction(_ body: (CGDisplayConfigRef) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&config), stage: "begin")
        guard let config else { throw DisplayControlError(message: "无法建立屏幕配置事务") }
        do { try body(config) } catch { CGCancelDisplayConfiguration(config); throw error }
        // Session scoped: do not persist a disabled panel as the login display layout.
        try check(CGCompleteDisplayConfiguration(config, .forSession), stage: "commit")
    }

    private func check(_ error: CGError, stage: String = "configure") throws {
        if error != .success { throw DisplayControlError(message: "屏幕配置失败（\(error.rawValue)）", stage: stage, code: error.rawValue) }
    }
}
