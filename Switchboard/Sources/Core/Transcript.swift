import Foundation

enum Tool: String, Sendable, Equatable { case claude, codex
    var title: String { self == .claude ? "Claude Code" : "Codex" }
}

/// What a line on the board is doing. `waitingTurn` = a finished turn waiting for input,
/// `waitingPermission` = a reported permission prompt.
enum LineState: String, Sendable, Equatable {
    case working, longStep, waitingTurn, waitingPermission, idle, exited, blocked, done, failed, stopped, unknown
    var isWorking: Bool { self == .working || self == .longStep }
    var isWaiting: Bool { self == .waitingTurn || self == .waitingPermission || self == .blocked }
    var isQuiet: Bool { self == .idle || self == .done }
}

/// What the last events of a transcript say, without any text from it. Only structure is kept.
struct Digest: Sendable, Equatable {
    enum Kind: Sendable { case turnEnded, interrupted, questionEnded, pendingQuestion, pendingTool, working, unknown }
    var kind: Kind = .unknown
    var cwd: String?
    var model: String?
    var cliVersion: String?
    var lastEvent: Date?
    var stamps: [Date] = []     // event times inside the tail, for the activity strip
    var sessionID: String?
}

enum Transcript {
    static let tailBytes = 65_536

    /// Last `tailBytes` of a file, or all of it. Never reads more.
    static func tail(of url: URL) -> (data: Data, partial: Bool)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        guard (try? h.seek(toOffset: start)) != nil, let d = try? h.readToEnd() else { return nil }
        return (d, start > 0)
    }

    /// The folder a Codex rollout started in, from its first line (about 22 KB, mostly fixed instructions we skip).
    static func codexHeader(of url: URL) -> (cwd: String?, version: String?) {
        guard let h = try? FileHandle(forReadingFrom: url), let d = try? h.read(upToCount: 65_536) else { return (nil, nil) }
        try? h.close()
        guard let line = d.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first,
              let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["type"] as? String == "session_meta",
              let payload = o["payload"] as? [String: Any] else { return (nil, nil) }
        return (payload["cwd"] as? String, payload["cli_version"] as? String)
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    /// Splits a tail into JSON objects. A first line cut off by the window is dropped; if that
    /// leaves nothing (one huge last record) `truncatedOnly` is true.
    static func records(_ data: Data, partial: Bool) -> (objects: [[String: Any]], truncatedOnly: Bool) {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if partial, !lines.isEmpty { lines.removeFirst(); if lines.isEmpty { return ([], true) } }
        let objs = lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        return (objs, objs.isEmpty && !data.isEmpty && partial)
    }

    static func digest(_ tool: Tool, tail data: Data, partial: Bool, sessionID: String? = nil) -> Digest {
        let (objs, truncated) = records(data, partial: partial)
        var d = Digest(sessionID: sessionID)
        if truncated { d.kind = .working }          // the last record is bigger than the window: a tool just answered
        for o in objs {
            switch tool {
            case .claude: applyClaude(o, &d)
            case .codex: applyCodex(o, &d)
            }
        }
        return d
    }

    private static func endsInQuestion(_ text: String?) -> Bool {
        guard let last = text?.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "?" || last == "？" || last == "؟"
    }

    private static func applyClaude(_ o: [String: Any], _ d: inout Digest) {
        guard let type = o["type"] as? String, type == "assistant" || type == "user" || type == "system" || type == "attachment" else { return }
        if o["isSidechain"] as? Bool == true { return }
        if let version = o["version"] as? String { d.cliVersion = version }
        let ts = parseDate(o["timestamp"] as? String)
        if let ts { d.stamps.append(ts) }
        if let c = o["cwd"] as? String, !c.isEmpty { d.cwd = c }
        if d.sessionID == nil, let s = o["sessionId"] as? String { d.sessionID = s }
        let msg = o["message"] as? [String: Any]
        let content = msg?["content"] as? [Any]
        let kinds = Set((content ?? []).compactMap { ($0 as? [String: Any])?["type"] as? String })
        switch type {
        case "assistant":
            if let m = msg?["model"] as? String, !m.hasPrefix("<") { d.model = m }
            let stop = msg?["stop_reason"] as? String
            d.lastEvent = ts ?? d.lastEvent
            if kinds.contains("tool_use") || stop == "tool_use" { d.kind = .pendingTool }
            else if stop == "end_turn", endsInQuestion((content?.last as? [String: Any])?["text"] as? String ?? msg?["content"] as? String) { d.kind = .questionEnded }
            else if let stop, ["end_turn", "stop_sequence", "max_tokens", "refusal"].contains(stop) { d.kind = .turnEnded }
            else { d.kind = .working }
        case "user":
            if o["isMeta"] as? Bool == true { return }
            d.lastEvent = ts ?? d.lastEvent
            if kinds.contains("tool_result") { d.kind = .working; return }
            var text = msg?["content"] as? String ?? ""
            if text.isEmpty, let first = (content?.first as? [String: Any])?["text"] as? String { text = first }
            d.kind = text.hasPrefix("[Request interrupted by user") ? .interrupted : .working
        default: break
        }
    }

    private static func applyCodex(_ o: [String: Any], _ d: inout Digest) {
        guard let type = o["type"] as? String else { return }
        let ts = parseDate(o["timestamp"] as? String)
        let p = o["payload"] as? [String: Any]
        let pt = p?["type"] as? String
        if let ts, type == "event_msg" || type == "response_item" { d.stamps.append(ts) }
        switch (type, pt) {
        case ("session_meta", _):
            if let version = p?["cli_version"] as? String { d.cliVersion = version }
            if let c = p?["cwd"] as? String { d.cwd = c }
            if d.sessionID == nil { d.sessionID = p?["id"] as? String }
        case ("turn_context", _):
            if let c = p?["cwd"] as? String { d.cwd = c }
            if let m = p?["model"] as? String { d.model = m }
        case ("event_msg", "task_started"): d.kind = .working; d.lastEvent = ts ?? d.lastEvent
        case ("response_item", "message") where p?["role"] as? String == "assistant":
            let text = (p?["content"] as? [[String: Any]])?.last?["text"] as? String
            d.kind = p?["phase"] as? String != "commentary" && endsInQuestion(text) ? .pendingQuestion : .working
            d.lastEvent = ts ?? d.lastEvent
        case ("event_msg", "task_complete"):
            let question = (p?["last_agent_message"] as? String).map { endsInQuestion($0) } ?? (d.kind == .pendingQuestion)
            d.kind = question ? .questionEnded : .turnEnded; d.lastEvent = ts ?? d.lastEvent
        case ("event_msg", "turn_aborted"): d.kind = .interrupted; d.lastEvent = ts ?? d.lastEvent
        case ("response_item", "function_call"), ("response_item", "custom_tool_call"): d.kind = .pendingTool; d.lastEvent = ts ?? d.lastEvent
        case ("response_item", "function_call_output"), ("response_item", "custom_tool_call_output"): d.kind = .working; d.lastEvent = ts ?? d.lastEvent
        default: break
        }
    }

    // MARK: state machine

    struct Context: Sendable {
        var now: Date
        var fileModified: Date
        var hasProcess: Bool
        var hook: HookEvent? = nil
    }

    static let longStepDelay: TimeInterval = 20
    static let waitingFor: TimeInterval = 30 * 60
    static let workingFor: TimeInterval = 15 * 60
    static let exitedAfter: TimeInterval = 90

    /// The line's state and when it entered it.
    static func resolve(_ d: Digest, _ c: Context) -> (state: LineState, since: Date, fromHook: Bool) {
        let last = d.lastEvent ?? c.fileModified
        // A hook event newer than the transcript is exact, no guessing needed.
        if let h = c.hook, h.ts > last {
            if h.event == "IdlePrompt" { return (.waitingTurn, h.ts, true) }
            if h.event == "PermissionRequest" { return (.waitingPermission, h.ts, true) }
            if h.event == "Stop", d.kind != .questionEnded { return (.idle, h.ts, true) }
        }
        let age = c.now.timeIntervalSince(max(last, c.fileModified))
        switch d.kind {
        case .turnEnded, .interrupted: return (.idle, last, false)
        case .questionEnded:
            // measured from the event itself: later metadata lines can touch the file without anything happening
            return (c.hasProcess || c.now.timeIntervalSince(last) <= waitingFor ? .waitingTurn : .idle, last, false)
        case .pendingTool where c.now.timeIntervalSince(last) > longStepDelay && (c.hasProcess || age <= exitedAfter):
            return (.longStep, last.addingTimeInterval(longStepDelay), false)
        case .pendingTool, .pendingQuestion, .working, .unknown:
            if !c.hasProcess && age > exitedAfter { return (.exited, last, false) }
            return (age > workingFor ? .idle : .working, last, false)
        }
    }

    /// 12 bins of 50 s over the last 10 minutes (oldest first): how many events fell in each.
    static func activity(_ stamps: [Date], now: Date) -> [Int] {
        var bins = [Int](repeating: 0, count: 12)
        for s in stamps {
            let ago = now.timeIntervalSince(s)
            guard ago >= 0, ago < 600 else { continue }
            bins[11 - Int(ago / 50)] += 1
        }
        return bins
    }

    /// "claude-opus-4-5-20251101" becomes "Opus 4.5"; other names are shown as they are.
    static func modelName(_ raw: String?) -> String? {
        guard var m = raw, !m.isEmpty else { return nil }
        guard m.hasPrefix("claude-") else { return m }
        m.removeFirst(7)
        var parts = m.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        guard let family = parts.first else { return nil }
        let version = parts.dropFirst().filter { Int($0) != nil }.joined(separator: ".")
        return family.capitalized + (version.isEmpty ? "" : " " + version)
    }

    /// "3 min", "2 h", "1 d" (the state name goes in front).
    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "under 1 min" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600) h" }
        return "\(s / 86400) d"
    }
}
