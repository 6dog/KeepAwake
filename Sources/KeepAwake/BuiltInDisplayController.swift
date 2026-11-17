import AppKit

final class BuiltInDisplayController {
    enum Key {
        static let automatic = "autoDisableBuiltInDisplay"
        static let forceOn = "keepBuiltInDisplayOn"
        static let owned = "builtInDisplayDisabledByApp"
        static let mirrors = "builtInDisplaySavedMirrors"
    }
    private let backend: DisplayBackend
    private let defaults: UserDefaults
    private let delay: TimeInterval
    private let verificationDelay: TimeInterval
    private let restoreDelay: TimeInterval
    private var changing = false
    private var work: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var generation = 0
    private var disableAttempts: [Date] = []
    private var paused = false
    private var recovering = false
    private var stopping = false
    private(set) var status = "内置屏幕：正在检测"
    private(set) var available = true
    var onChange: (() -> Void)?
    var automatic: Bool { defaults.bool(forKey: Key.automatic) }
    var forceOn: Bool { defaults.bool(forKey: Key.forceOn) }
    private var owned: Bool {
        get { defaults.bool(forKey: Key.owned) }
        set { defaults.set(newValue, forKey: Key.owned) }
    }

    init(backend: DisplayBackend = SkyLightDisplayBackend(), defaults: UserDefaults = .standard, delay: TimeInterval = 2, verificationDelay: TimeInterval = 0.6, restoreDelay: TimeInterval = 0.4) {
        self.backend = backend
        self.defaults = defaults
        self.delay = delay
        self.verificationDelay = verificationDelay
        self.restoreDelay = restoreDelay
    }

    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        // Fallback if a hotplug notification is lost; also refreshes actual menu state.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        if owned { restore(attempt: 0, resumeAutomation: true) } else { refresh() }
    }

    func setAutomatic(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.automatic)
        paused = false
        disableAttempts.removeAll()
        cancelPending()
        if !enabled && owned { restore(attempt: 0) } else { refresh() }
    }

    func setForceOn(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.forceOn)
        paused = false
        disableAttempts.removeAll()
        cancelPending()
        if enabled { restore(attempt: 0) } else { refresh() }
    }

    private func cancelPending() {
        generation += 1
        work?.cancel(); work = nil
        retry?.cancel(); retry = nil
        recovering = false
    }

    func refresh() {
        guard !stopping, !recovering, !changing else { return }
        do {
            let screens = try backend.displays()
            available = true
            let panel = screens.first(where: \.builtIn)
            let hasExternal = screens.contains(where: \.usableExternal)
            if ((forceOn || !automatic || !hasExternal || paused) && owned) || (forceOn && panel?.online == false) {
                work?.cancel(); work = nil
                restore(attempt: 0)
                return
            }
            if panel?.online == true {
                status = paused ? "内置屏幕已开启（自动控制已暂停）" : "内置屏幕已开启"
                if automatic && !forceOn && hasExternal && !paused && work == nil {
                    let token = generation
                    let item = DispatchWorkItem { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.work = nil
                        self.disableIfSafe()
                    }
                    work = item
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                }
            } else {
                status = panel == nil ? "未检测到内置屏幕（请保持开盖）" : "内置屏幕已关闭"
            }
            if !hasExternal || forceOn || !automatic || paused { work?.cancel(); work = nil }
            onChange?()
        } catch {
            work?.cancel(); work = nil
            available = false
            status = "屏幕控制不可用：\(error.localizedDescription)"
            onChange?()
        }
    }

    private func disableIfSafe() {
        guard !stopping, automatic, !forceOn, !paused else { return }
        do {
            let screens = try backend.displays()
            guard screens.contains(where: \.usableExternal), let panel = screens.first(where: \.builtIn), panel.online else { refresh(); return }
            disableAttempts = disableAttempts.filter { Date().timeIntervalSince($0) < 60 }
            guard disableAttempts.count < 3 else {
                paused = true
                status = "自动控制已暂停：屏幕反复恢复，请重新开关自动功能"
                onChange?()
                return
            }
            disableAttempts.append(Date())
            if !owned {
                let relations = screens.compactMap { display -> [String]? in
                    guard display.id == panel.id || display.mirrors == panel.id,
                          let target = screens.first(where: { $0.id == display.mirrors }) else { return nil }
                    return [display.identity, target.identity]
                }
                defaults.set(relations, forKey: Key.mirrors)
            }
            // Persist before committing so a crash immediately after disconnect is recoverable.
            owned = true
            changing = true
            defer { changing = false }
            try backend.setBuiltInEnabled(false)
            let token = generation
            let verification = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token else { return }
                self.work = nil
                do {
                    if try self.backend.displays().first(where: \.builtIn)?.online != false {
                        throw DisplayControlError(message: "内置屏幕未关闭，自动控制已暂停")
                    }
                    self.refresh()
                } catch { self.failAndRecover(error) }
            }
            work = verification
            status = "内置屏幕：正在关闭"
            onChange?()
            DispatchQueue.main.asyncAfter(deadline: .now() + verificationDelay, execute: verification)
        } catch { failAndRecover(error) }
    }

    private func failAndRecover(_ error: Error) {
        paused = true
        status = "屏幕操作失败：\(error.localizedDescription)"
        onChange?()
        if owned { restore(attempt: 0) }
    }

    private func restore(attempt: Int, resumeAutomation: Bool = false) {
        work?.cancel(); work = nil
        recovering = true
        status = "内置屏幕：正在恢复"
        onChange?()
        var failure: Error?
        do {
            try backend.setBuiltInEnabled(true)
            // Verify on a later main-loop turn: WindowServer changes are asynchronous.
        } catch { failure = error }
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, !self.stopping else { return }
            do {
                guard try self.backend.displays().first(where: \.builtIn)?.online == true else {
                    throw failure ?? DisplayControlError(message: "内置屏幕尚未恢复，请保持开盖")
                }
                try self.finishRestore()
                self.recovering = false
                self.retry = nil
                self.status = self.paused ? "内置屏幕已恢复（自动控制已暂停）" : "内置屏幕已开启"
                self.onChange?()
                if resumeAutomation { self.refresh() }
            } catch {
                if attempt < 2 { self.restore(attempt: attempt + 1, resumeAutomation: resumeAutomation) }
                else {
                    self.recovering = false
                    self.paused = true
                    self.status = "恢复失败：\(error.localizedDescription)；可重开上盖或拔插外接屏后重试"
                    self.onChange?()
                    // Keep the recovery marker. A later hotplug/poll or restart can recover.
                }
            }
        }
        retry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay, execute: item)
    }

    private func finishRestore() throws {
        if let relations = defaults.array(forKey: Key.mirrors) as? [[String]] {
            for pair in relations where pair.count == 2 { try backend.restoreMirror(pair[0], to: pair[1]) }
        }
        owned = false
        defaults.removeObject(forKey: Key.mirrors)
    }

    /// Quit is cancelled if recovery fails, leaving the menu available for another attempt.
    func prepareToQuit() -> Bool {
        cancelPending()
        guard owned else { stop(); return true }
        do {
            var lastError: Error = DisplayControlError(message: "内置屏幕未恢复")
            for _ in 0..<3 {
                do {
                    try backend.setBuiltInEnabled(true)
                    if try backend.displays().first(where: \.builtIn)?.online == true {
                        try finishRestore()
                        stop()
                        return true
                    }
                } catch { lastError = error }
                Thread.sleep(forTimeInterval: 0.2)
            }
            throw lastError
        } catch {
            paused = true
            status = "退出已取消：\(error.localizedDescription)，请先恢复内置屏幕"
            onChange?()
            return false
        }
    }

    func stop() {
        stopping = true
        cancelPending()
        timer?.invalidate(); timer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}
