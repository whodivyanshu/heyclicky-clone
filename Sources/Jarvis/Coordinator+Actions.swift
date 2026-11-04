import AppKit
import JarvisCore

// Carrying out what a reply asks for, and reporting how it went.
extension Coordinator {
    /// Returns what to say instead of the model's reply if the action failed.
    func act(_ tag: ActionTag) async -> String? {
        // After a failure the rest of the reply was planned for a screen that isn't there.
        guard allowsActions, actionFailure == nil, !abandonedReply else { return nil }
        // Looked-up data can come from anyone, so it can't lead to opening or typing anything without full control.
        if answeringLookup, control == nil, !tag.kind.isNative, tag.kind != .copy { return nil }
        if tag.kind.isNative { return await actNatively(tag) }
        switch tag.kind {
        case .addRoutine, .removeRoutine:
            return actOnRoutine(tag)
        case .plan:
            control?.setPlan(tag.value)
            return nil
        case .confirm:
            declaredConfirmation = tag.value
            return nil
        case .remember:
            guard isDirectRequest, let saved = settings.memory.add(tag.value) else { return nil }
            island.activity = "Remembered: \(saved)"
            return nil
        case .forget:
            guard isDirectRequest else { return nil }
            island.activity = settings.memory.forget(matching: tag.value).isEmpty ? "Nothing saved about that" : "Forgot that"
            return nil
        case .copy:
            island.activity = ActionRunner.progress(for: tag)
            return report(await ActionRunner.run(tag))
        default:
            break
        }

        if tag.kind.usesKeyboard {
            guard control != nil else {
                return report(ActionResult(summary: "Didn't type", failure: "I can't use your keyboard unless you turn on full control in Settings."))
            }
            guard !didOpenSomething else {
                return report(ActionResult(summary: "Didn't type", failure: "The new window may not have been ready, so I stopped before typing. Ask me again and I'll take a fresh look.", retryable: true))
            }
        } else {
            didOpenSomething = true
        }

        let needsYes: Bool
        var title = String(ActionRunner.progress(for: tag).dropLast())
        if tag.kind == .pressKey {
            let context = UIInspector.keyContext()
            needsYes = declaredConfirmation != nil || RiskRules.keyNeedsConfirmation(tag.value, context: context)
            title = "Press \(tag.value) in \(context.appName)"
        } else {
            needsYes = declaredConfirmation != nil
        }
        if needsYes {
            let app = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let approved = await askToConfirm(title)
            guard !Task.isCancelled else { return nil }
            guard approved else { return declined() }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app else { return screenChanged() }
        }

        didRunAction = true
        island.activity = ActionRunner.progress(for: tag)
        if control != nil, !tag.kind.usesKeyboard {
            beforeOpening = await ScreenCapture.thumbnail()
            guard !Task.isCancelled else { return nil }
        }
        let result = await ActionRunner.run(tag)
        clock.mark("ran \(tag.kind.rawValue)")
        if result.failure == nil, tag.kind == .typeText || tag.kind == .paste { lastTyped = tag.value }
        return report(result)
    }

    /// Uses an app's data directly. Their own new words can do this right away. A later step
    /// follows a screenshot or looked-up data, which anyone could have written, so it asks first.
    private func actNatively(_ tag: ActionTag) async -> String? {
        if !isDirectRequest {
            let approved = await askToConfirm(String(ActionRunner.progress(for: tag).dropLast()))
            guard !Task.isCancelled else { return nil }
            guard approved else { return declined() }
        }
        island.activity = ActionRunner.progress(for: tag)
        if tag.kind.changesScreen {
            didRunAction = true
            didOpenSomething = true
        }
        let result = tag.kind == .recall ? recallFromScreenMemory(tag.value) : await ActionRunner.run(tag)
        guard !Task.isCancelled else { return nil }
        clock.mark("ran \(tag.kind.rawValue)")
        if result.failure == nil, let data = result.data { lookupResults.append(data) }
        return report(result)
    }

    private func recallFromScreenMemory(_ query: String) -> ActionResult {
        guard settings.screenMemoryEnabled else {
            return ActionResult(summary: "Screen memory is off", failure: "Screen memory is turned off. You can turn it on in Settings.")
        }
        let format = DateFormatter()
        format.dateFormat = "EEE d MMM HH:mm"
        let lines = settings.screenMemory.search(query, limit: 10).map { hit in
            "- \(format.string(from: hit.date)) in \(hit.app): \(hit.snippet)"
        }
        return ActionResult(
            summary: "Searched your screen memory",
            data: lines.isEmpty ? "Nothing on screen matched \(query)." : "What was on screen:\n" + lines.joined(separator: "\n")
        )
    }

    /// Flies the pointer to the target so they can see what's about to happen, then clicks it.
    func click(_ tag: PointTag) async -> String? {
        // Walkthrough follow-ups have no new words from the user, so show the target and leave the click to them.
        guard allowsActions, !answeringLookup || control != nil else {
            point(at: tag)
            return nil
        }
        guard !unattended else {
            return report(ActionResult(summary: "Didn't click \(tag.label ?? "that")", failure: "A scheduled routine can't click anything, in case you're away."))
        }
        guard actionFailure == nil, !abandonedReply else { return nil }
        let tag = ControlMatcher.snap(tag, to: controls)
        guard !didRunAction, let screen = screen(for: tag) else {
            return report(ActionResult(
                summary: "Didn't click \(tag.label ?? "that")",
                failure: "The screen may have changed, so I didn't click. Ask me again and I'll take a fresh look.",
                retryable: true
            ))
        }
        didRunAction = true
        didPoint = true
        island.activity = "Clicking \(tag.label ?? "that")…"
        let location = screen.globalPoint(imageX: tag.x, imageY: tag.y)
        let flight = overlay.fly(to: location, label: tag.label)
        try? await Task.sleep(nanoseconds: UInt64(flight * 1_000_000_000))
        // Esc or the shortcut during the flight has to stop the click.
        guard !Task.isCancelled else { return nil }

        // What the app calls the control counts as much as what the model calls it.
        let quartz = Geometry.quartzPoint(appKit: location, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
        let labels = UIInspector.labels(at: quartz)
        let risky = RiskRules.riskyLabel(in: labels + [tag.label].compactMap { $0 })
        if risky != nil || declaredConfirmation != nil {
            let app = NSWorkspace.shared.frontmostApplication
            let name = risky ?? labels.first ?? tag.label ?? "that"
            let approved = await askToConfirm("Click \"\(name)\" in \(app?.localizedName ?? "this app")")
            guard !Task.isCancelled else { return nil }
            guard approved else { return declined() }
            // Whatever they approved has to still be what's under the pointer.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app?.processIdentifier,
                  UIInspector.labels(at: quartz) == labels
            else { return screenChanged() }
        }

        let result = await ActionRunner.click(at: location, label: tag.label)
        guard !Task.isCancelled else { return nil }
        return report(result)
    }

    func declined() -> String? {
        report(ActionResult(summary: "Left that to you", failure: settings.hindiAssistant ? "ठीक है, मैंने वह नहीं किया।" : "Okay, I didn't do that."))
    }

    func screenChanged() -> String? {
        report(ActionResult(summary: "Stopped", failure: "The screen changed while I was asking, so I didn't do it."))
    }

    func report(_ result: ActionResult) -> String? {
        if settings.keepActivityLog, !result.summary.isEmpty {
            settings.activity.add(request: requestText, summary: result.summary, failure: result.failure, screenshot: latestScreenshot)
        }
        // A failure is explained in the reply itself, so only success gets the checkmark line.
        island.activity = result.failure == nil ? result.summary : ""
        guard let failure = result.failure else {
            control?.record(result.summary)
            return nil
        }
        if result.retryable, var session = control, session.recordFailure(failure) {
            control = session
            abandonedReply = true
            wantsNextStep = true
            heldBeats = []
            return ""
        }
        actionFailure = failure
        island.reply = failure
        // The reply may already be in the history, and it shouldn't claim something happened that didn't.
        if isTurnRecorded, let last = history.last {
            history[history.count - 1] = ChatTurn(user: last.user, assistant: failure)
            island.conversation = history
        }
        return failure
    }

    func point(at tag: PointTag) {
        guard let screen = screen(for: tag) else { return }
        didPoint = true
        overlay.fly(to: screen.globalPoint(imageX: tag.x, imageY: tag.y), label: tag.label)
    }

    func screen(for tag: PointTag) -> ScreenMap? {
        let index = tag.screen ?? 1
        return screens.first { $0.index == index }
    }

    func speechFinished() {
        setMode(.idle)
        if guide?.current != nil {
            finishShortcut(with: island.reply)
            return
        }
        if continueAfterLookup() { return }
        if continueRequest() { return }
        finishShortcut(with: island.reply)
        guide = nil
        island.rest(after: Self.replyLinger)
        listenForFollowUp()
        guard didPoint else { return }
        didPoint = false
        // Leave the pointer on the target long enough to act on it.
        returnTask = Task {
            try? await Task.sleep(nanoseconds: Self.pointHoldAfterSpeech)
            guard !Task.isCancelled else { return }
            overlay.returnToCursor()
        }
    }
}
