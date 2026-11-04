import CoreGraphics
import Foundation

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
