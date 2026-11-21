import Foundation

struct NeedsInbox {
    enum Kind: String {
        case permission = "Needs permission", question = "Asked a question", finished = "Finished", blocked = "Blocked", unknown = "Unknown"

        init?(_ line: Line) {
            switch line.state {
            case .waitingPermission: self = .permission
            case .waitingTurn: self = line.finishedTurn ? .finished : .question
            case .done: self = .finished
            case .idle where line.finishedTurn: self = .finished
            case .blocked: self = .blocked
            default: return nil
            }
        }
    }

    struct Item: Identifiable {
        var line: Line
        var kind: Kind
        var id: String { line.id }
    }

    private struct Record {
        var source: Line
        var opened = false
        var lostProcess = false
        var missingSince: Date?

        var hasOutcome: Bool { Kind(source) == .finished || source.state == .failed || source.state == .stopped }
    }

    private var records: [String: Record] = [:]
    private(set) var items: [Item] = []

    mutating func update(_ snapshot: [Line], now: Date) -> [Line] {
        var previous = records
        records.removeAll(keepingCapacity: true)
        for line in snapshot {
            let old = previous.removeValue(forKey: line.id)
            var next = Record(source: line)
            if let old {
                let stamp = line.observedAt ?? line.since, last = old.source.observedAt ?? old.source.since
                if stamp < last || (stamp == last && Kind(old.source) != nil && Kind(line) == nil) {
                    next.source = old.source
                    next.source.pid = line.pid
                    next.source.terminal = line.terminal
                }
                next.lostProcess = line.pid == nil && (old.source.pid != nil || old.lostProcess)
                next.opened = old.opened && next.source.since == old.source.since && Kind(next.source) == Kind(old.source)
            }
            records[line.id] = next
        }
        for (id, var record) in previous {
            let missingSince = record.missingSince ?? now
            record.missingSince = missingSince
            let pending = Kind(record.source) != nil && !record.opened
            guard pending || (!record.hasOutcome && now.timeIntervalSince(missingSince) < 300) else { continue }
            record.lostProcess = true
            record.source.pid = nil
            records[id] = record
        }
        var board: [Line] = []
        items = []
        for record in records.values {
            var line = record.source
            let kind = Kind(line)
            if now.timeIntervalSince(line.observedAt ?? line.since) >= 300 || line.state == .exited || (record.lostProcess && !record.hasOutcome) {
                line.state = .unknown
            }
            board.append(line)
            if let kind, !record.opened { items.append(Item(line: line, kind: line.state == .unknown ? .unknown : kind)) }
        }
        items.sort { ($0.line.since, $0.id) < ($1.line.since, $1.id) }
        return Discovery.order(board)
    }

    mutating func opened(_ line: Line) {
        guard let item = items.first(where: { $0.id == line.id }), item.line.since == line.since else { return }
        records[line.id]?.opened = true
        items.removeAll { $0.id == line.id }
    }
}
