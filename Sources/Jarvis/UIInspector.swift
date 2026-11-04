import AppKit
import Carbon.HIToolbox
import JarvisCore

/// Reads the frontmost app through Accessibility. It only reads, and every answer is empty without the permission.
/// Field contents aren't collected, apart from the selection they've made themselves.
enum UIInspector {
    /// A stuck app must not hang Jarvis.
    private static let messagingTimeout: Float = 0.25
    private static let walkBudget: TimeInterval = 0.6
    private static let maxVisited = 1500
    private static let maxControls = 120

    private static let controlRoles: [String: String] = [
        "AXButton": "button", "AXLink": "link", "AXTextField": "text field", "AXTextArea": "text area",
        "AXSearchField": "search field", "AXComboBox": "combo box", "AXCheckBox": "checkbox",
        "AXRadioButton": "radio button", "AXPopUpButton": "pop-up", "AXMenuButton": "menu button",
        "AXRow": "row", "AXCell": "cell",
    ]

    // MARK: - Reading attributes

    private static func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let text = value(element, name) as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let result = value(parent, name), CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = value(element, kAXPositionAttribute), let size = value(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func ownLabels(_ element: AXUIElement) -> [String] {
        [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { string(element, $0) }
    }

    /// Buttons and rows in web pages and chat lists usually keep their name in a piece of text inside them.
    private static func innerText(_ element: AXUIElement, depth: Int = 3) -> String? {
        guard depth > 0 else { return nil }
        for child in children(element).prefix(8) {
            if string(child, kAXRoleAttribute) == "AXStaticText", let text = string(child, kAXValueAttribute) { return text }
            if let text = innerText(child, depth: depth - 1) { return text }
        }
        return nil
    }

    private static func frontApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return app
    }

    private static func appElement(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return app
    }

    // MARK: - For the safety checks

    /// What the control under a point calls itself, in mouse-event coordinates.
    static func labels(at location: CGPoint) -> [String] {
        guard AXIsProcessTrusted() else { return [] }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, messagingTimeout)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(location.x), Float(location.y), &hit) == .success,
              var current = hit
        else { return [] }

        var labels: [String] = []
        for _ in 0..<4 {
            let role = string(current, kAXRoleAttribute) ?? ""
            if ["AXWindow", "AXApplication", "AXWebArea"].contains(role) { break }
            labels += ownLabels(current)
            if role == "AXStaticText", let text = string(current, kAXValueAttribute) { labels.append(text) }
            if controlRoles[role] != nil {
                if labels.isEmpty, let text = innerText(current) { labels.append(text) }
                break
            }
            guard let parent = element(current, kAXParentAttribute) else { break }
            current = parent
        }
        return labels
    }

    static func keyContext() -> KeyContext {
        guard AXIsProcessTrusted(), let app = frontApp() else {
            return KeyContext(appName: NSWorkspace.shared.frontmostApplication?.localizedName ?? "")
        }
        let root = appElement(pid: app.processIdentifier)
        var context = KeyContext(appName: app.localizedName ?? "")
        if let window = element(root, kAXFocusedWindowAttribute) {
            context.windowTitle = string(window, kAXTitleAttribute) ?? ""
            if let button = element(window, kAXDefaultButtonAttribute) {
                context.defaultButton = string(button, kAXTitleAttribute) ?? ""
            }
        }
        if let focused = element(root, kAXFocusedUIElementAttribute) {
            context.focusedRole = [kAXRoleAttribute, kAXSubroleAttribute].compactMap { string(focused, $0) }.joined(separator: " ")
            context.focusedLabel = (ownLabels(focused) + [string(focused, kAXPlaceholderValueAttribute)].compactMap { $0 }).joined(separator: " ")
            var parent = element(focused, kAXParentAttribute)
            for _ in 0..<6 {
                guard let current = parent, string(current, kAXRoleAttribute) != "AXWindow" else { break }
                context.surroundingLabels += ownLabels(current)
                parent = element(current, kAXParentAttribute)
            }
        }
        return context
    }

    // MARK: - For the model

    /// What they've selected in the frontmost app. Password fields are never read.
    static func selectedText() -> String? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), let app = frontApp() else { return nil }
        guard let focused = element(appElement(pid: app.processIdentifier), kAXFocusedUIElementAttribute),
              string(focused, kAXSubroleAttribute) != "AXSecureTextField"
        else { return nil }
        return ContextRules.limited(string(focused, kAXSelectedTextAttribute))
    }

    /// A control as the app reports it, before the screenshot it will be matched to exists.
    struct FoundControl: Sendable {
        let role: String
        let label: String
        let box: CGRect
    }

    /// Starts reading the labeled controls in the front window. Runs off the main thread, because a large
    /// window takes a moment to walk, so it can happen while the screenshot is being taken.
    static func startFindingControls() -> Task<[FoundControl], Never> {
        guard AXIsProcessTrusted(), let pid = frontApp()?.processIdentifier else { return Task { [] } }
        return Task.detached(priority: .userInitiated) { walk(pid: pid) }
    }

    /// Converts found controls to screenshot pixels, leaving out any that aren't on a captured screen.
    static func controls(_ found: [FoundControl], on screens: [ScreenMap], primaryHeight: CGFloat) -> [ScreenControl] {
        found.compactMap { control(role: $0.role, label: $0.label, box: $0.box, screens: screens, primaryHeight: primaryHeight) }
    }

    private static func walk(pid: pid_t) -> [FoundControl] {
        let root = appElement(pid: pid)
        // Electron apps such as VS Code and WhatsApp's desktop app only build their tree when asked.
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window = element(root, kAXFocusedWindowAttribute) ?? element(root, kAXMainWindowAttribute),
              let windowFrame = frame(window)
        else { return [] }

        let deadline = Date().addingTimeInterval(walkBudget)
        var stack = [window]
        var visited = 0
        var found: [FoundControl] = []
        while let current = stack.popLast(), visited < maxVisited, found.count < maxControls, Date() < deadline {
            visited += 1
            let box = frame(current)
            // Scrolled out of view.
            if let box, !box.isEmpty, !box.intersects(windowFrame) { continue }

            if let role = string(current, kAXRoleAttribute), let name = controlRoles[role], let box, !box.isEmpty,
               let label = ownLabels(current).first ?? string(current, kAXPlaceholderValueAttribute) ?? innerText(current) {
                found.append(FoundControl(role: name, label: label, box: box))
                // A labeled row's insides would only repeat it.
                if role == "AXRow" || role == "AXCell" || role == "AXButton" || role == "AXLink" { continue }
            }
            // Reversed, so the walk goes in reading order.
            stack.append(contentsOf: children(current).reversed())
        }
        return found
    }

    private static func control(role: String, label: String, box: CGRect, screens: [ScreenMap], primaryHeight: CGFloat) -> ScreenControl? {
        let center = CGPoint(x: box.midX, y: primaryHeight - box.midY)
        guard let screen = screens.first(where: { $0.frame.contains(center) }) else { return nil }
        let point = screen.imagePoint(global: center)
        let scale = screen.imageSize.width / screen.frame.width
        let control = ScreenControl(
            role: role, label: label, x: point.x, y: point.y,
            width: box.width * scale, height: box.height * scale, screen: screen.index
        )
        return control.label.isEmpty ? nil : control
    }
}
