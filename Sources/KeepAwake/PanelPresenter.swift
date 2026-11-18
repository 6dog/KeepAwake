import AppKit

/// Explicit dismissal avoids NSPopover.transient closing on the status-item mouse-down
/// before its mouse-up action has a chance to decide whether to toggle the panel.
final class PanelPresenter: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let diagnostics: Diagnostics
    private weak var anchor: NSButton?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var requestedAt: TimeInterval?
    private var eventAt: TimeInterval?
    private var operation = UUID().uuidString
    var isShown: Bool { popover.isShown }

    init(content: NSViewController, diagnostics: Diagnostics = .shared) {
        self.diagnostics = diagnostics
        super.init()
        popover.contentViewController = content
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        // Build/layout SwiftUI at startup, not on the first click.
        content.view.layoutSubtreeIfNeeded()
        _ = content.view.fittingSize
    }
    func toggle(anchor: NSButton, event: NSEvent?) {
        if isShown { close(reason: "status_item") }
        else { show(anchor: anchor, event: event, trigger: "status_item") }
    }
    func show(anchor: NSButton, event: NSEvent? = nil, trigger: String = "reopen") {
        guard !isShown else { return }
        guard anchor.window?.isVisible == true, !anchor.bounds.isEmpty else {
            diagnostics.record("interface", "panel_anchor_unavailable", level: "warning", fields: ["trigger": trigger])
            return
        }
        self.anchor = anchor
        requestedAt = ProcessInfo.processInfo.systemUptime
        eventAt = event?.timestamp
        operation = UUID().uuidString
        diagnostics.record("interface", "panel_requested", operation: operation, fields: ["trigger": trigger, "appActive": String(NSApp.isActive)])
        // No device queries, preference reads, file I/O or model synchronization on this path.
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        installDismissal()
    }
    func close(reason: String) {
        removeDismissal()
        guard isShown else { return }
        diagnostics.record("interface", "panel_close_requested", operation: operation, fields: ["reason": reason])
        popover.performClose(nil)
    }
    func popoverDidShow(_ notification: Notification) {
        anchor?.highlight(true)
        let now = ProcessInfo.processInfo.systemUptime
        var fields: [String: String] = [:]
        if let requestedAt { fields["showMilliseconds"] = String(Int(max(0, now - requestedAt) * 1000)) }
        if let eventAt, eventAt > 0 { fields["clickToShowMilliseconds"] = String(Int(max(0, now - eventAt) * 1000)) }
        diagnostics.record("interface", "panel_shown", operation: operation, fields: fields)
    }
    func popoverDidClose(_ notification: Notification) {
        anchor?.highlight(false)
        removeDismissal()
        diagnostics.record("interface", "panel_closed", operation: operation)
    }
    private func isAnchorClick(_ event: NSEvent) -> Bool {
        guard let anchor, let window = anchor.window else { return false }
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let point = event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
        return rect.contains(point)
    }
    private func installDismissal() {
        removeDismissal()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(reason: "escape"); return nil }
                return event
            }
            // Let the anchor's own action toggle it exactly once.
            if self.isAnchorClick(event) { return event }
            if event.window !== self.popover.contentViewController?.view.window { self.close(reason: "outside_local") }
            return event
        }
        // Mouse events do not require monitoring global keyboard input or new permissions.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, !self.isAnchorClick(event) else { return }
            self.close(reason: "outside_global")
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            self?.close(reason: "deactivated")
        }
    }
    private func removeDismissal() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver); self.resignObserver = nil }
    }
    deinit { removeDismissal() }
}
