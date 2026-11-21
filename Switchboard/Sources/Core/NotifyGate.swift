import Foundation

/// Which lines just started waiting, and at most one notification per line per 5 minutes.
struct NotifyGate: Sendable {
    private var last: [String: Date] = [:]
    static let interval: TimeInterval = 5 * 60

    /// Lines in `new` that are waiting now and were not waiting in `old`, and are allowed to notify.
    mutating func fire(old: [String: LineState], new: [Line], now: Date = Date()) -> [Line] {
        var out: [Line] = []
        last = last.filter { now.timeIntervalSince($0.value) < Self.interval }    // a line gone for 5 min is forgotten
        for l in new where l.state.isWaiting && !(old[l.id]?.isWaiting ?? false) {
            if let t = last[l.id], now.timeIntervalSince(t) < Self.interval { continue }
            last[l.id] = now
            out.append(l)
        }
        return out
    }
}

enum QuietHours {
    /// True when `hour` (0-23) lies in [from, to); a window like 22 to 7 wraps past midnight. from == to means never.
    static func contains(hour: Int, from: Int, to: Int) -> Bool {
        if from == to { return false }
        return from < to ? (hour >= from && hour < to) : (hour >= from || hour < to)
    }
}
