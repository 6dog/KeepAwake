import AppKit
import IOKit.pwr_mgt

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var assertionID = IOPMAssertionID(0)
    private var isKeepingAwake = false {
        didSet {
            updateStatusItem()
            updateMenu()
        }
    }

    private let menu = NSMenu()
    private let toggleItem = NSMenuItem()
    private let statusItemText = NSMenuItem()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        setKeepingAwake(true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseAssertion()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleFromStatusButton)
        updateStatusItem()
    }

    private func configureMenu() {
        statusItemText.isEnabled = false
        menu.addItem(statusItemText)
        menu.addItem(.separator())

        toggleItem.target = self
        toggleItem.action = #selector(toggleFromMenu)
        menu.addItem(toggleItem)

        let quitItem = NSMenuItem(title: "Quit Keep Awake", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        updateMenu()
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer", accessibilityDescription: "Keep Awake")
        button.title = isKeepingAwake ? " Awake" : ""
        button.toolTip = isKeepingAwake ? "Keep Awake is preventing sleep" : "Keep Awake is off"
    }

    private func updateMenu() {
        statusItemText.title = isKeepingAwake ? "Preventing sleep" : "Not preventing sleep"
        toggleItem.title = isKeepingAwake ? "Turn Off" : "Turn On"
    }

    @objc private func toggleFromStatusButton() {
        setKeepingAwake(!isKeepingAwake)
    }

    @objc private func toggleFromMenu() {
        setKeepingAwake(!isKeepingAwake)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func setKeepingAwake(_ enabled: Bool) {
        if enabled {
            createAssertion()
        } else {
            releaseAssertion()
        }
    }

    private func createAssertion() {
        guard !isKeepingAwake else { return }

        var newAssertionID = IOPMAssertionID(0)
        let reason = "Keep Awake is enabled" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &newAssertionID
        )

        if result == kIOReturnSuccess {
            assertionID = newAssertionID
            isKeepingAwake = true
        } else {
            showAssertionError(result)
        }
    }

    private func releaseAssertion() {
        guard isKeepingAwake else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = IOPMAssertionID(0)
        isKeepingAwake = false
    }

    private func showAssertionError(_ result: IOReturn) {
        let alert = NSAlert()
        alert.messageText = "Keep Awake could not prevent sleep."
        alert.informativeText = "IOKit returned error code \(result)."
        alert.alertStyle = .warning
        alert.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
