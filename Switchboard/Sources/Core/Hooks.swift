import Foundation

struct LampOffer {
    private let defaults: UserDefaults?
    private(set) var hiddenUntil: Date

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        hiddenUntil = defaults?.object(forKey: "sbLampOfferUntil") as? Date ?? .distantPast
    }

    mutating func deferForWeek(now: Date = Date()) {
        hiddenUntil = now.addingTimeInterval(7 * 24 * 3600)
        defaults?.set(hiddenUntil, forKey: "sbLampOfferUntil")
    }
}

/// One line from the optional hook file: only ids and a time, never text.
struct HookEvent: Sendable, Equatable {
    let ts: Date
    let event: String        // "IdlePrompt", "PermissionRequest" or "Stop"
    let session: String
    let cwd: String
    var terminal: [String: String] = [:]
}

/// Precise mode: both agents append metadata to `events.jsonl`.
enum Hooks {
    static let events = ["PermissionRequest", "Stop", "Notification"]
    static let codexEvents = ["PermissionRequest", "Stop"]
    /// Marker used to find (and only remove) our own entries.
    static let marker = "Application Support/Switchboard/events.jsonl"

    static var eventsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Switchboard/events.jsonl")
    }

    static func command(for event: String) -> String {
        let kind = event == "Notification" ? """
        notice = payload.get("notification_type")
        event = {"idle_prompt":"IdlePrompt", "permission_prompt":"PermissionRequest"}.get(notice)
        if notice is None:
            message = (payload.get("message") or "").lower()
            if "waiting for your input" in message: event = "IdlePrompt"
            elif any(text in message for text in ("needs your permission", "permission request", "permission to use")): event = "PermissionRequest"
        if not event: sys.exit(0)
        """ : "event = \"\(event)\""
        return """
        /usr/bin/python3 -I -c 'import fcntl, json, os, subprocess, sys, time
        payload = json.load(sys.stdin)
        \(kind)
        path = sys.argv[1]
        terminal = {key: os.environ[key] for key in ("TERM_PROGRAM", "ITERM_SESSION_ID", "WARP_FOCUS_URL", "TMUX_PANE", "TMUX") if os.environ.get(key)}
        try:
            tty = subprocess.run(["/bin/ps", "-p", str(os.getpid()), "-o", "tty="], capture_output=True, text=True).stdout.strip()
            if tty and tty != "??": terminal["tty"] = tty
        except OSError: pass
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as log:
            fcntl.flock(log, fcntl.LOCK_EX)
            print(json.dumps(dict(ts=time.time(), event=event, session=payload.get("session_id"), cwd=payload.get("cwd"), terminal=terminal)), file=log)' "$HOME/Library/\(marker)"
        """
    }

    private static func group(_ event: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": command(for: event)]]]
    }

    private static func isOurs(_ group: Any) -> Bool {
        guard let g = group as? [String: Any], let hs = g["hooks"] as? [[String: Any]] else { return false }
        return hs.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    static func isInstalled(settings: URL, events: [String] = events) -> Bool {
        guard let root = read(settings), let hooks = root["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { (hooks[$0] as? [Any])?.contains(where: isOurs) == true }
    }

    private static func read(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url), !d.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }

    enum Failure: Error { case unreadable }

    struct Setup {
        let claude: URL
        let codex: URL

        var installed: Bool {
            Hooks.isInstalled(settings: claude) && Hooks.isInstalled(settings: codex, events: codexEvents)
        }

        func setEnabled(_ enabled: Bool) throws {
            var edits: [(URL, Data)] = []
            for (url, names) in [(claude, events), (codex, codexEvents)] {
                if let data = try Hooks.edit(settings: url, events: names, enabled: enabled) { edits.append((url, data)) }
            }
            for (url, _) in edits {
                _ = try Hooks.backup(url, to: url.deletingLastPathComponent().appendingPathComponent("backups"), now: Date())
            }
            for (url, data) in edits {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            }
        }
    }

    private static func edit(settings: URL, events: [String], enabled: Bool) throws -> Data? {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: settings.path) {
            guard let r = read(settings) else { throw Failure.unreadable }   // never overwrite a file we cannot parse
            root = r
        }
        let original = root as NSDictionary
        guard root["hooks"] == nil || root["hooks"] is [String: Any] else { throw Failure.unreadable }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if !enabled && hooks.isEmpty { return nil }
        for e in events {
            guard hooks[e] == nil || hooks[e] is [Any] else { throw Failure.unreadable }
            var groups = hooks[e] as? [Any] ?? []
            for index in groups.indices.reversed() where isOurs(groups[index]) {
                guard var existing = groups[index] as? [String: Any], var entries = existing["hooks"] as? [[String: Any]] else { continue }
                for entry in entries.indices.reversed() where (entries[entry]["command"] as? String)?.contains(marker) == true {
                    if enabled { entries[entry]["command"] = command(for: e) } else { entries.remove(at: entry) }
                }
                existing["hooks"] = entries
                if entries.isEmpty { groups.remove(at: index) } else { groups[index] = existing }
            }
            if enabled && !groups.contains(where: isOurs) { groups.append(group(e)) }
            if enabled || (hooks[e] as? [Any])?.contains(where: isOurs) == true { hooks[e] = groups.isEmpty ? nil : groups }
        }
        root["hooks"] = hooks.isEmpty ? nil : hooks
        guard !original.isEqual(to: root) else { return nil }
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func backup(_ settings: URL, to dir: URL, now: Date) throws -> URL? {
        guard FileManager.default.fileExists(atPath: settings.path) else { return nil }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let dest = dir.appendingPathComponent("\(settings.deletingPathExtension().lastPathComponent)-\(f.string(from: now))-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: settings, to: dest)
        return dest
    }

    // MARK: reading the event file

    static func trimIfNeeded(_ url: URL) throws {
        let limit = 1_048_576
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_size > limit else { return }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else { return }
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        guard data.count > limit else { return }
        var lines = 0
        for index in data.indices.reversed().dropFirst() where data[index] == 10 {
            lines += 1
            if lines == 2_000 {
                let kept = data.subdata(in: (index + 1)..<data.endIndex)
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: kept)
                try handle.truncate(atOffset: UInt64(kept.count))
                return
            }
        }
    }

    /// Newest event per session id, from the last 32 KB of the file.
    static func latest(in url: URL = eventsURL) -> [String: HookEvent] {
        try? trimIfNeeded(url)
        guard let (data, partial) = Transcript.tail(of: url) else { return [:] }
        var out: [String: HookEvent] = [:]
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if partial, !lines.isEmpty { lines.removeFirst() }
        for l in lines {
            guard let o = try? JSONSerialization.jsonObject(with: Data(l)) as? [String: Any],
                  let ts = o["ts"] as? Double, let e = o["event"] as? String, let s = o["session"] as? String else { continue }
            let ev = HookEvent(ts: Date(timeIntervalSince1970: ts), event: e, session: s, cwd: o["cwd"] as? String ?? "", terminal: o["terminal"] as? [String: String] ?? [:])
            if out[s].map({ $0.ts <= ev.ts }) ?? true { out[s] = ev }
        }
        return out
    }
}
