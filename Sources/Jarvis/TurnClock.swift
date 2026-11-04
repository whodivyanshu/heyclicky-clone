import Foundation
import os

/// Logs how long each stage of a request takes. It records stage names and times only, never what was said.
/// To watch it: log stream --predicate 'subsystem == "local.jarvis.companion" AND category == "timing"'
struct TurnClock {
    private static let log = Logger(subsystem: "local.jarvis.companion", category: "timing")
    private var start = Date()
    private var last = Date()

    mutating func restart() {
        start = Date()
        last = start
    }

    mutating func mark(_ stage: String) {
        let now = Date()
        let took = Int(now.timeIntervalSince(last) * 1000)
        let total = Int(now.timeIntervalSince(start) * 1000)
        last = now
        Self.log.notice("\(stage, privacy: .public): \(took)ms (total \(total)ms)")
    }
}
