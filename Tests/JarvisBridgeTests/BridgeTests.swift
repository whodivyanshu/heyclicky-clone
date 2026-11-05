import Foundation
import XCTest
@testable import JarvisBridge

final class BridgeTests: XCTestCase {
    /// Goes through the real C functions, as the Windows app does.
    private func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        let result = method.withCString { m in json.withCString { p in jarvis_call(m, p) } }
        defer { jarvis_free(result) }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(String(cString: result).utf8)) as? [String: Any])
    }

    private func ok(_ method: String, _ params: [String: Any] = [:]) throws -> Any? {
        let response = try call(method, params)
        XCTAssertNil(response["error"], "\(method): \(response["error"] ?? "")")
        return response["ok"] is NSNull ? nil : response["ok"]
    }

    func testBadCallsReportAnError() throws {
        XCTAssertNotNil(try call("no.such.method")["error"])
        XCTAssertNotNil(try call("text.typable")["error"])
        XCTAssertNotNil(try call("parser.feed", ["id": 999_999, "chunk": "x"])["error"])
        let result = "key.parse".withCString { m in "not json".withCString { p in jarvis_call(m, p) } }
        defer { jarvis_free(result) }
        XCTAssertTrue(String(cString: result).contains("error"))
    }

    func testParserStreamsAcrossSplitTags() throws {
        let id = try XCTUnwrap(try ok("parser.new") as? Int)
        let first = try XCTUnwrap(try ok("parser.feed", ["id": id, "chunk": "[POINT:10,20:sha"]) as? [[String: Any]])
        XCTAssertTrue(first.isEmpty)
        let second = try XCTUnwrap(try ok("parser.feed", ["id": id, "chunk": "re:screen2] Click it. "]) as? [[String: Any]])
        XCTAssertEqual(second.first?["type"] as? String, "point")
        let tag = try XCTUnwrap(second.first?["tag"] as? [String: Any])
        XCTAssertEqual(tag["label"] as? String, "share")
        XCTAssertEqual(tag["screen"] as? Int, 2)
        XCTAssertEqual(second.last?["text"] as? String, "Click it.")
        _ = try ok("parser.finish", ["id": id])
        XCTAssertNotNil(try call("parser.feed", ["id": id, "chunk": "x"])["error"], "A finished parser is gone")
    }

    func testDangerousWindowsKeysAreRefused() throws {
        for text in ["alt+f4", "ctrl+q", "cmd+q", "shift+delete", "ctrl+alt+delete", "win+r", "windows+l", "alt+space", "esc", "ctrl+backspace"] {
            XCTAssertNil(try ok("key.parse", ["text": text]), text)
        }
    }

    func testWindowsKeysReadCorrectly() throws {
        let copy = try XCTUnwrap(try ok("key.parse", ["text": "Ctrl+Shift+N"]) as? [String: Any])
        XCTAssertEqual(copy["key"] as? String, "n")
        XCTAssertEqual(copy["control"] as? Bool, true)
        XCTAssertEqual(copy["shift"] as? Bool, true)
        XCTAssertEqual(copy["alt"] as? Bool, false)
        let fromMac = try XCTUnwrap(try ok("key.parse", ["text": "cmd+t"]) as? [String: Any])
        XCTAssertEqual(fromMac["key"] as? String, "t")
        XCTAssertEqual(fromMac["control"] as? Bool, true)
    }

    func testRiskRulesUseWindowsKeys() throws {
        func needsYes(_ text: String, _ context: [String: Any]) throws -> Bool {
            try XCTUnwrap(try ok("risk.key", ["text": text, "context": context]) as? Bool)
        }
        XCTAssertTrue(try needsYes("return", ["appName": "WhatsApp"]))
        XCTAssertTrue(try needsYes("ctrl+return", ["appName": "Notepad"]))
        XCTAssertTrue(try needsYes("alt+s", ["appName": "Outlook"]))
        XCTAssertTrue(try needsYes("ctrl+d", ["appName": "File Explorer"]))
        XCTAssertFalse(try needsYes("ctrl+d", ["appName": "Chrome"]))
        XCTAssertTrue(try needsYes("delete", ["appName": "File Explorer", "focusedRole": "list"]))
        XCTAssertFalse(try needsYes("delete", ["appName": "Notepad", "focusedRole": "textarea"]))
    }

    func testProtectedWindowsApps() throws {
        func refuses(_ method: String, _ process: String, _ title: String = "") throws -> Bool {
            try XCTUnwrap(try ok(method, ["process": process, "title": title]) as? Bool)
        }
        XCTAssertTrue(try refuses("windows.refusesClick", "consent.exe"))
        XCTAssertTrue(try refuses("windows.refusesClick", "REGEDIT.EXE"))
        XCTAssertTrue(try refuses("windows.refusesClick", "ApplicationFrameHost.exe", "Settings"))
        XCTAssertFalse(try refuses("windows.refusesClick", "ApplicationFrameHost.exe", "Calculator"))
        XCTAssertFalse(try refuses("windows.refusesClick", "cmd.exe"))
        XCTAssertTrue(try refuses("windows.refusesKeyboard", "cmd.exe"))
        XCTAssertTrue(try refuses("windows.refusesKeyboard", "WindowsTerminal.exe"))
        XCTAssertTrue(try refuses("windows.refusesKeyboard", "explorer.exe", "Run"))
        XCTAssertFalse(try refuses("windows.refusesKeyboard", "explorer.exe", "Documents"))
        XCTAssertFalse(try refuses("windows.refusesKeyboard", "notepad.exe"))
    }

    func testTerminalPanesOnWindows() throws {
        let cmd = try ok("risk.terminalPane", ["context": ["focusedLabel": "cmd - project"]]) as? Bool
        XCTAssertEqual(cmd, true)
        let plain = try ok("risk.terminalPane", ["context": ["focusedLabel": "Message"]]) as? Bool
        XCTAssertEqual(plain, false)
    }

    func testWindowsPromptHasNoMacWords() throws {
        for control in [true, false] {
            let prompt = try XCTUnwrap(try ok("prompt.system", ["canControl": control, "native": true, "screenMemory": true]) as? String)
            XCTAssertNil(prompt.range(of: #"\bMac\b|Finder|\bDock\b|System Settings|cmd\+"#, options: .regularExpression), prompt)
            XCTAssertTrue(prompt.contains("File Explorer"))
        }
    }

    /// A second display to the left of and above the primary one has negative Windows coordinates.
    func testScreenPointsUseWindowsCoordinates() throws {
        let screen: [String: Any] = ["index": 2, "x": -1000, "y": -200, "width": 1000, "height": 800, "imageWidth": 500, "imageHeight": 400]
        let topLeft = try XCTUnwrap(try ok("screen.globalPoint", ["screen": screen, "x": 0, "y": 0]) as? [String: Double])
        XCTAssertEqual(topLeft["x"], -1000)
        XCTAssertEqual(topLeft["y"], -200)
        let bottomRight = try XCTUnwrap(try ok("screen.globalPoint", ["screen": screen, "x": 500, "y": 400]) as? [String: Double])
        XCTAssertEqual(bottomRight["x"], 0)
        XCTAssertEqual(bottomRight["y"], 600)
        let back = try XCTUnwrap(try ok("screen.imagePoint", ["screen": screen, "x": -500, "y": 200]) as? [String: Double])
        XCTAssertEqual(back["x"], 250)
        XCTAssertEqual(back["y"], 200)
    }

    func testWalkthroughHitsOnWindowsScreens() throws {
        let screen: [String: Any] = ["index": 1, "x": 0, "y": 0, "width": 1000, "height": 800, "imageWidth": 1000, "imageHeight": 800]
        let id = try XCTUnwrap(try ok("guide.new", ["task": "export"]) as? Int)
        defer { _ = try? ok("guide.free", ["id": id]) }
        XCTAssertEqual(try ok("guide.setTarget", ["id": id, "tag": ["x": 100, "y": 100, "radius": 30]]) as? Bool, true)
        XCTAssertEqual(try ok("guide.isHit", ["id": id, "screen": screen, "x": 110, "y": 105]) as? Bool, true)
        XCTAssertEqual(try ok("guide.isHit", ["id": id, "screen": screen, "x": 100, "y": 700]) as? Bool, false)
    }

    func testControlSessionKeepsItsState() throws {
        let id = try XCTUnwrap(try ok("session.new", ["task": "send it"]) as? Int)
        defer { _ = try? ok("session.free", ["id": id]) }
        _ = try ok("session.setPlan", ["id": id, "plan": "open > send"])
        _ = try ok("session.record", ["id": id, "summary": "Opened it"])
        let guidance = try XCTUnwrap(try ok("session.followUp", ["id": id]) as? String)
        XCTAssertTrue(guidance.contains("open > send"))
        XCTAssertTrue(guidance.contains("Opened it"))
    }

    func testClaudeArgumentsKeepToolsOff() throws {
        let arguments = try XCTUnwrap(try ok("claude.arguments", ["model": "haiku", "system": "hi"]) as? [String])
        let tools = try XCTUnwrap(arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(arguments[tools + 1], "")
    }

    func testRoutinesRoundTripAsJSON() throws {
        let added = try XCTUnwrap(try ok("routines.add", ["book": "", "text": "Focus|say focus mode|quit Slack"]) as? [String: Any])
        XCTAssertEqual(added["added"] as? Bool, true)
        let book = try XCTUnwrap(added["book"] as? String)
        XCTAssertEqual(try ok("routines.matching", ["book": book, "transcript": "hey Jarvis, focus mode"]) as? String, "quit Slack")
        XCTAssertNil(try ok("routines.matching", ["book": book, "transcript": "what is focus mode for"]))
        let list = try XCTUnwrap(try ok("routines.list", ["book": book]) as? [[String: Any]])
        XCTAssertEqual(list.first?["name"] as? String, "Focus")
        XCTAssertNotNil(try call("routines.list", ["book": "not json"])["error"], "A damaged file must not look like an empty one")
    }

    func testImagesPassThroughToProviders() throws {
        let image = Data([1, 2, 3]).base64EncodedString()
        let body = try XCTUnwrap(try ok("gemini.body", ["system": "s", "userText": "u", "images": [image]]) as? String)
        XCTAssertTrue(body.contains(image))
        XCTAssertNotNil(try call("gemini.body", ["system": "s", "userText": "u", "images": ["%%%"]])["error"])
    }
}
