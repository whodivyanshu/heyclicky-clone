import AppKit
import JarvisCore
import QuartzCore

enum CompanionMode {
    case idle, listening, thinking, speaking
}

/// The companion that follows the cursor and flies to what the AI points at.
/// It's drawn on one click-through panel per display, so it can cross between them.
@MainActor
final class OverlayController {
    var showWhenIdle: () -> Bool = { true }

    private enum Motion {
        case follow
        case flying(from: CGPoint, to: CGPoint, start: CFTimeInterval, duration: Double, label: String?, ringRadius: CGFloat?)
        case parked(CGPoint)
    }

    private static let ringRadiusRange: ClosedRange<CGFloat> = 18...120

    private var panels: [NSPanel] = []
    private var views: [CompanionView] = []
    private var timer: Timer?
    private var motion = Motion.follow
    private var position = NSEvent.mouseLocation
    private var velocity = CGVector.zero
    private var heading: CGFloat = 0
    private var lastTick = CACurrentMediaTime()
    private var mode = CompanionMode.idle
    private var level: CGFloat = 0
    private var caption: String?
    private var captionExpiry: CFTimeInterval?
    private var targetRing: (center: CGPoint, radius: CGFloat)?

    func start() {
        rebuildPanels()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setMode(_ mode: CompanionMode) {
        self.mode = mode
        views.forEach { $0.apply(mode: mode) }
    }

    func setLevel(_ level: Float) {
        self.level = CGFloat(level)
    }

    /// A nil `lasting` keeps the caption until it's replaced.
    func setCaption(_ text: String?, lasting: Double? = nil) {
        caption = text
        captionExpiry = lasting.map { CACurrentMediaTime() + $0 }
    }

    /// A `ringRadius` marks the spot as a click target for a guided step.
    /// Returns how long the flight takes, in seconds.
    @discardableResult
    func fly(to target: CGPoint, label: String?, ringRadius: CGFloat? = nil) -> Double {
        let distance = hypot(target.x - position.x, target.y - position.y)
        let duration = min(max(Double(distance) / 1300, 0.4), 1.0)
        velocity = .zero
        targetRing = nil
        setCaption(nil)
        motion = .flying(
            from: position,
            to: target,
            start: CACurrentMediaTime(),
            duration: duration,
            label: label,
            ringRadius: ringRadius
        )
        return duration
    }

    func returnToCursor() {
        motion = .follow
        heading = 0
        targetRing = nil
        setCaption(nil)
    }

    private func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        views = []
        for screen in NSScreen.screens {
            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.setFrame(screen.frame, display: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .screenSaver
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.sharingType = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let view = CompanionView(frame: NSRect(origin: .zero, size: screen.frame.size), scale: screen.backingScaleFactor)
            view.apply(mode: mode)
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now

        if let expiry = captionExpiry, now > expiry {
            caption = nil
            captionExpiry = nil
        }

        switch motion {
        case .follow:
            // A spring trailing just below and to the right of the real cursor.
            let mouse = NSEvent.mouseLocation
            let target = CGPoint(x: mouse.x + 16, y: mouse.y - 16)
            let stiffness = 260.0, damping = 30.0
            velocity.dx += ((target.x - position.x) * stiffness - velocity.dx * damping) * dt
            velocity.dy += ((target.y - position.y) * stiffness - velocity.dy * damping) * dt
            position.x += velocity.dx * dt
            position.y += velocity.dy * dt
            heading *= 0.85

        case .flying(let from, let to, let start, let duration, let label, let ringRadius):
            let t = Geometry.easeInOut((now - start) / duration)
            let next = Geometry.arcPoint(from: from, to: to, t: t)
            let dx = next.x - position.x, dy = next.y - position.y
            if hypot(dx, dy) > 0.5 {
                // The dart's resting direction is up-left (135 degrees).
                let wanted = atan2(dy, dx) - .pi * 0.75
                let difference = atan2(sin(wanted - heading), cos(wanted - heading))
                heading += difference * 0.25
            }
            position = next
            if now - start >= duration {
                position = to
                motion = .parked(to)
                setCaption(label)
                targetRing = ringRadius.map {
                    (to, min(max($0, Self.ringRadiusRange.lowerBound), Self.ringRadiusRange.upperBound))
                }
            }

        case .parked(let target):
            position = target
            heading *= 0.8
        }

        let visible = mode != .idle || showWhenIdle()
        for view in views {
            view.update(
                global: position,
                heading: heading,
                level: level,
                caption: caption,
                targetRing: targetRing,
                visible: visible,
                screenFrame: view.window?.frame ?? .zero
            )
        }
    }
}

private final class CompanionView: NSView {
    private let dart = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let targetLayer = CAShapeLayer()
    private var targetLayerRadius: CGFloat = 0
    private let bubble = CALayer()
    private let bubbleText = CATextLayer()
    private let scale: CGFloat
    private var shownCaption: String?

    private static let accent = NSColor(srgbRed: 1.0, green: 0.30, blue: 0.43, alpha: 1)
    private static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    private static let ringRadius: CGFloat = 21

    init(frame: NSRect, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()

        // The tip sits at the layer's origin, so positioning the layer positions the tip.
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 18, y: -7))
        path.addLine(to: CGPoint(x: 8, y: -9))
        path.addLine(to: CGPoint(x: 6, y: -19))
        path.closeSubpath()
        dart.path = path
        dart.fillColor = Self.accent.cgColor
        dart.strokeColor = Self.accent.cgColor
        dart.lineWidth = 2.5
        dart.lineJoin = .round
        dart.shadowColor = NSColor.black.cgColor
        dart.shadowOpacity = 0.3
        dart.shadowRadius = 3
        dart.shadowOffset = CGSize(width: 0, height: -1)
        dart.contentsScale = scale

        ring.bounds = CGRect(x: 0, y: 0, width: Self.ringRadius * 2, height: Self.ringRadius * 2)
        ring.path = CGPath(ellipseIn: ring.bounds, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = Self.accent.cgColor
        ring.lineWidth = 2.5
        ring.lineCap = .round
        ring.contentsScale = scale
        ring.isHidden = true

        targetLayer.fillColor = Self.accent.withAlphaComponent(0.12).cgColor
        targetLayer.strokeColor = Self.accent.cgColor
        targetLayer.lineWidth = 2.5
        targetLayer.contentsScale = scale
        targetLayer.isHidden = true
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.45
        breathe.duration = 0.7
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        targetLayer.add(breathe, forKey: "breathe")

        bubble.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
        bubble.cornerRadius = 10
        bubble.isHidden = true
        bubbleText.contentsScale = scale
        bubbleText.isWrapped = true
        bubble.addSublayer(bubbleText)

        layer?.addSublayer(targetLayer)
        layer?.addSublayer(ring)
        layer?.addSublayer(dart)
        layer?.addSublayer(bubble)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(mode: CompanionMode) {
        ring.removeAllAnimations()
        dart.removeAnimation(forKey: "pulse")
        ring.isHidden = mode != .listening && mode != .thinking
        switch mode {
        case .thinking:
            ring.lineDashPattern = [14, 12]
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * CGFloat.pi
            spin.duration = 1.1
            spin.repeatCount = .infinity
            ring.add(spin, forKey: "spin")
        case .speaking:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.6
            pulse.duration = 0.45
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            dart.add(pulse, forKey: "pulse")
        case .listening, .idle:
            ring.lineDashPattern = nil
        }
    }

    func update(
        global: CGPoint,
        heading: CGFloat,
        level: CGFloat,
        caption: String?,
        targetRing: (center: CGPoint, radius: CGFloat)?,
        visible: Bool,
        screenFrame: CGRect
    ) {
        let local = CGPoint(x: global.x - screenFrame.minX, y: global.y - screenFrame.minY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        targetLayer.isHidden = targetRing == nil
        if let targetRing {
            if targetRing.radius != targetLayerRadius {
                targetLayerRadius = targetRing.radius
                let box = CGRect(x: 0, y: 0, width: targetRing.radius * 2, height: targetRing.radius * 2)
                targetLayer.bounds = box
                targetLayer.path = CGPath(ellipseIn: box, transform: nil)
            }
            targetLayer.position = CGPoint(x: targetRing.center.x - screenFrame.minX, y: targetRing.center.y - screenFrame.minY)
        }

        dart.isHidden = !visible
        dart.position = local
        dart.setAffineTransform(CGAffineTransform(rotationAngle: heading))

        ring.position = CGPoint(x: local.x + 9, y: local.y - 10)
        if ring.animation(forKey: "spin") == nil {
            let growth = 1 + level * 0.45
            ring.setAffineTransform(CGAffineTransform(scaleX: growth, y: growth))
        }

        updateBubble(caption: visible ? caption : nil, anchor: local)
        CATransaction.commit()
    }

    private func updateBubble(caption: String?, anchor: CGPoint) {
        guard let caption, !caption.isEmpty else {
            bubble.isHidden = true
            shownCaption = nil
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: NSColor.white]
        let padding = CGSize(width: 11, height: 7)
        if caption != shownCaption {
            shownCaption = caption
            let text = NSAttributedString(string: caption, attributes: attributes)
            let measured = text.boundingRect(
                with: CGSize(width: 320, height: 200),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).size
            let size = CGSize(width: ceil(measured.width) + 2, height: ceil(measured.height) + 2)
            bubbleText.string = text
            bubbleText.frame = CGRect(x: padding.width, y: padding.height, width: size.width, height: size.height)
            bubble.bounds = CGRect(x: 0, y: 0, width: size.width + padding.width * 2, height: size.height + padding.height * 2)
        }
        bubble.isHidden = false

        // Below and to the right of the dart, flipped or clamped to stay on this display.
        let size = bubble.bounds.size
        var x = anchor.x + 26
        var y = anchor.y - 26 - size.height
        if x + size.width > bounds.width - 8 { x = anchor.x - size.width - 12 }
        if y < 8 { y = anchor.y + 16 }
        x = min(max(x, 8), max(8, bounds.width - size.width - 8))
        y = min(max(y, 8), max(8, bounds.height - size.height - 8))
        bubble.position = CGPoint(x: x + size.width / 2, y: y + size.height / 2)
    }
}
