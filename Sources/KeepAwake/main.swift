import AppKit
import SwiftUI
import Darwin

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instance = InstanceLock()
    private let state = AppState()
    private let diagnostics = Diagnostics.shared
    private lazy var power = PowerController()
    private lazy var display = BuiltInDisplayController()
    private lazy var battery = LogiBatteryReader()
    private let login = LoginItemManager()
    private var item: NSStatusItem!
    private var panel: PanelPresenter!
    private var batteryTimer: Timer?
    private var summaryTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var started = false
    private var terminating = false
    private var terminationSignals: [DispatchSourceSignal] = []
    private var iconSignature: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do {
            guard try instance.acquire() else { exit(0) }
        } catch {
            let alert = NSAlert(); alert.messageText = "无法启动 Keep Awake"; alert.informativeText = Diagnostics.sanitize(error.localizedDescription)
            alert.runModal(); NSApp.terminate(nil); return
        }
        diagnostics.beginSession(); started = true
        for code in [SIGTERM, SIGINT] {
            signal(code, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self, !self.terminating else { return }
                self.diagnostics.record("lifecycle", "termination_signal", fields: ["signal": String(code)])
                NSApp.terminate(nil)
            }
            terminationSignals.append(source); source.resume()
        }
        state.choosePower = { [weak self] mode in
            guard let self else { return }
            self.power.apply(mode); self.synchronize()
        }
        state.chooseAutomatic = { [weak self] enabled in self?.display.setAutomatic(enabled); self?.synchronize() }
        state.refreshBattery = { [weak self] in self?.readBattery(trigger: "user") }
        state.quit = { [weak self] in self?.quit() }
        display.onChange = { [weak self] in self?.synchronize() }
        configurePanel()
        power.apply(PowerMode.saved(in: .standard, diagnostics: diagnostics), persist: false, trigger: "startup")
        display.start()
        synchronize()
        readBattery(trigger: "startup")
        let batteryPoll = Timer(timeInterval: 86400, repeats: true) { [weak self] _ in self?.readBattery(trigger: "timer") }
        batteryTimer = batteryPoll; RunLoop.main.add(batteryPoll, forMode: .common)
        let summary = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.synchronize(); self.diagnostics.record("application", "summary", fields: self.snapshot())
        }
        summaryTimer = summary; RunLoop.main.add(summary, forMode: .common)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.diagnostics.record("lifecycle", name.rawValue, fields: self.snapshot())
                self.synchronize()
            })
        }
    }
    private func configurePanel() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self; item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseDown])
        item.button?.imagePosition = .imageOnly
        let hosting = NSHostingController(rootView: ControlPanel(state: state))
        hosting.sizingOptions = [.preferredContentSize]
        panel = PanelPresenter(content: hosting, diagnostics: diagnostics)
    }
    @objc private func statusClicked() {
        if let button = item.button, !terminating {
            panel.toggle(anchor: button, event: NSApp.currentEvent)
        }
    }
    private func showPanel() {
        guard started, !terminating, let button = item?.button else { return }
        panel.show(anchor: button)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }
    private func synchronize() {
        func update<T: Equatable>(_ key: ReferenceWritableKeyPath<AppState, T>, _ value: T) {
            if state[keyPath: key] != value { state[keyPath: key] = value }
        }
        update(\.powerMode, power.mode); update(\.powerError, power.lastError)
        update(\.automatic, display.automatic); update(\.screenStatus, display.status)
        update(\.screenError, display.lastFailure); update(\.screenAvailable, display.available); update(\.screenBusy, display.isBusy)
        update(\.logError, diagnostics.error); update(\.detailed, diagnostics.isDetailed)
        let signature = "\(state.battery ?? -1):\(power.displayID != 0):\(power.systemID != 0)"
        if signature != iconSignature {
            iconSignature = signature
            item?.button?.image = StatusIcon.make(percent: state.battery, keepsDisplayAwake: power.displayID != 0, preventsSystemSleep: power.systemID != 0)
            item?.button?.toolTip = nil
            item?.button?.setAccessibilityLabel("Logitech 电量 \(state.battery.map { "\($0)%" } ?? "未知")，\(power.mode.title)")
        }
    }
    private func readBattery(trigger: String) {
        guard !state.refreshingBattery, !terminating else { return }
        diagnostics.record("battery", "refresh_trigger", fields: ["trigger": trigger])
        state.refreshingBattery = true
        battery.read { [weak self] result in
            guard let self else { return }
            self.state.refreshingBattery = false
            guard !self.terminating else { return }
            self.state.battery = result.percent
            self.state.batteryError = result.errorMessage.map(Diagnostics.sanitize)
            if result.percent != nil { self.state.batteryUpdated = Date() }
            self.synchronize()
        }
    }
    private func snapshot() -> [String: String] {
        var result = ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
                      "os": ProcessInfo.processInfo.operatingSystemVersionString,
                      "battery.percent": state.battery.map(String.init) ?? "unavailable",
                      "battery.lastUpdate": state.batteryUpdated.map { ISO8601DateFormatter().string(from: $0) } ?? "none",
                      "battery.error": state.batteryError ?? "", "login.exists": String(login.exists), "login.valid": String(login.matchesCurrentApp),
                      "diagnostics.detailed": String(diagnostics.isDetailed)]
        for (key, value) in power.snapshot { result["power.\(key)"] = value }
        for (key, value) in display.snapshot { result["display.\(key)"] = value }
        for (key, value) in PowerController.systemSummary() { result["systemAssertions.\(key)"] = value }
        return result
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard started else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true; state.quitting = true
        battery.cancel()
        diagnostics.record("lifecycle", "quit_requested", fields: snapshot())
        display.prepareToQuit { [weak self] success in
            guard let self else { return }
            if !success {
                self.terminating = false; self.state.quitting = false
                self.state.notice = "内置屏幕恢复失败，退出已取消。"
                self.synchronize(); NSApp.reply(toApplicationShouldTerminate: false)
            } else {
                self.power.apply(.system, persist: false, trigger: "exit")
                DispatchQueue.global(qos: .utility).async {
                    self.diagnostics.endSession()
                    RunLoop.main.perform(inModes: [.common]) { NSApp.reply(toApplicationShouldTerminate: true) }
                    CFRunLoopWakeUp(CFRunLoopGetMain())
                }
            }
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        batteryTimer?.invalidate(); summaryTimer?.invalidate()
        terminationSignals.forEach { $0.cancel() }
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
