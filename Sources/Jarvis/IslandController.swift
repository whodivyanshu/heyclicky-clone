import AppKit
import SwiftUI

/// A panel that can take typing without activating Jarvis or stealing focus from your current app.
private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Lets the island sit over the menu bar, where macOS would otherwise push a window down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Owns the island's window, follows the display you're on, and opens it on hover.
/// The window stays click-through everywhere except over the island itself.
@MainActor
final class IslandController {
    private static let panelSize = CGSize(width: 640, height: 520)
    private static let hoverOpenDelay: TimeInterval = 0.12
    private static let hoverCloseDelay: TimeInterval = 0.4

    private let model: IslandModel
    private let settings: AppSettings
    private var panel: IslandPanel?
    private var timer: Timer?
    private var currentScreen: NSScreen?
    private var hoverStarted: Date?
    private var leftAt: Date?

    init(model: IslandModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
    }

    func start() {
        let panel = IslandPanel(
            contentRect: CGRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: IslandView(model: model, settings: settings))
        panel.orderFrontRegardless()
        self.panel = panel

        place(on: NSScreen.main ?? NSScreen.screens[0])

        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func place(on screen: NSScreen) {
        currentScreen = screen
        let frame = screen.frame
        panel?.setFrame(
            CGRect(
                x: frame.midX - Self.panelSize.width / 2,
                y: frame.maxY - Self.panelSize.height,
                width: Self.panelSize.width,
                height: Self.panelSize.height
            ),
            display: true
        )

        let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
        let notchHeight = screen.safeAreaInsets.top
        model.hasHardwareNotch = notchHeight > 0
        model.topHeight = notchHeight > 0 ? notchHeight : (menuBarHeight > 0 ? menuBarHeight : 24)
        if notchHeight > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            model.notchWidth = frame.width - left.width - right.width
        } else {
            model.notchWidth = 0
        }
    }

    private func tick() {
        guard let panel, let screen = currentScreen else { return }
        let mouse = NSEvent.mouseLocation
        model.hotkeySymbols = settings.hotkey.symbols

        // The island follows you between displays, but never moves while it's in use.
        if model.phase == .resting, !model.isOpen, !screen.frame.contains(mouse),
           let next = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            place(on: next)
            return
        }

        let size = model.size
        let area = CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
        let isHidden = model.phase == .resting && !model.isOpen && !settings.showIslandWhenIdle && !model.isRecordingMeeting
        let isOver = !isHidden && area.contains(mouse)

        if panel.ignoresMouseEvents == isOver {
            panel.ignoresMouseEvents = !isOver
        }
        updateHover(isOver: isOver)
        releaseKeyboardIfClosed(panel)
    }

    private func updateHover(isOver: Bool) {
        let now = Date()
        if isOver {
            leftAt = nil
            guard !model.isOpen, model.phase == .resting else { return }
            let started = hoverStarted ?? now
            hoverStarted = started
            if now.timeIntervalSince(started) >= Self.hoverOpenDelay {
                model.isOpen = true
                hoverStarted = nil
            }
        } else {
            hoverStarted = nil
            guard model.isOpen else { return }
            let left = leftAt ?? now
            leftAt = left
            if now.timeIntervalSince(left) >= Self.hoverCloseDelay {
                model.isOpen = false
                leftAt = nil
            }
        }
    }

    /// Reordering hands keyboard focus back to whichever app you were using.
    private func releaseKeyboardIfClosed(_ panel: NSPanel) {
        guard !model.isOpen, panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }
}
