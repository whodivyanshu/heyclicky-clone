import AppKit
import JarvisCore

// Requests that take several rounds: full control and guided walkthroughs.
extension Coordinator {
    /// Sends looked-up data back to the model, so it can answer from it.
    func continueAfterLookup() -> Bool {
        let results = lookupResults
        lookupResults = []
        guard !results.isEmpty, actionFailure == nil, lookupRounds < Self.maxLookupRounds else { return false }
        lookupRounds += 1
        wantsNextStep = false
        let task = requestText
        var guidance = NativeRules.lookupGuidance(task: task, results: results)
        if let control { guidance += "\n" + control.followUpGuidance() }
        island.progress = settings.hindiAssistant ? "देख रहा हूँ…" : "Reading what I found…"
        setMode(.thinking)
        island.show(.thinking)
        turn = Task {
            do {
                try await exchange(transcript: task, guidance: guidance, historyEntry: task, continuesRequest: true, answeringLookup: true)
            } catch is CancellationError {
                // Interrupted: whatever interrupted the turn has already reset the state.
            } catch {
                if !Task.isCancelled { show(error) }
            }
        }
        return true
    }

    /// Starts the next step if the model asked for one. A failed action ends the request.
    func continueRequest() -> Bool {
        guard wantsNextStep, actionFailure == nil, var session = control else { return false }
        wantsNextStep = false
        didPoint = false
        overlay.returnToCursor()

        guard session.advance() else {
            control = nil
            speechOut.begin()
            speechOut.enqueue([.say("I've stopped after \(ControlSession.maxSteps) steps. Ask me again if there's more to do.")])
            island.reply = "I've stopped after \(ControlSession.maxSteps) steps. Ask me again if there's more to do."
            island.show(.speaking)
            speechOut.finishInput()
            return true
        }
        control = session
        let task = session.task
        let guidance = session.followUpGuidance()
        let opened = didOpenSomething
        let before = beforeOpening
        // A reply with nothing but NEXT is waiting for something to load, and that can look settled until it arrives.
        let ranSomething = ranScreenAction
        island.progress = ["Step \(session.step)", session.plan].compactMap { $0 }.joined(separator: ": ")
        setMode(.thinking)
        island.show(.thinking)
        turn = Task {
            do {
                if opened {
                    try await ScreenCapture.waitUntilSettled(
                        mustChangeFrom: before, requiresChange: true,
                        atLeast: Self.settleAfterOpening.minimum, limit: Self.settleAfterOpening.limit
                    )
                } else {
                    let settle = Self.settleAfterClick
                    try await ScreenCapture.waitUntilSettled(atLeast: ranSomething ? settle.minimum : settle.limit, limit: settle.limit)
                }
                clock.mark("waited for the screen")
                try await exchange(transcript: task, guidance: guidance, historyEntry: task, continuesRequest: true)
            } catch is CancellationError {
                // Interrupted: whatever interrupted the turn has already reset the state.
            } catch {
                if !Task.isCancelled { show(error) }
            }
        }
        return true
    }

    func target(_ tag: PointTag) {
        guard let screen = screen(for: tag), guide?.setTarget(tag) == true else {
            // No guide to attach to, or out of steps: still show the location.
            point(at: tag)
            return
        }
        didPoint = true
        let pointsPerPixel = screen.frame.width / screen.imageSize.width
        overlay.fly(
            to: screen.globalPoint(imageX: tag.x, imageY: tag.y),
            label: tag.label,
            ringRadius: CGFloat(tag.radius ?? 0) * pointsPerPixel
        )
        island.guideStep = (guide?.completed.count ?? 0) + 1
        island.show(.guiding)
        watchForClick()
    }

    /// Clicks go through to the app as usual. Jarvis only notices where they landed.
    func watchForClick() {
        stopWatchingForClick()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.clicked(at: NSEvent.mouseLocation) }
            }
        }
        guideTimeout = Task {
            try? await Task.sleep(nanoseconds: Self.guideWait)
            guard !Task.isCancelled else { return }
            finishGuideQuietly()
        }
    }

    func clicked(at location: CGPoint) {
        guard var session = guide, let tag = session.current, let screen = screen(for: tag) else { return }
        guard session.isHit(click: location, on: screen) else {
            // They've gone off to do something else, so step back without nagging.
            finishGuideQuietly()
            return
        }

        stopWatchingForClick()
        turn?.cancel()
        speechOut.stop()
        overlay.returnToCursor()
        didPoint = false

        let name = session.completeCurrent()
        conversationID = UUID()
        guide = session
        let task = session.task
        let guidance = session.followUpGuidance()
        setMode(.thinking)
        island.show(.thinking)

        turn = Task {
            do {
                try await ScreenCapture.waitUntilSettled(atLeast: Self.settleAfterClick.minimum, limit: Self.settleAfterClick.limit)
                try await exchange(transcript: task, guidance: guidance, historyEntry: "(clicked \(name))")
            } catch is CancellationError {
                // Interrupted: whatever interrupted the turn has already reset the state.
            } catch {
                if !Task.isCancelled { show(error) }
            }
        }
    }

    func finishGuideQuietly() {
        endGuide()
        didPoint = false
        overlay.returnToCursor()
        island.rest()
    }

    func endGuide() {
        guide = nil
        stopWatchingForClick()
    }

    func stopWatchingForClick() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        guideTimeout?.cancel()
        guideTimeout = nil
    }
}
