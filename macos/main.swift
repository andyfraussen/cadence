import AppKit
import Network
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let demo = CommandLine.arguments.contains("--demo")
    private lazy var model = AppModel(demo: demo)
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var timer: Timer?
    private var popoverMonitors: [Any] = []
    private let pathMonitor = NWPathMonitor()
    private var isOffline = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.delegate = self
        configurePopover()
        model.onDisplayChange = { [weak self] in self?.updateMenuBar() }
        updateMenuBar()
        model.refresh()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateMenuBar()
                // Offline pause: age the display without hammering the API.
                // Backoff for consecutive failures is enforced in refreshIfDue.
                if self.isOffline { return }
                self.model.refreshIfDue()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status != .satisfied
            Task { @MainActor in self?.isOffline = offline }
        }
        pathMonitor.start(queue: DispatchQueue(label: "dev.fraussen.cadence.net"))
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appResignedActive), name: NSApplication.didResignActiveNotification, object: nil)
        if CommandLine.arguments.contains("--settings") { showSettings() }
        if CommandLine.arguments.contains("--preview") {
            let window = NSWindow(contentViewController: NSHostingController(rootView: dashboard))
            window.title = demo ? "Cadence — demo" : "Cadence"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center(); window.makeKeyAndOrderFront(nil)
            previewWindow = window
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var dashboard: DashboardView {
        DashboardView(model: model, settings: { [weak self] in self?.showSettings() }, quit: { NSApp.terminate(nil) }, height: dashboardHeight)
    }

    private var dashboardHeight: CGFloat {
        let screen = item.button?.window?.screen ?? NSScreen.main
        // Leave room for the popover arrow and screen edges. Content scrolls within this bound.
        let cursorHeight: CGFloat = model.showCursor ? 430 + (model.showGrok ? 160 : 0) : 0
        let codexHeight: CGFloat = model.showCodex ? 300 + 180 * CGFloat(max(0, model.codex.count - 1)) : 0
        let preferred: CGFloat = max(300, 140 + cursorHeight + codexHeight)
        return min(preferred, max(220, (screen?.visibleFrame.height ?? 700) - 40))
    }

    private func configurePopover() {
        let size = NSSize(width: 390, height: dashboardHeight)
        guard popover.contentViewController == nil || popover.contentSize != size else { return }
        popover.contentViewController = NSHostingController(rootView: dashboard)
        popover.contentSize = size
    }

    private func updateMenuBar() {
        guard let button = item.button else { return }
        button.title = model.displayMode == .logo ? (model.hasProblem ? "!" : "") : model.toolbarTitle
        button.image = model.displayMode == .limits ? nil : CadenceBrand.menuBarIcon
        button.imagePosition = .imageLeading
        let status = model.hasProblem ? " — attention: click for details." : ". Click to open Cadence."
        button.toolTip = "\(model.toolbarTitle) remaining. C: Cursor Models, O: Other Models, G: Grok Bot, Cx: Codex\(status)"
        button.setAccessibilityLabel("Cadence")
        button.setAccessibilityValue(model.toolbarTitle + " remaining")
        configurePopover()
    }

    @objc private func togglePopover() {
        if popover.isShown { closePopover() }
        else if let button = item.button { showPopover(from: button) }
    }
    @objc private func woke() { updateMenuBar(); model.refresh() }
    @objc private func appResignedActive() { closePopover() }

    func applicationWillTerminate(_ notification: Notification) {
        stopPopoverMonitors()
        pathMonitor.cancel()
    }

    func popoverDidClose(_ notification: Notification) {
        stopPopoverMonitors()
    }

    private func showPopover(from button: NSStatusBarButton) {
        configurePopover()
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        startPopoverMonitors()
    }

    private func closePopover() {
        stopPopoverMonitors()
        if popover.isShown { popover.performClose(nil) }
    }

    private func startPopoverMonitors() {
        stopPopoverMonitors()
        // Backup for outside clicks AppKit doesn't route to the transient
        // popover (common for menu-bar extras): any click in another process
        // closes it. Clicks inside our popover never reach this monitor.
        popoverMonitors.append(
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in self?.closePopover() }
            } as Any
        )
    }

    private func stopPopoverMonitors() {
        for monitor in popoverMonitors { NSEvent.removeMonitor(monitor) }
        popoverMonitors.removeAll()
    }

    private func showSettings() {
        closePopover()
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.title = "Cadence Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
