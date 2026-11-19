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
    private let pollingInterval: TimeInterval
    private var changing = false
    private var work: DispatchWorkItem?
    private var retry: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var generation = 0
    private let failureRetryDelay: TimeInterval
    private let now: () -> TimeInterval
    private let diagnostics: Diagnostics
    private var operation = UUID().uuidString
    private var cachedScreens: [ManagedDisplay] = []
    private var quitting = false
    private var trigger = "startup"
    var isBusy: Bool { changing || recovering || verifyingDisable || quitting }
    var snapshot: [String: String] {
        ["automatic": String(automatic), "owned": String(owned), "status": status, "error": lastFailure ?? "", "retrySeconds": String(retrySeconds),
         "screens": cachedScreens.map { "id=\($0.id),builtin=\($0.builtIn),online=\($0.online),active=\($0.active),physical=\($0.physical),mirror=\($0.mirrors),main=\($0.main),origin=\($0.origin.x):\($0.origin.y)" }.joined(separator: ";")]
    }
    private var failureCount = 0
    private var recentClosures: [TimeInterval] = []
    private var retryAfter: TimeInterval?
    private var mustRecover = false
    private var verifyingDisable = false
    private(set) var lastFailure: String?
    private var recovering = false
    private var stopping = false
    private(set) var status = "内置屏幕：正在检测" {
        didSet {
            if oldValue != status {
                diagnostics.record("display", "state_changed", operation: operation, fields: ["before": oldValue, "after": status, "trigger": trigger])
            }
        }
    }
    private(set) var available = true
    var onChange: (() -> Void)?
    var automatic: Bool { defaults.bool(forKey: Key.automatic) }
    private var owned: Bool {
        get { defaults.bool(forKey: Key.owned) }
        set { defaults.set(newValue, forKey: Key.owned) }
    }

    init(backend: DisplayBackend = SkyLightDisplayBackend(), defaults: UserDefaults = .standard, delay: TimeInterval = 2, verificationDelay: TimeInterval = 0.6, restoreDelay: TimeInterval = 0.4, failureRetryDelay: TimeInterval = 5, pollingInterval: TimeInterval = 3, now: (() -> Date)? = nil, diagnostics: Diagnostics = .shared) {
        self.backend = backend
        self.defaults = defaults
        self.delay = delay
        self.verificationDelay = verificationDelay
        self.restoreDelay = restoreDelay
        self.failureRetryDelay = failureRetryDelay
        self.pollingInterval = pollingInterval
        self.now = now.map { clock in { clock().timeIntervalSinceReferenceDate } } ?? { ProcessInfo.processInfo.systemUptime }
        self.diagnostics = diagnostics
        // Remove the old hidden force-on override. Preserve its intent as manual auto-off.
        if defaults.bool(forKey: Key.forceOn) {
            defaults.set(false, forKey: Key.automatic)
            diagnostics.record("settings", "force_on_migrated_to_automatic_off")
        }
        defaults.removeObject(forKey: Key.forceOn)
    }

    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh(trigger: "display_change") })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh(trigger: name.rawValue) })
        }
        // Fallback if a hotplug notification is lost; also refreshes actual menu state.
        let pollTimer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in self?.refresh(trigger: "poll") }
        timer = pollTimer
        RunLoop.main.add(pollTimer, forMode: .common)
        if owned { restore(attempt: 0) } else { refresh() }
    }

    func setAutomatic(_ enabled: Bool) {
        guard !quitting else { return }
        operation = UUID().uuidString
        diagnostics.record("display", "requested", operation: operation, fields: ["automatic": String(enabled), "trigger": "user"])
        defaults.set(enabled, forKey: Key.automatic)
        resetFailures()
        recentClosures.removeAll()
        cancelPending()
        if !enabled && owned { restore(attempt: 0) } else { refresh() }
    }

    private func schedule(_ item: DispatchWorkItem, after interval: TimeInterval) {
        // NSApplication.terminate() may run a nested loop inside a main-queue handler.
        // Common-mode timers remain serviceable there; another main-queue block does not.
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            if !item.isCancelled { item.perform() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelPending() {
        generation += 1
        work?.cancel(); work = nil
        retry?.cancel(); retry = nil
        recovering = false
        verifyingDisable = false
    }

    private func resetFailures() {
        failureCount = 0
        retryAfter = nil
        lastFailure = nil
    }

    private var retrySeconds: Int {
        guard let retryAfter else { return 0 }
        return max(0, Int(ceil(retryAfter - now())))
    }

    private func recordFailure(_ error: Error) {
        failureCount += 1
        lastFailure = error.localizedDescription
        let interval = min(60, failureRetryDelay * pow(2, Double(min(failureCount - 1, 4))))
        retryAfter = now() + interval
        diagnostics.failure("display", "failed", error, operation: operation)
        diagnostics.record("display", "retry_scheduled", operation: operation, fields: ["seconds": String(interval), "failureCount": String(failureCount)])
    }

    func refresh(trigger: String = "refresh") {
        guard !stopping, !recovering, !changing, !quitting else { return }
        self.trigger = trigger
        do {
            let screens = try backend.displays()
            available = true
            if cachedScreens != screens {
                cachedScreens = screens
                diagnostics.record("display", "topology_changed", operation: operation, fields: snapshot)
            }
            diagnostics.record("display", "decision", level: "debug", operation: operation, fields: snapshot.merging(["trigger": trigger]) { _, new in new })
            let panel = screens.first(where: \.builtIn)
            let hasExternal = screens.contains(where: \.connectedExternal)
            if automatic && screens.contains(where: \.usableExternal) { preserveExternalMain() }
            let wantsRestore = !automatic || !hasExternal || mustRecover
            if wantsRestore && owned {
                work?.cancel(); work = nil
                verifyingDisable = false
                if retrySeconds > 0 && (hasExternal || panel?.online == true) {
                    status = "内置屏幕恢复待重试（\(retrySeconds) 秒后）"
                    onChange?()
                } else { restore(attempt: 0) }
                return
            }
            if verifyingDisable { return }
            if panel?.online == true {
                if automatic && screens.contains(where: \.usableExternal) {
                    if retrySeconds > 0 {
                        status = "内置屏幕已开启（\(retrySeconds) 秒后自动重试）"
                    } else {
                        status = "内置屏幕已开启（等待外接屏稳定）"
                        if work == nil {
                            let token = generation
                            let item = DispatchWorkItem { [weak self] in
                                guard let self, self.generation == token else { return }
                                self.work = nil
                                self.disableIfSafe()
                            }
                            work = item
                            schedule(item, after: delay)
                        }
                    }
                } else {
                    status = "内置屏幕已开启"
                }
            } else {
                status = panel == nil ? "未检测到内置屏幕（请保持开盖）" : "内置屏幕已关闭"
            }
            if !hasExternal || !automatic { work?.cancel(); work = nil }
            onChange?()
        } catch {
            work?.cancel(); work = nil
            if verifyingDisable { mustRecover = owned }
            verifyingDisable = false
            available = false
            if lastFailure != error.localizedDescription { recordFailure(error) }
            status = "屏幕控制不可用：\(error.localizedDescription)"
            onChange?()
        }
    }

    private func disableIfSafe() {
        guard !stopping, automatic, !mustRecover, retrySeconds == 0 else { return }
        do {
            let screens = try backend.displays()
            cachedScreens = screens
            guard screens.contains(where: \.usableExternal), let panel = screens.first(where: \.builtIn), panel.online else { refresh(); return }
            recentClosures = recentClosures.filter { now() - $0 < 15 }
            if recentClosures.count >= 3 {
                // Limit rapid WindowServer re-enable loops, without leaving automation paused forever.
                recordFailure(DisplayControlError(message: "系统短时间内反复重新启用内置屏幕"))
                recentClosures.removeAll()
                status = "内置屏幕已开启（\(retrySeconds) 秒后自动重试）"
                onChange?()
                return
            }
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
            let parentOperation = operation
            operation = UUID().uuidString
            diagnostics.record("display", "disable_started", operation: operation, fields: snapshot.merging(["parentOperation": parentOperation, "trigger": trigger]) { _, new in new })
            try backend.setBuiltInEnabled(false)
            verifyingDisable = true
            status = "内置屏幕：正在关闭"
            onChange?()
            verifyDisable(attempt: 0)
        } catch { failAndRecover(error) }
    }

    private func verifyDisable(attempt: Int) {
        let token = generation
        let verification = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, !self.stopping else { return }
            self.work = nil
            do {
                let screens = try self.backend.displays()
                self.cachedScreens = screens
                guard self.automatic, screens.contains(where: \.connectedExternal) else {
                    self.verifyingDisable = false
                    self.restore(attempt: 0)
                    return
                }
                if screens.first(where: \.builtIn)?.online == false {
                    self.verifyingDisable = false
                    self.resetFailures()
                    self.recentClosures.append(self.now())
                    self.diagnostics.record("display", "disable_verified", operation: self.operation, fields: self.snapshot)
                    self.refresh()
                } else if attempt < 4 {
                    // WindowServer may need several frames/transactions to finish reconfiguration.
                    // Poll the result; do not submit another disable transaction while it settles.
                    self.verifyDisable(attempt: attempt + 1)
                } else {
                    throw DisplayControlError(message: "系统尚未关闭内置屏幕")
                }
            } catch { self.failAndRecover(error) }
        }
        work = verification
        schedule(verification, after: verificationDelay)
    }

    private func failAndRecover(_ error: Error) {
        verifyingDisable = false
        recordFailure(error)
        mustRecover = owned
        status = "关闭失败，将自动重试：\(error.localizedDescription)"
        onChange?()
        if owned { restore(attempt: 0) }
    }

    private func restore(attempt: Int, completion: ((Bool) -> Void)? = nil) {
        generation += 1
        work?.cancel(); work = nil
        retry?.cancel(); retry = nil
        verifyingDisable = false
        recovering = true
        mustRecover = true
        status = "内置屏幕：正在恢复"
        onChange?()
        if attempt == 0 { diagnostics.record("display", "restore_started", operation: operation, fields: snapshot) }
        var failure: Error?
        do {
            try backend.setBuiltInEnabled(true)
            // Verify on a later main-loop turn: WindowServer changes are asynchronous.
        } catch { failure = error }
        let token = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, !self.stopping else { return }
            do {
                self.cachedScreens = try self.backend.displays()
                guard self.cachedScreens.first(where: \.builtIn)?.online == true else {
                    throw failure ?? DisplayControlError(message: "内置屏幕尚未恢复，请保持开盖")
                }
                try self.finishRestore()
                self.recovering = false
                self.retry = nil
                self.mustRecover = false
                self.status = "内置屏幕已开启"
                self.diagnostics.record("display", "restore_verified", operation: self.operation, fields: self.snapshot)
                self.onChange?()
                if let completion { completion(true) } else { self.refresh() }
            } catch {
                if attempt < 2 { self.restore(attempt: attempt + 1, completion: completion) }
                else {
                    self.recovering = false
                    self.recordFailure(error)
                    self.status = "恢复失败（\(self.retrySeconds) 秒后重试）：\(error.localizedDescription)"
                    self.onChange?()
                    completion?(false)
                    // Keep the recovery marker. A later hotplug/poll or restart can recover.
                }
            }
        }
        retry = item
        schedule(item, after: restoreDelay)
    }

    private func preserveExternalMain() {
        changing = true
        defer { changing = false }
        do { try backend.preserveExternalMain() }
        catch { diagnostics.failure("display", "external_main_failed", error, operation: operation) }
    }

    private func finishRestore() throws {
        if let relations = defaults.array(forKey: Key.mirrors) as? [[String]] {
            for pair in relations where pair.count == 2 { try backend.restoreMirror(pair[0], to: pair[1]) }
        }
        preserveExternalMain()
        owned = false
        defaults.removeObject(forKey: Key.mirrors)
    }

    /// Asynchronous: WindowServer can finish its configuration without blocking AppKit.
    func prepareToQuit(completion: @escaping (Bool) -> Void) {
        guard !quitting else { completion(false); return }
        cancelPending()
        quitting = true
        diagnostics.record("display", "quit_requested", operation: operation, fields: snapshot)
        guard owned else { stop(); completion(true); return }
        restore(attempt: 0) { [weak self] restored in
            guard let self else { completion(false); return }
            if restored { self.stop() }
            else {
                self.quitting = false
                self.status = "退出已取消，请先恢复内置屏幕"
                self.onChange?()
            }
            completion(restored)
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
