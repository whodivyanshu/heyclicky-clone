import AppKit
import ImageIO
import JarvisCore
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CapturedScreen {
    let map: ScreenMap
    let jpeg: Data
}

enum ScreenCapture {
    /// Keeps images within the size vision models accept without resizing them again,
    /// so the coordinates the model returns match what it was shown.
    private static let maxLongEdge = 1568

    /// Captures every display, with the cursor's display first as screen 1. Jarvis's own windows are left out.
    @MainActor
    static func captureAll() async throws -> [CapturedScreen] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }

        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens.sorted { a, _ in a.frame.contains(mouse) }

        var captured: [CapturedScreen] = []
        for screen in screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  let display = content.displays.first(where: { $0.displayID == number.uint32Value })
            else { continue }

            let scale = screen.backingScaleFactor
            let size = Geometry.fitted(
                width: Int(screen.frame.width * scale),
                height: Int(screen.frame.height * scale),
                maxLongEdge: maxLongEdge
            )
            let configuration = SCStreamConfiguration()
            configuration.width = size.width
            configuration.height = size.height
            configuration.showsCursor = false

            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let jpeg = encodeJPEG(image) else { continue }

            captured.append(CapturedScreen(
                map: ScreenMap(
                    index: captured.count + 1,
                    frame: screen.frame,
                    imageSize: CGSize(width: image.width, height: image.height)
                ),
                jpeg: jpeg
            ))
        }
        guard !captured.isEmpty else { throw JarvisMessage("Couldn't capture the screen.") }
        return captured
    }

    /// A tiny grayscale copy of every display, for telling whether the screen is still changing.
    /// Nil without permission, or if it can't be captured.
    @MainActor
    static func thumbnail() async -> [UInt8]? {
        guard Permissions.screen,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        else { return nil }
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let width = 160, height = 100

        var pixels: [UInt8] = []
        for display in content.displays {
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.showsCursor = false
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            else { return nil }

            var gray = [UInt8](repeating: 0, count: width * height)
            let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(
                    data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { return nil }
            pixels += gray
        }
        return pixels
    }

    /// Waits for the result of an action to show, for at most `limit` seconds.
    /// `mustChangeFrom` is how the screen looked before opening something: a new window can take a while
    /// to appear, and until it does the old screen looks perfectly settled.
    @MainActor
    static func waitUntilSettled(mustChangeFrom before: [UInt8]? = nil, requiresChange: Bool = false, atLeast: TimeInterval, limit: TimeInterval) async throws {
        func nanoseconds(_ seconds: TimeInterval) -> UInt64 { UInt64(max(seconds, 0) * 1_000_000_000) }
        let start = Date()
        try await Task.sleep(nanoseconds: nanoseconds(atLeast))

        // Without a way to look, or a before picture to compare with, wait the full time.
        guard var previous = await thumbnail(), !requiresChange || before != nil else {
            try await Task.sleep(nanoseconds: nanoseconds(limit - Date().timeIntervalSince(start)))
            return
        }
        var changed = !requiresChange
        while Date().timeIntervalSince(start) < limit {
            try await Task.sleep(nanoseconds: nanoseconds(0.1))
            guard let current = await thumbnail() else { return }
            if let before, !ScreenRules.looksSame(current, before) { changed = true }
            if changed, ScreenRules.looksSame(current, previous) { return }
            previous = current
        }
    }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
