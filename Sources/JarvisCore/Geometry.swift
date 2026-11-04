import CoreGraphics
import Foundation

public enum ScreenRules {
    /// A pixel has to move this far to count, which ignores compression noise and soft fades.
    private static let pixelTolerance = 8
    /// A blinking text cursor or a clock changes a few pixels, and shouldn't count as the screen still changing.
    private static let allowedChangedShare = 0.005

    /// Compares two thumbnails of the same size.
    public static func looksSame(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var changed = 0
        for index in a.indices where abs(Int(a[index]) - Int(b[index])) > pixelTolerance {
            changed += 1
        }
        return Double(changed) <= Double(a.count) * allowedChangedShare
    }
}

/// Relates one captured screenshot to the display it came from.
/// `frame` is in AppKit global coordinates (origin bottom-left, y up, in points);
/// screenshot coordinates have their origin top-left, y down, in image pixels.
public struct ScreenMap: Equatable, Sendable {
    public var index: Int
    public var frame: CGRect
    public var imageSize: CGSize

    public init(index: Int, frame: CGRect, imageSize: CGSize) {
        self.index = index
        self.frame = frame
        self.imageSize = imageSize
    }

    public func globalPoint(imageX: Double, imageY: Double) -> CGPoint {
        let x = min(max(imageX, 0), imageSize.width) / imageSize.width
        let y = min(max(imageY, 0), imageSize.height) / imageSize.height
        return CGPoint(x: frame.minX + x * frame.width, y: frame.maxY - y * frame.height)
    }

    public func imagePoint(global: CGPoint) -> CGPoint {
        CGPoint(
            x: (global.x - frame.minX) / frame.width * imageSize.width,
            y: (frame.maxY - global.y) / frame.height * imageSize.height
        )
    }
}

public enum Geometry {
    /// Converts AppKit global coordinates to the ones mouse events use: origin at the top-left of the primary display, y down.
    public static func quartzPoint(appKit point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Scales a size down so its long edge is at most `maxLongEdge`, keeping aspect ratio.
    public static func fitted(width: Int, height: Int, maxLongEdge: Int) -> (width: Int, height: Int) {
        let longEdge = max(width, height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return (width, height) }
        let scale = Double(maxLongEdge) / Double(longEdge)
        return (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
    }

    public static func easeInOut(_ t: Double) -> Double {
        let t = min(max(t, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A point on an arc from `start` to `end`. Long flights bow out more, within a limit.
    public static func arcPoint(from start: CGPoint, to end: CGPoint, t: Double) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance > 0.001 else { return end }
        let bow = min(distance * 0.25, 160)
        // The perpendicular with positive y, so the arc rises in AppKit coordinates.
        let side: CGFloat = dx >= 0 ? 1 : -1
        let control = CGPoint(
            x: (start.x + end.x) / 2 - side * dy / distance * bow,
            y: (start.y + end.y) / 2 + side * dx / distance * bow
        )
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }
}
