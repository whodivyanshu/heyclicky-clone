import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings()
    private var coordinator: Coordinator?
    private var island: IslandController?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let coordinator = Coordinator(settings: settings)
        coordinator.openSettings = { [weak self] in self?.showSettings() }
        coordinator.onModeChange = { [weak self] in self?.updateIcon($0) }
        coordinator.start()
        self.coordinator = coordinator

        let island = IslandController(model: coordinator.island, settings: settings)
        island.start()
        self.island = island

        setUpStatusItem()

        if CommandLine.arguments.contains("--demo") {
            coordinator.runDemo()
        } else if !UserDefaults.standard.bool(forKey: AppSettings.onboardedKey) || Self.needsSetup {
            UserDefaults.standard.set(true, forKey: AppSettings.onboardedKey)
            showSettings()
        }
    }

    /// Opening Jarvis again while it's already running brings up Settings, since it has no Dock icon or main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    private static var needsSetup: Bool {
        !Permissions.microphone || !Permissions.speech || !Permissions.screen
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsMenu), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Jarvis", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        updateIcon(.idle)
    }

    private func updateIcon(_ mode: CompanionMode) {
        let symbol: String
        switch mode {
        case .idle: symbol = "sparkle"
        case .listening: symbol = "mic.fill"
        case .thinking: symbol = "ellipsis.circle"
        case .speaking: symbol = "waveform"
        }
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Jarvis")
    }


    @objc private func openSettingsMenu() {
        showSettings()
    }

    private func showSettings() {
        if settingsWindow == nil {
            // Opens where setup is still needed, so a new install goes straight to permissions.
            let view = SettingsView(settings: settings, initialTab: Self.needsSetup ? .permissions : .general)
            let controller = NSHostingController(rootView: view)
            // The view runs under the transparent title bar, at exactly its own size.
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.title = "Jarvis"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.isReleasedWhenClosed = false
            window.setContentSize(SettingsView.size)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
