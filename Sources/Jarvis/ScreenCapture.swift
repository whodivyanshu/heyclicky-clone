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

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
