import AppKit
import os

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
    private let now: () -> Date
    private let logger = Logger(subsystem: "com.jesseyun.KeepAwake", category: "DisplayControl")
    private var failureCount = 0
    private var recentClosures: [Date] = []
    private var retryAfter: Date?
    private var mustRecover = false
    private var verifyingDisable = false
    private(set) var lastFailure: String?
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

    init(backend: DisplayBackend = SkyLightDisplayBackend(), defaults: UserDefaults = .standard, delay: TimeInterval = 2, verificationDelay: TimeInterval = 0.6, restoreDelay: TimeInterval = 0.4, failureRetryDelay: TimeInterval = 5, pollingInterval: TimeInterval = 3, now: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.defaults = defaults
        self.delay = delay
        self.verificationDelay = verificationDelay
        self.restoreDelay = restoreDelay
        self.failureRetryDelay = failureRetryDelay
        self.pollingInterval = pollingInterval
        self.now = now
    }

    func start() {
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.refresh() })
        }
        // Fallback if a hotplug notification is lost; also refreshes actual menu state.
        let pollTimer = Timer(timeInterval: pollingInterval, repeats: true) { [weak self] _ in self?.refresh() }
        timer = pollTimer
        RunLoop.main.add(pollTimer, forMode: .common)
        if owned { restore(attempt: 0) } else { refresh() }
    }

    func setAutomatic(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.automatic)
        resetFailures()
        recentClosures.removeAll()
        cancelPending()
        if !enabled && owned { restore(attempt: 0) } else { refresh() }
    }

    func setForceOn(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.forceOn)
        resetFailures()
        recentClosures.removeAll()
        cancelPending()
        if enabled { restore(attempt: 0) } else { refresh() }
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
        return max(0, Int(ceil(retryAfter.timeIntervalSince(now()))))
    }

    private func recordFailure(_ error: Error) {
        failureCount += 1
        lastFailure = error.localizedDescription
        let interval = min(60, failureRetryDelay * pow(2, Double(min(failureCount - 1, 4))))
        retryAfter = now().addingTimeInterval(interval)
        logger.error("Screen control failed; retry in \(interval, privacy: .public)s: \(error.localizedDescription, privacy: .public)")
    }

    func refresh() {
        guard !stopping, !recovering, !changing else { return }
        do {
            let screens = try backend.displays()
            available = true
            let panel = screens.first(where: \.builtIn)
            let hasExternal = screens.contains(where: \.usableExternal)
            let wantsRestore = forceOn || !automatic || !hasExternal || mustRecover
            if wantsRestore && (owned || (forceOn && panel?.online == false)) {
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
                if automatic && !forceOn && hasExternal {
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
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
                        }
                    }
                } else {
                    status = forceOn ? "内置屏幕已开启（保持开启）" : "内置屏幕已开启"
                }
            } else {
                status = panel == nil ? "未检测到内置屏幕（请保持开盖）" : "内置屏幕已关闭"
            }
            if !hasExternal || forceOn || !automatic { work?.cancel(); work = nil }
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
        guard !stopping, automatic, !forceOn, !mustRecover, retrySeconds == 0 else { return }
        do {
            let screens = try backend.displays()
            guard screens.contains(where: \.usableExternal), let panel = screens.first(where: \.builtIn), panel.online else { refresh(); return }
            recentClosures = recentClosures.filter { now().timeIntervalSince($0) < 15 }
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
                guard self.automatic, !self.forceOn, screens.contains(where: \.usableExternal) else {
                    self.verifyingDisable = false
                    self.restore(attempt: 0)
                    return
                }
                if screens.first(where: \.builtIn)?.online == false {
                    self.verifyingDisable = false
                    self.resetFailures()
                    self.recentClosures.append(self.now())
                    self.logger.info("Built-in display disabled and verified")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + verificationDelay, execute: verification)
    }

    private func failAndRecover(_ error: Error) {
        verifyingDisable = false
        recordFailure(error)
        mustRecover = owned
        status = "关闭失败，将自动重试：\(error.localizedDescription)"
        onChange?()
        if owned { restore(attempt: 0) }
    }

    private func restore(attempt: Int) {
        generation += 1
        work?.cancel(); work = nil
        retry?.cancel(); retry = nil
        verifyingDisable = false
        recovering = true
        mustRecover = true
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
                self.mustRecover = false
                self.status = "内置屏幕已开启"
                self.logger.info("Built-in display restored and verified")
                self.onChange?()
                self.refresh()
            } catch {
                if attempt < 2 { self.restore(attempt: attempt + 1) }
                else {
                    self.recovering = false
                    self.recordFailure(error)
                    self.status = "恢复失败（\(self.retrySeconds) 秒后重试）：\(error.localizedDescription)"
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
            mustRecover = true
            recordFailure(error)
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
