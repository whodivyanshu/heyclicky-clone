import CoreGraphics
import XCTest
@testable import JarvisCore

final class ResponseParserTests: XCTestCase {
    private func parse(_ chunks: [String]) -> [Beat] {
        var parser = ResponseParser()
        return chunks.flatMap { parser.feed($0) } + parser.finish()
    }

    func testTagBeforeSentenceKeepsOrder() {
        XCTAssertEqual(parse(["[POINT:412,88:share button:screen2] Click Share."]), [
            .point(PointTag(x: 412, y: 88, label: "share button", screen: 2)),
            .say("Click Share."),
        ])
    }

    func testTagSplitAcrossEveryCharacter() {
        let text = "First this. [POINT:10,20:save] Then save. [POINT:30,40] Done."
        XCTAssertEqual(parse(text.map(String.init)), [
            .say("First this."),
            .point(PointTag(x: 10, y: 20, label: "save")),
            .say("Then save."),
            .point(PointTag(x: 30, y: 40)),
            .say("Done."),
        ])
    }

    func testScreenWithoutLabelIsNotTakenAsLabel() {
        XCTAssertEqual(parse(["[POINT:1,2:screen3]"]), [.point(PointTag(x: 1, y: 2, screen: 3))])
    }

    func testNoneTagIsDropped() {
        XCTAssertEqual(parse(["Nothing to show. [POINT:none]"]), [.say("Nothing to show.")])
    }

    func testOrdinaryBracketsAreSpoken() {
        XCTAssertEqual(parse(["See [section 2] now."]), [.say("See [section 2] now.")])
    }

    func testUnterminatedTagIsNotSpoken() {
        XCTAssertEqual(parse(["Look here. [POINT:12,3"]), [.say("Look here.")])
    }

    func testDecimalsDoNotSplitSentences() {
        XCTAssertEqual(parse(["Version 3.5 is out. Update."]), [.say("Version 3.5 is out."), .say("Update.")])
    }

    func testMarkdownIsRemovedFromSpeech() {
        XCTAssertEqual(parse(["Click **Save** now."]), [.say("Click Save now.")])
    }

    func testSpokenTextStripsTags() {
        XCTAssertEqual(ResponseParser.spokenText(of: "[POINT:1,2:x] Hi there."), "Hi there.")
    }
}

final class GuideTests: XCTestCase {
    private func parse(_ chunks: [String]) -> [Beat] {
        var parser = ResponseParser()
        return chunks.flatMap { parser.feed($0) } + parser.finish()
    }

    private let screen = ScreenMap(index: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 500), imageSize: CGSize(width: 2000, height: 1000))

    func testTargetTagSplitAcrossCharacters() {
        let text = "[TARGET:412,88,30:share button:screen2] Click Share."
        XCTAssertEqual(parse(text.map(String.init)), [
            .target(PointTag(x: 412, y: 88, label: "share button", screen: 2, radius: 30)),
            .say("Click Share."),
        ])
    }

    func testTargetWithoutRadiusIsNotATarget() {
        XCTAssertEqual(parse(["[TARGET:1,2] Hello."]), [.say("[TARGET:1,2] Hello.")])
    }

    func testUnterminatedTargetIsNotSpoken() {
        XCTAssertEqual(parse(["Next. [TARGET:1,2,"]), [.say("Next.")])
    }

    func testHitTestUsesScreenPointsAndTolerance() {
        var guide = GuideSession(task: "export")
        XCTAssertTrue(guide.setTarget(PointTag(x: 1000, y: 500, radius: 100)))
        // The center is (500, 250) in points, and radius 100px is 50pt, or 62.5pt with tolerance.
        XCTAssertTrue(guide.isHit(click: CGPoint(x: 560, y: 250), on: screen))
        XCTAssertFalse(guide.isHit(click: CGPoint(x: 570, y: 250), on: screen))
    }

    func testTinyTargetsStillHaveAClickableArea() {
        var guide = GuideSession(task: "export")
        XCTAssertTrue(guide.setTarget(PointTag(x: 1000, y: 500, radius: 1)))
        XCTAssertTrue(guide.isHit(click: CGPoint(x: 520, y: 250), on: screen))
    }

    func testOnlyFirstTargetOfATurnCounts() {
        var guide = GuideSession(task: "t")
        XCTAssertTrue(guide.setTarget(PointTag(x: 1, y: 1, label: "first", radius: 5)))
        XCTAssertFalse(guide.setTarget(PointTag(x: 2, y: 2, label: "second", radius: 5)))
        XCTAssertEqual(guide.completeCurrent(), "first")
    }

    func testStepLimitStopsTargetsAndChangesInstructions() {
        var guide = GuideSession(task: "t")
        for step in 0..<GuideSession.maxSteps {
            XCTAssertTrue(guide.setTarget(PointTag(x: 1, y: 1, label: "s\(step)", radius: 5)))
            XCTAssertTrue(guide.followUpGuidance().contains("t"))
            guide.completeCurrent()
        }
        XCTAssertFalse(guide.setTarget(PointTag(x: 1, y: 1, radius: 5)))
        XCTAssertTrue(guide.followUpGuidance().contains("Don't use a TARGET tag"))
    }

    func testFollowUpListsCompletedSteps() {
        var guide = GuideSession(task: "export my file")
        _ = guide.setTarget(PointTag(x: 1, y: 1, label: "file menu", radius: 5))
        guide.completeCurrent()
        let text = guide.followUpGuidance()
        XCTAssertTrue(text.contains("export my file"))
        XCTAssertTrue(text.contains("1. file menu"))
    }
}

final class ActionTests: XCTestCase {
    private func parse(_ chunks: [String]) -> [Beat] {
        var parser = ResponseParser()
        return chunks.flatMap { parser.feed($0) } + parser.finish()
    }

    private let apps = ["ChatGPT", "Claude", "Safari", "Google Chrome", "Calculator", "Notes", "Xcode", "Visual Studio Code"]

    func testActionTagSplitAcrossCharacters() {
        let text = "[OPEN_APP:ChatGPT] Opening ChatGPT."
        XCTAssertEqual(parse(text.map(String.init)), [
            .action(ActionTag(kind: .openApp, value: "ChatGPT")),
            .say("Opening ChatGPT."),
        ])
    }

    func testURLWithColonsAndLowercaseTag() {
        XCTAssertEqual(parse(["[open_url:https://example.com:8080/a?b=c]"]), [
            .action(ActionTag(kind: .openURL, value: "https://example.com:8080/a?b=c")),
        ])
    }

    func testUnterminatedActionIsNotSpoken() {
        XCTAssertEqual(parse(["Sure. [OPEN_APP:Chat"]), [.say("Sure.")])
    }

    func testSpokenTextLeavesOutActions() {
        XCTAssertEqual(ResponseParser.spokenText(of: "[QUIT_APP:Notes] Done."), "Done.")
    }

    func testMatchesHowPeopleAndSpeechSpellAppNames() {
        XCTAssertEqual(AppMatcher.best(for: "ChatGPT", among: apps), "ChatGPT")
        XCTAssertEqual(AppMatcher.best(for: "chat GPT", among: apps), "ChatGPT")
        XCTAssertEqual(AppMatcher.best(for: "chat-gpt", among: apps), "ChatGPT")
        XCTAssertEqual(AppMatcher.best(for: "ChatGPT desktop app", among: apps), "ChatGPT")
        XCTAssertEqual(AppMatcher.best(for: "chrome", among: apps), "Google Chrome")
        XCTAssertEqual(AppMatcher.best(for: "vs code", among: apps + ["VS Code"]), "VS Code")
    }

    func testAppNameInsideALongerWordDoesntMatch() {
        XCTAssertNil(AppMatcher.best(for: "Photoshop", among: ["Photos", "Notes"]))
        XCTAssertNil(AppMatcher.best(for: "photoshopzz", among: ["Photos"]))
        XCTAssertEqual(AppMatcher.best(for: "chat GPT please", among: ["ChatGPT", "Photos"]), "ChatGPT")
    }

    func testExactMatchBeatsLongerName() {
        XCTAssertEqual(AppMatcher.best(for: "Notes", among: ["Notes Pro", "Notes"]), "Notes")
    }

    func testUnknownOrTooShortNamesDontMatch() {
        XCTAssertNil(AppMatcher.best(for: "Photoshop", among: apps))
        XCTAssertNil(AppMatcher.best(for: "a", among: apps))
        XCTAssertNil(AppMatcher.best(for: "", among: apps))
    }

    func testOnlyWebAddressesAreAllowed() {
        XCTAssertEqual(ActionRules.webURL(from: "https://youtube.com/x")?.absoluteString, "https://youtube.com/x")
        XCTAssertEqual(ActionRules.webURL(from: "youtube.com")?.absoluteString, "https://youtube.com")
        XCTAssertNil(ActionRules.webURL(from: "file:///etc/passwd"))
        XCTAssertNil(ActionRules.webURL(from: "javascript:alert(1)"))
        XCTAssertNil(ActionRules.webURL(from: "vscode://open?x=1"))
        XCTAssertNil(ActionRules.webURL(from: "x-apple.systempreferences:foo.bar"))
        XCTAssertNil(ActionRules.webURL(from: "not a url"))
    }
}

final class GeminiVoiceTests: XCTestCase {
    func testRequestMatchesInteractionsFormat() throws {
        let data = try GeminiVoiceWire.requestBody(text: "Hello", voice: "Kore", model: "m")
        let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual((body["response_format"] as! [String: String])["type"], "audio")
        let config = body["generation_config"] as! [String: Any]
        XCTAssertEqual((config["speech_config"] as! [[String: String]])[0]["voice"], "Kore")
        let input = (body["input"] as! [[String: Any]])[0]
        XCTAssertEqual(input["type"] as? String, "user_input")
        XCTAssertEqual((input["content"] as! [[String: Any]])[0]["text"] as? String, "Hello")
    }

    func testAudioIsReadFromStreamDeltas() throws {
        // The shape recorded from the live API.
        let line = #"data: {"index":0,"delta":{"mime_type":"audio/l16","data":"AQIDBA==","channels":1,"sample_rate":24000,"type":"audio"},"event_type":"step.delta"}"#
        XCTAssertEqual(try GeminiVoiceWire.audio(fromSSELine: line), Data([1, 2, 3, 4]))
    }

    func testOtherStreamEventsCarryNoAudio() throws {
        XCTAssertNil(try GeminiVoiceWire.audio(fromSSELine: "event: step.delta"))
        XCTAssertNil(try GeminiVoiceWire.audio(fromSSELine: #"data: {"event_type":"step.start"}"#))
        XCTAssertNil(try GeminiVoiceWire.audio(fromSSELine: "data: [DONE]"))
    }

    func testStreamErrorThrows() {
        XCTAssertThrowsError(try GeminiVoiceWire.audio(fromSSELine: #"data: {"error":{"message":"Quota"}}"#)) {
            XCTAssertEqual($0 as? AIError, AIError("Gemini voice: Quota"))
        }
    }
}

final class GeometryTests: XCTestCase {
    func testImagePixelsMapToAppKitCoordinates() {
        let map = ScreenMap(index: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), imageSize: CGSize(width: 1568, height: 980))
        XCTAssertEqual(map.globalPoint(imageX: 0, imageY: 0), CGPoint(x: 0, y: 900))
        XCTAssertEqual(map.globalPoint(imageX: 1568, imageY: 980), CGPoint(x: 1440, y: 0))
        XCTAssertEqual(map.globalPoint(imageX: 784, imageY: 490), CGPoint(x: 720, y: 450))
    }

    func testSecondaryDisplayOffsetAndRoundTrip() {
        let map = ScreenMap(index: 2, frame: CGRect(x: -1920, y: 200, width: 1920, height: 1080), imageSize: CGSize(width: 1568, height: 882))
        let global = map.globalPoint(imageX: 100, imageY: 50)
        XCTAssertLessThan(global.x, 0)
        let back = map.imagePoint(global: global)
        XCTAssertEqual(back.x, 100, accuracy: 0.001)
        XCTAssertEqual(back.y, 50, accuracy: 0.001)
    }

    func testOutOfRangeCoordinatesStayOnScreen() {
        let map = ScreenMap(index: 1, frame: CGRect(x: 0, y: 0, width: 100, height: 100), imageSize: CGSize(width: 100, height: 100))
        XCTAssertEqual(map.globalPoint(imageX: 500, imageY: -20), CGPoint(x: 100, y: 100))
    }

    func testFittedKeepsAspectAndNeverUpscales() {
        XCTAssertEqual(Geometry.fitted(width: 3136, height: 1960, maxLongEdge: 1568).width, 1568)
        XCTAssertEqual(Geometry.fitted(width: 3136, height: 1960, maxLongEdge: 1568).height, 980)
        XCTAssertEqual(Geometry.fitted(width: 800, height: 600, maxLongEdge: 1568).width, 800)
    }

    func testArcStartsAndEndsOnTarget() {
        let start = CGPoint(x: 10, y: 10), end = CGPoint(x: 500, y: 300)
        XCTAssertEqual(Geometry.arcPoint(from: start, to: end, t: 0), start)
        XCTAssertEqual(Geometry.arcPoint(from: start, to: end, t: 1), end)
    }
}

final class WireFormatTests: XCTestCase {
    func testGeminiSSETextSkipsThoughts() throws {
        let line = #"data: {"candidates":[{"content":{"parts":[{"text":"hmm","thought":true},{"text":"Hello"}]}}]}"#
        XCTAssertEqual(try GeminiWire.text(fromSSELine: line), "Hello")
        XCTAssertNil(try GeminiWire.text(fromSSELine: ": keepalive"))
    }

    func testGeminiStreamErrorThrows() {
        let line = #"data: {"error":{"code":429,"message":"Quota exceeded"}}"#
        XCTAssertThrowsError(try GeminiWire.text(fromSSELine: line)) {
            XCTAssertEqual($0 as? AIError, AIError("Quota exceeded"))
        }
    }

    func testGeminiErrorBodyAsArray() {
        XCTAssertEqual(GeminiWire.errorMessage(fromBody: #"[{"error":{"message":"Bad key"}}]"#), "Bad key")
    }

    func testGeminiBodyHasImageHistoryAndSystem() throws {
        let request = AIRequest(system: "sys", history: [ChatTurn(user: "a", assistant: "b")], userText: "c", jpegImages: [Data([1, 2])])
        let body = try JSONSerialization.jsonObject(with: GeminiWire.requestBody(request)) as! [String: Any]
        let contents = body["contents"] as! [[String: Any]]
        XCTAssertEqual(contents.map { $0["role"] as! String }, ["user", "model", "user"])
        let parts = contents[2]["parts"] as! [[String: Any]]
        XCTAssertEqual((parts[0]["inlineData"] as! [String: String])["data"], "AQI=")
        XCTAssertEqual(parts[1]["text"] as? String, "c")
    }

    func testClaudeEventsIgnoreThinking() {
        let text = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"#
        let thinking = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"x"}}}"#
        XCTAssertEqual(ClaudeCodeWire.event(fromLine: text), .text("Hi"))
        XCTAssertNil(ClaudeCodeWire.event(fromLine: thinking))
    }

    func testClaudeResult() {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in"}"#
        XCTAssertEqual(ClaudeCodeWire.event(fromLine: line), .result(text: "Not logged in", isError: true))
    }

    func testClaudeInputCarriesHistoryAsText() throws {
        let request = AIRequest(system: "s", history: [ChatTurn(user: "u1", assistant: "a1")], userText: "now", jpegImages: [Data([1])])
        let object = try JSONSerialization.jsonObject(with: ClaudeCodeWire.inputLine(request)) as! [String: Any]
        let content = (object["message"] as! [String: Any])["content"] as! [[String: Any]]
        XCTAssertEqual(content[0]["type"] as? String, "image")
        XCTAssertTrue((content[1]["text"] as! String).contains("User: u1\nYou: a1"))
    }
}
