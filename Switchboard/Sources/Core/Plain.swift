import Foundation

/// The words the board uses: one plain state per session, details only on hover.
enum Plain {
    /// "Working, 3 min", "Waiting: needs permission", "Finished". Waiting and finished lines carry no time.
    static func state(_ line: Line, now: Date) -> String {
        let age = now.timeIntervalSince(line.since)
        func timed(_ word: String) -> String { age < 60 ? word : word + ", " + Transcript.duration(age) }
        switch line.state {
        case .working, .longStep: return timed("Working")
        case .waitingPermission: return "Waiting: needs permission"
        case .waitingTurn: return line.finishedTurn ? "Finished" : "Waiting: asked a question"
        case .blocked: return "Waiting: blocked"
        case .idle: return line.finishedTurn ? "Finished" : timed("Idle")
        case .done: return "Finished"
        case .failed: return "Failed"
        case .stopped: return "Stopped"
        case .exited: return "Exited"
        case .unknown: return "Unknown"
        }
    }

    /// Amber only for a session that waits for an answer.
    static func isWaiting(_ line: Line) -> Bool { line.state.isWaiting && !(line.state == .waitingTurn && line.finishedTurn) }

    /// The one thing the header says.
    static func header(waiting: Int, working: Int, total: Int) -> String {
        if waiting > 0 { return "\(waiting) waiting" }
        if total == 0 { return "No sessions" }
        if working == total { return "All working" }
        return working > 0 ? "\(working) working" : "All idle"
    }

    /// The hover line: branch, tool, model, CLI version.
    static func summary(_ line: Line) -> String {
        let parts: [String?] = [
            line.git.map { $0.branch + ($0.worktree ? " (worktree)" : "") },
            line.git != nil ? line.agent?.name : nil,
            line.tool.title, line.model, line.cliVersion.map { "CLI \($0)" },
        ]
        return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Everything the default row leaves out, for the tooltip: the hover line plus event count and line number.
    static func details(_ line: Line, number: Int) -> String {
        let events = line.activity.reduce(0, +)
        return [summary(line), "\(events) \(events == 1 ? "event" : "events")", number > 0 ? String(format: "No. %02d", number) : ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
