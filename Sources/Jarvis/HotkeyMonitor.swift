import CoreGraphics
import Foundation

/// Watches for a held modifier combo and for Escape by polling key state.
/// Polling needs no Accessibility or Input Monitoring permission, and it can't block or read typed text.
@MainActor
final class HotkeyMonitor {
    var hotkey: () -> HotkeyChoice = { .controlOption }
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onEscape: () -> Void = {}

    private var timer: Timer?
    private var isHeld = false
    private var escapeWasDown = false
    private static let watched: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
    private static let escapeKeyCode: CGKeyCode = 53

    func start() {
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        let pressed = CGEventSource.flagsState(.combinedSessionState).intersection(Self.watched)
        let down = pressed == hotkey().flags
        if down != isHeld {
            isHeld = down
            if down { onPress() } else { onRelease() }
        }

        let escapeDown = CGEventSource.keyState(.combinedSessionState, key: Self.escapeKeyCode)
        if escapeDown && !escapeWasDown { onEscape() }
        escapeWasDown = escapeDown
    }
}
