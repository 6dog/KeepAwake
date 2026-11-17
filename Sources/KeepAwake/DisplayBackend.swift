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
    var errorDescription: String? { message }
}

protocol DisplayBackend {
    func displays() throws -> [ManagedDisplay]
    func setBuiltInEnabled(_ enabled: Bool) throws
    func restoreMirror(_ source: String, to target: String) throws
}

/// Private entry points are optional at runtime; missing symbols must never prevent app launch.
final class SkyLightDisplayBackend: DisplayBackend {
    private typealias List = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> CGError
    private typealias Enable = @convention(c) (CGDisplayConfigRef?, UInt32, Bool) -> CGError
    private typealias Info = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
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
            try check(list(UInt32(capacity), &ids, &count))
            if count < capacity {
                return ids.prefix(Int(count)).compactMap { id in
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
        // A disabled screen disappears from public lists. Resolve it from SkyLight every time.
        let current = try displays()
        guard let panel = current.first(where: \.builtIn) else {
            throw DisplayControlError(message: "未找到内置屏幕，请保持笔记本开盖")
        }
        if panel.online == enabled { return }
        if !enabled && !current.contains(where: \.usableExternal) {
            throw DisplayControlError(message: "没有可用的实体外接屏，已取消关闭内置屏幕")
        }
        let set = try symbol("CGSConfigureDisplayEnabled", in: sky, as: Enable.self)
        try transaction { config in
            if !enabled {
                // Mirroring can be rooted in either screen. Detach every member of this pair.
                for display in current where display.id == panel.id || display.mirrors == panel.id {
                    if display.mirrors != 0 { try self.check(CGConfigureDisplayMirrorOfDisplay(config, display.id, 0)) }
                }
            }
            try self.check(set(config, panel.id, enabled))
        }
    }

    func restoreMirror(_ source: String, to target: String) throws {
        let current = try displays()
        guard let a = current.first(where: { $0.identity == source && $0.online }),
              let b = current.first(where: { $0.identity == target && $0.online }) else { return }
        if a.mirrors == b.id { return }
        try transaction { try self.check(CGConfigureDisplayMirrorOfDisplay($0, a.id, b.id)) }
    }

    private func transaction(_ body: (CGDisplayConfigRef) throws -> Void) throws {
        var config: CGDisplayConfigRef?
        try check(CGBeginDisplayConfiguration(&config))
        guard let config else { throw DisplayControlError(message: "无法建立屏幕配置事务") }
        do { try body(config) } catch { CGCancelDisplayConfiguration(config); throw error }
        // Session scoped: do not persist a disabled panel as the login display layout.
        try check(CGCompleteDisplayConfiguration(config, .forSession))
    }

    private func check(_ error: CGError) throws {
        if error != .success { throw DisplayControlError(message: "屏幕配置失败（\(error.rawValue)）") }
    }
}
