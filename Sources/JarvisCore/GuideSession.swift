#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A click-by-click walkthrough: the AI targets one control, the user clicks it,
/// and the AI looks at a fresh screenshot to choose the next step.
public struct GuideSession: Equatable, Sendable {
    public static let maxSteps = 8
    /// Small targets are hard to hit exactly, and models place them slightly off.
    static let minimumHitRadius: CGFloat = 24
    static let hitTolerance: CGFloat = 1.25

    public let task: String
    public private(set) var completed: [String] = []
    public private(set) var current: PointTag?

    public init(task: String) {
        self.task = task
    }

    public var remainingSteps: Int { Self.maxSteps - completed.count }

    /// Accepts the first target of a turn, as long as steps remain.
    public mutating func setTarget(_ tag: PointTag) -> Bool {
        guard current == nil, remainingSteps > 0 else { return false }
        current = tag
        return true
    }

    /// Records the current target as done and returns its name.
    @discardableResult
    public mutating func completeCurrent() -> String {
        let name = current?.label ?? "the highlighted control"
        completed.append(name)
        current = nil
        return name
    }

    /// Whether a click lands on the current target, on the display it was captured from.
    public func isHit(click: CGPoint, on screen: ScreenMap) -> Bool {
        guard let current else { return false }
        let center = screen.globalPoint(imageX: current.x, imageY: current.y)
        let pointsPerPixel = screen.frame.width / screen.imageSize.width
        let radius = max(CGFloat(current.radius ?? 0) * pointsPerPixel * Self.hitTolerance, Self.minimumHitRadius)
        return hypot(click.x - center.x, click.y - center.y) <= radius
    }

    /// The instruction for the turn after a click, sent with a new screenshot.
    public func followUpGuidance() -> String {
        let done = completed.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        var lines = [
            "You are guiding them through this request: \(task)",
            "Steps they have clicked so far:\n\(done)",
            "The new screenshot shows what happened after the last click, so trust it over your earlier plan. "
                + "Don't repeat a finished step unless the screenshot shows it failed. "
                + "If a menu or panel has opened, your next target is inside it.",
        ]
        if remainingSteps > 0 {
            lines.append("If the request is done, say so in one short sentence with no tag. Otherwise give the next step: one TARGET tag followed by one short sentence.")
        } else {
            lines.append("This walkthrough has reached its step limit. Don't use a TARGET tag. Say in one or two short sentences what is left to do.")
        }
        return lines.joined(separator: "\n")
    }
}
