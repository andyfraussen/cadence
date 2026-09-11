import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demo = CommandLine.arguments.contains("--demo")
    private lazy var model = AppModel(demo: demo)
    private var item: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        configurePopover()
        model.onDisplayChange = { [weak self] in self?.updateMenuBar() }
        updateMenuBar()
        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMenuBar(); self?.model.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
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
        return min(model.showGrok ? 730 : 570, max(220, (screen?.visibleFrame.height ?? 700) - 40))
    }

    private func configurePopover() {
        let size = NSSize(width: 390, height: dashboardHeight)
        guard popover.contentViewController == nil || popover.contentSize != size else { return }
        popover.contentViewController = NSHostingController(rootView: dashboard)
        popover.contentSize = size
    }

    private func updateMenuBar() {
        guard let button = item.button else { return }
        button.title = model.displayMode == "logo" ? (model.hasProblem ? "!" : "") : model.toolbarTitle
        button.image = model.displayMode == "limits" ? nil : CadenceBrand.menuBarIcon
        button.imagePosition = .imageLeading
        button.toolTip = "\(model.toolbarTitle) remaining. C: Cursor Models, O: Other Models, G: Grok Bot. Click to open Cadence."
        button.setAccessibilityLabel("Cadence")
        button.setAccessibilityValue(model.toolbarTitle + " remaining")
        configurePopover()
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = item.button {
            configurePopover()
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    @objc private func woke() { updateMenuBar(); model.refresh() }

    private func showSettings() {
        popover.performClose(nil)
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
