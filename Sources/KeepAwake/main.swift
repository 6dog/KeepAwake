import AppKit
import IOKit.pwr_mgt

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let batteryRefreshInterval: TimeInterval = 24 * 60 * 60

    private enum DefaultsKey {
        static let keepDisplayAwake = "keepDisplayAwake"
        static let preventSystemSleep = "preventSystemSleep"
        static let legacyAwakeMode = "awakeMode"
    }

    private var statusItem: NSStatusItem!
    private var displayAssertionID = IOPMAssertionID(0)
    private var systemAssertionID = IOPMAssertionID(0)
    private let batteryReader = LogiBatteryReader()
    private var batteryTimer: Timer?
    private var isRefreshingBattery = false {
        didSet {
            updateMenu()
        }
    }
    private var batteryStatus = LogiBatteryStatus.loading {
        didSet {
            updateStatusItem()
            updateMenu()
        }
    }
    private var isKeepingDisplayAwake = false {
        didSet {
            updateStatusItem()
            updateMenu()
        }
    }
    private var isPreventingSystemSleep = false {
        didSet {
            updateStatusItem()
            updateMenu()
        }
    }

    private let menu = NSMenu()
    private let powerStatusItem = NSMenuItem()
    private let refreshBatteryItem = NSMenuItem()
    private let displayAwakeItem = NSMenuItem()
    private let systemAwakeItem = NSMenuItem()
    private let launchAtLoginItem = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        applySavedPowerSettings()
        refreshBattery()
        scheduleBatteryRefreshTimer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        batteryTimer?.invalidate()
        releaseDisplayAwakeAssertion(persist: false)
        releaseSystemSleepAssertion(persist: false)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        updateStatusItem()
    }

    private func configureMenu() {
        menu.delegate = self

        powerStatusItem.isEnabled = false
        menu.addItem(powerStatusItem)

        refreshBatteryItem.target = self
        refreshBatteryItem.action = #selector(refreshBatteryFromMenu)
        menu.addItem(refreshBatteryItem)

        menu.addItem(.separator())

        displayAwakeItem.target = self
        displayAwakeItem.action = #selector(toggleDisplayAwakeFromMenu)
        menu.addItem(displayAwakeItem)

        systemAwakeItem.target = self
        systemAwakeItem.action = #selector(toggleSystemAwakeFromMenu)
        menu.addItem(systemAwakeItem)

        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(.separator())
        menu.addItem(launchAtLoginItem)

        let quitItem = NSMenuItem(title: "退出 Keep Awake", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenu()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = makeDisplayBatteryImage(
            percent: batteryStatus.percent,
            keepsDisplayAwake: isKeepingDisplayAwake,
            preventsSystemSleep: isPreventingSystemSleep
        )
        button.title = ""
        button.toolTip = "\(batteryStatus.tooltipTitle) - \(powerSummaryTitle)"
    }

    private func updateMenu() {
        powerStatusItem.title = "电源状态：\(powerSummaryTitle)"

        refreshBatteryItem.title = isRefreshingBattery ? "正在刷新电池电量..." : "刷新电池电量"
        refreshBatteryItem.isEnabled = !isRefreshingBattery

        displayAwakeItem.title = "保持屏幕亮起"
        displayAwakeItem.state = isKeepingDisplayAwake ? .on : .off

        systemAwakeItem.title = "防止电脑自动睡眠（屏幕可熄灭）"
        systemAwakeItem.state = isPreventingSystemSleep ? .on : .off

        updateLaunchAtLoginMenuItem()
    }

    private var powerSummaryTitle: String {
        switch (isKeepingDisplayAwake, isPreventingSystemSleep) {
        case (true, true):
            return "屏幕保持亮起，电脑不自动睡眠"
        case (true, false):
            return "屏幕保持亮起"
        case (false, true):
            return "电脑不自动睡眠，屏幕可熄灭"
        case (false, false):
            return "未启用防睡眠"
        }
    }

    @objc private func toggleDisplayAwakeFromMenu() {
        setDisplayAwake(!isKeepingDisplayAwake)
    }

    @objc private func toggleSystemAwakeFromMenu() {
        if isPreventingSystemSleep, isKeepingDisplayAwake {
            setDisplayAwake(false)
            setSystemSleepPrevention(false)
        } else {
            setSystemSleepPrevention(!isPreventingSystemSleep)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try setLaunchAtLoginEnabled(!isLaunchAtLoginEnabled)
        } catch {
            showLaunchAtLoginError(error)
        }

        updateMenu()
    }

    @objc private func refreshBatteryFromMenu() {
        refreshBattery(resetTimer: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func scheduleBatteryRefreshTimer() {
        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: Self.batteryRefreshInterval, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
    }

    private func refreshBattery(resetTimer: Bool = false) {
        guard !isRefreshingBattery else { return }
        if resetTimer {
            scheduleBatteryRefreshTimer()
        }
        isRefreshingBattery = true
        batteryReader.read { [weak self] status in
            self?.batteryStatus = status
            self?.isRefreshingBattery = false
        }
    }

    private func applySavedPowerSettings() {
        let keepDisplayAwake = Self.savedKeepDisplayAwake()
        setDisplayAwake(keepDisplayAwake, persist: false)
        if !keepDisplayAwake {
            setSystemSleepPrevention(Self.savedPreventSystemSleep(), persist: false)
        }
    }

    private static func savedKeepDisplayAwake() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKey.keepDisplayAwake) != nil {
            return defaults.bool(forKey: DefaultsKey.keepDisplayAwake)
        }

        if defaults.string(forKey: DefaultsKey.legacyAwakeMode) == "allowDisplaySleep" {
            return false
        }

        return true
    }

    private static func savedPreventSystemSleep() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: DefaultsKey.preventSystemSleep) != nil {
            return defaults.bool(forKey: DefaultsKey.preventSystemSleep)
        }

        return defaults.string(forKey: DefaultsKey.legacyAwakeMode) == "allowDisplaySleep"
    }

    private func setDisplayAwake(_ enabled: Bool, persist: Bool = true) {
        if enabled {
            if createDisplayAwakeAssertion(persist: persist) {
                setSystemSleepPrevention(true, persist: persist)
            }
        } else {
            releaseDisplayAwakeAssertion(persist: persist)
        }
    }

    private func setSystemSleepPrevention(_ enabled: Bool, persist: Bool = true) {
        if enabled {
            createSystemSleepAssertion(persist: persist)
        } else {
            releaseSystemSleepAssertion(persist: persist)
        }
    }

    @discardableResult
    private func createDisplayAwakeAssertion(persist: Bool) -> Bool {
        guard displayAssertionID == 0 else {
            isKeepingDisplayAwake = true
            if persist {
                UserDefaults.standard.set(true, forKey: DefaultsKey.keepDisplayAwake)
            }
            return true
        }

        var newAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Keep Awake - Prevent display sleep" as CFString,
            &newAssertionID
        )

        if result == kIOReturnSuccess {
            displayAssertionID = newAssertionID
            isKeepingDisplayAwake = true
            if persist {
                UserDefaults.standard.set(true, forKey: DefaultsKey.keepDisplayAwake)
            }
            return true
        } else {
            isKeepingDisplayAwake = false
            if persist {
                UserDefaults.standard.set(false, forKey: DefaultsKey.keepDisplayAwake)
            }
            showAssertionError(result)
            return false
        }
    }

    private func releaseDisplayAwakeAssertion(persist: Bool) {
        if displayAssertionID != 0 {
            IOPMAssertionRelease(displayAssertionID)
            displayAssertionID = 0
        }
        isKeepingDisplayAwake = false
        if persist {
            UserDefaults.standard.set(false, forKey: DefaultsKey.keepDisplayAwake)
        }
    }

    private func createSystemSleepAssertion(persist: Bool) {
        guard systemAssertionID == 0 else {
            isPreventingSystemSleep = true
            if persist {
                UserDefaults.standard.set(true, forKey: DefaultsKey.preventSystemSleep)
            }
            return
        }

        var newAssertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Keep Awake - Prevent system sleep" as CFString,
            &newAssertionID
        )

        if result == kIOReturnSuccess {
            systemAssertionID = newAssertionID
            isPreventingSystemSleep = true
            if persist {
                UserDefaults.standard.set(true, forKey: DefaultsKey.preventSystemSleep)
            }
        } else {
            isPreventingSystemSleep = false
            if persist {
                UserDefaults.standard.set(false, forKey: DefaultsKey.preventSystemSleep)
            }
            showAssertionError(result)
        }
    }

    private func releaseSystemSleepAssertion(persist: Bool) {
        if systemAssertionID != 0 {
            IOPMAssertionRelease(systemAssertionID)
            systemAssertionID = 0
        }
        isPreventingSystemSleep = false
        if persist {
            UserDefaults.standard.set(false, forKey: DefaultsKey.preventSystemSleep)
        }
    }

    private func updateLaunchAtLoginMenuItem() {
        launchAtLoginItem.title = "开机自动启动"
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
        launchAtLoginItem.isEnabled = currentAppBundleURL != nil
    }

    private var isLaunchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.jesseyun.KeepAwake.login.plist")
    }

    private var currentAppBundleURL: URL? {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
        }

        var currentURL = Bundle.main.executableURL
        while let url = currentURL {
            if url.pathExtension == "app" {
                return url
            }
            currentURL = url.deletingLastPathComponent()
        }

        return nil
    }

    private func setLaunchAtLoginEnabled(_ enabled: Bool) throws {
        if enabled {
            try writeLaunchAgent()
        } else if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
        }
    }

    private func writeLaunchAgent() throws {
        guard let appBundleURL = currentAppBundleURL else {
            throw NSError(
                domain: "KeepAwake",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "请从 Keep Awake.app 启动后再开启。"]
            )
        }

        let launchAgentsDirectory = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": "com.jesseyun.KeepAwake.login",
            "ProgramArguments": ["/usr/bin/open", "-n", appBundleURL.path],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private func showAssertionError(_ result: IOReturn) {
        let alert = NSAlert()
        alert.messageText = "Keep Awake 无法启用。"
        alert.informativeText = "IOKit 返回错误代码 \(result)。"
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showLaunchAtLoginError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "无法修改开机自动启动。"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func makeDisplayBatteryImage(
        percent: Int?,
        keepsDisplayAwake: Bool,
        preventsSystemSleep: Bool
    ) -> NSImage {
        let size = NSSize(width: 30, height: 20)
        let image = NSImage(size: size, flipped: false) { _ in
            let primary = NSColor.labelColor
            let activeScreenColor = NSColor.white
            let inactive = primary.withAlphaComponent(0.62)
            let screenRect = NSRect(x: 2.0, y: 5.0, width: 26.0, height: 13.0)
            let standRect = NSRect(x: 13.3, y: 2.5, width: 3.4, height: 2.8)
            let baseRect = NSRect(x: 9.2, y: 1.0, width: 11.6, height: 1.8)
            let strokeColor = keepsDisplayAwake ? activeScreenColor : inactive
            let baseColor = primary.withAlphaComponent(preventsSystemSleep ? 1.0 : 0.38)

            if keepsDisplayAwake {
                activeScreenColor.setFill()
                NSBezierPath(roundedRect: screenRect.insetBy(dx: 1.0, dy: 1.0), xRadius: 2.0, yRadius: 2.0).fill()
            }

            strokeColor.setStroke()
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 2.7, yRadius: 2.7)
            screenPath.lineWidth = keepsDisplayAwake ? 1.65 : 1.25
            screenPath.stroke()

            baseColor.setFill()
            NSBezierPath(roundedRect: standRect, xRadius: 0.8, yRadius: 0.8).fill()
            NSBezierPath(roundedRect: baseRect, xRadius: 0.9, yRadius: 0.9).fill()

            if preventsSystemSleep {
                let indicatorRect = NSRect(x: 3.7, y: 2.0, width: 3.8, height: 2.0)
                NSBezierPath(roundedRect: indicatorRect, xRadius: 1.0, yRadius: 1.0).fill()
            }

            let percentText = percent.map { "\($0)" } ?? "?"
            let fontSize: CGFloat = percentText.count >= 3 ? 6.1 : 7.2
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
                .foregroundColor: primary
            ]
            let textSize = percentText.size(withAttributes: attributes)
            let textRect = NSRect(
                x: screenRect.midX - textSize.width / 2.0,
                y: screenRect.midY - textSize.height / 2.0 - 0.2,
                width: textSize.width,
                height: textSize.height
            )

            if keepsDisplayAwake, let context = NSGraphicsContext.current {
                context.saveGraphicsState()
                context.compositingOperation = .destinationOut
                percentText.draw(in: textRect, withAttributes: attributes)
                context.restoreGraphicsState()
            } else {
                percentText.draw(in: textRect, withAttributes: attributes)
            }

            return true
        }
        image.isTemplate = false
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
