import Foundation

struct GitLabel: Equatable, Sendable {
    let repo: String
    let branch: String
    let worktree: Bool

    static func parse(_ output: String) -> Self? {
        let fields = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let values = fields.last == "" ? fields.dropLast() : fields[...]
        guard values.count == 4, values.prefix(3).allSatisfy({ $0.hasPrefix("/") }), !fields[3].isEmpty else { return nil }
        let common = URL(fileURLWithPath: fields[2])
        let linked = fields[1] != fields[2]
        let repo = linked ? (common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : common.deletingPathExtension()) : URL(fileURLWithPath: fields[0])
        return Self(repo: repo.lastPathComponent, branch: fields[3] == "HEAD" ? "detached HEAD" : fields[3], worktree: linked)
    }

    static func read(_ cwd: String) -> Self? {
        guard cwd.hasPrefix("/") else { return nil }
        let deadline = DispatchTime.now() + .seconds(1)
        guard let result = run(["rev-parse", "--path-format=absolute", "--show-toplevel", "--absolute-git-dir", "--git-common-dir", "--abbrev-ref", "HEAD"], cwd: cwd, deadline: deadline), let label = parse(result.text) else { return nil }
        if result.status == 0 { return label }
        guard label.branch == "detached HEAD", let unborn = run(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: cwd, deadline: deadline), unborn.status == 0 else { return nil }
        return Self(repo: label.repo, branch: unborn.text.trimmingCharacters(in: .newlines), worktree: label.worktree)
    }

    private static func run(_ arguments: [String], cwd: String, deadline: DispatchTime) -> (status: Int32, text: String)? {
        guard DispatchTime.now() < deadline else { return nil }
        let task = Process(), output = Pipe(), finished = DispatchSemaphore(value: 0)
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", cwd] + arguments
        task.standardOutput = output; task.standardError = FileHandle.nullDevice; task.standardInput = FileHandle.nullDevice
        task.terminationHandler = { _ in finished.signal() }
        do { try task.run() } catch { return nil }
        guard finished.wait(timeout: deadline) == .success else {
            if task.isRunning { task.terminate() }
            return nil
        }
        guard let data = try? output.fileHandleForReading.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return (task.terminationStatus, text)
    }
}

struct GitLabelCache {
    private var entries: [String: (label: GitLabel?, expires: Date)] = [:]

    mutating func apply(to lines: inout [Line], now: Date = Date(), read: (String) -> GitLabel? = GitLabel.read) {
        entries = entries.filter { $0.value.expires > now }
        for index in lines.indices {
            let cwd = lines[index].cwd
            if entries[cwd] == nil { entries[cwd] = (read(cwd), now.addingTimeInterval(60)) }
            lines[index].git = entries[cwd]?.label
        }
    }
}

/// One session on the board.
struct Line: Identifiable, Equatable, Sendable {
    let id: String               // "claude:<session id>"
    let tool: Tool
    var cwd: String
    var model: String?
    var cliVersion: String?
    var git: GitLabel?
    var state: LineState
    var since: Date
    var activity: [Int]          // 12 bins of 50 s, oldest first
    var pid: Int32?              // the CLI process, when one runs in this folder
    var agent: ClaudeAgent? = nil
    var fromHook = false
    var terminal: [String: String] = [:]
    var ambiguousPID = false
    var observedAt: Date? = nil
    var finishedTurn = false
    var focusPID: Int32? { ambiguousPID ? nil : pid }

    var project: String {
        if let name = agent?.name, !name.isEmpty { return name }
        return cwd.isEmpty || cwd == "/" ? tool.title : (cwd as NSString).lastPathComponent
    }
}

/// Finds sessions on disk and joins them with running processes. Keeps a small cache keyed by
/// file size and modification time, so an unchanged transcript is never read twice.
struct Discovery: Sendable {
    var claudeRoot: URL
    var codexRoot: URL
    var hookFile: URL? = nil
    var precise = false          // hooks installed: trust their events, no permission guessing
    private var cache: [String: (stamp: String, digest: Digest)] = [:]
    private var liveWaits: [String: Tool] = [:]
    private var reported: [String: Line] = [:]

    mutating func updateAgents(_ agents: [ClaudeAgent]?, now: Date = Date()) {
        var next: [String: Line] = [:]
        for agent in agents ?? [] {
            guard let id = agent.lineID, let state = agent.lineState else { continue }
            let since = reported[id].flatMap { $0.state == state ? $0.since : nil } ?? now
            next[id] = Line(id: id, tool: .claude, cwd: agent.cwd ?? "", model: Transcript.modelName(agent.model), cliVersion: agent.cliVersion ?? agent.version, state: state, since: since,
                            activity: Array(repeating: 0, count: 12), pid: agent.pid, agent: agent, observedAt: now)
        }
        reported = next
    }

    init(claudeRoot: URL, codexRoot: URL, hookFile: URL? = nil) {
        self.claudeRoot = claudeRoot; self.codexRoot = codexRoot; self.hookFile = hookFile
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, environment: [String: String] = ProcessInfo.processInfo.environment, hookFile: URL? = nil) {
        func config(_ key: String, fallback: String) -> URL {
            guard let path = environment[key], !path.isEmpty else { return home.appendingPathComponent(fallback) }
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        self.init(claudeRoot: config("CLAUDE_CONFIG_DIR", fallback: ".claude").appendingPathComponent("projects"),
                  codexRoot: config("CODEX_HOME", fallback: ".codex").appendingPathComponent("sessions"), hookFile: hookFile)
    }

    static let liveWindow: TimeInterval = 10 * 60

    /// Claude Code encodes a folder as its path with every character outside A-Z, a-z, 0-9 turned into "-".
    static func encode(_ path: String) -> String {
        String(path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
    }

    private struct Candidate { let tool: Tool; let url: URL; let modified: Date; let size: Int }

    mutating func scan(procs: [AgentProc], now: Date = Date()) -> [Line] {
        var cands: [Candidate] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        func files(in dir: URL) -> [Candidate] {
            ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []).compactMap { u in
                guard u.pathExtension == "jsonl", let v = try? u.resourceValues(forKeys: Set(keys)), let m = v.contentModificationDate else { return nil }
                return Candidate(tool: .claude, url: u, modified: m, size: v.fileSize ?? 0)
            }
        }
        // Claude: every project folder's recent transcripts. In a folder that has a process, also its newest one and any
        // from the last half hour: the desktop app runs many sessions from one folder, and a quiet one may be waiting.
        let claudeCwds = Set(procs.filter { $0.tool == .claude }.map { Self.encode($0.cwd) })
        for dir in (try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [] {
            let all = files(in: dir).sorted { $0.modified > $1.modified }
            let hosted = claudeCwds.contains(dir.lastPathComponent)
            for (i, c) in all.enumerated() {
                let age = now.timeIntervalSince(c.modified)
                if age < Self.liveWindow || (hosted && (i == 0 || age < Transcript.waitingFor)) { cands.append(c) }
            }
        }
        // Keep the recent three-day shortlist and include older rollouts resumed in the past day.
        var rollouts: [Candidate] = []
        var resumed: [Candidate] = []
        let cal = Calendar.current
        for back in 0..<14 {
            guard let day = cal.date(byAdding: .day, value: -back, to: now) else { continue }
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let dir = codexRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            for file in files(in: dir) where file.url.lastPathComponent.hasPrefix("rollout-") {
                let rollout = Candidate(tool: .codex, url: file.url, modified: file.modified, size: file.size)
                if back < 3 { rollouts.append(rollout) }
                else if now.timeIntervalSince(file.modified) <= 24 * 3600 { resumed.append(rollout) }
            }
        }
        rollouts.sort { $0.modified > $1.modified }
        let shortlist = rollouts.enumerated().filter { now.timeIntervalSince($0.element.modified) < Self.liveWindow || $0.offset < 40 }.map(\.element)
        cands += (shortlist + resumed).sorted { $0.modified > $1.modified }

        let listed = Set(cands.map { $0.url.path })
        for (path, tool) in liveWaits where !listed.contains(path) {
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let modified = values.contentModificationDate else { continue }
            cands.append(Candidate(tool: tool, url: url, modified: modified, size: values.fileSize ?? 0))
        }
        liveWaits.removeAll(keepingCapacity: true)

        let hooks = precise ? (hookFile.map { Hooks.latest(in: $0) } ?? [:]) : [:]
        var lines: [Line] = []
        var seen = Set<String>()
        for c in cands {
            let key = c.url.path
            let stamp = "\(c.size):\(c.modified.timeIntervalSince1970)"
            var digest: Digest
            if let hit = cache[key], hit.stamp == stamp { digest = hit.digest }
            else {
                guard let (data, partial) = Transcript.tail(of: c.url) else { continue }
                let stem = c.url.deletingPathExtension().lastPathComponent
                digest = Transcript.digest(c.tool, tail: data, partial: partial, sessionID: c.tool == .claude ? stem : nil)
                if partial {
                    digest.cliVersion = digest.cliVersion ?? cache[key]?.digest.cliVersion
                    if c.tool == .codex, digest.cwd == nil || digest.cliVersion == nil {
                        let header = Transcript.codexHeader(of: c.url)
                        digest.cwd = digest.cwd ?? header.cwd
                        digest.cliVersion = digest.cliVersion ?? header.version
                    }
                    digest.model = digest.model ?? cache[key]?.digest.model
                }
                cache[key] = (stamp, digest)
            }
            seen.insert(key)
            let cwd = digest.cwd ?? ""
            let mine = procs.filter { $0.tool == c.tool && !cwd.isEmpty && Self.sameFolder($0.cwd, cwd) }
            let age = now.timeIntervalSince(c.modified)
            // a process rooted in home or / (hosted by an app) could belong to any session: do not call a quiet one exited
            let vague = procs.contains { $0.tool == c.tool && [NSHomeDirectory(), "/", ""].contains($0.cwd) }
            let sid = digest.sessionID ?? c.url.deletingPathExtension().lastPathComponent
            let rolloutID = String(sid.suffix(36))
            let hook = hooks[sid] ?? (c.tool == .codex && UUID(uuidString: rolloutID) != nil ? hooks[rolloutID] : nil)
            let (state, since, fromHook) = Transcript.resolve(digest, .init(now: now, fileModified: c.modified, hasProcess: !mine.isEmpty || vague,
                                                                   hook: hook))
            // Old transcript: show it only while a process of that folder runs, and it is that folder's newest session or still waits.
            if age >= Self.liveWindow {
                guard !mine.isEmpty, state.isWaiting || !lines.contains(where: { $0.tool == c.tool && $0.cwd == cwd }) else { continue }
            }
            if state == .waitingTurn && !mine.isEmpty { liveWaits[key] = c.tool }
            lines.append(Line(id: "\(c.tool.rawValue):\(sid)", tool: c.tool, cwd: cwd, model: Transcript.modelName(digest.model), cliVersion: digest.cliVersion, state: state, since: since,
                              activity: Transcript.activity(digest.stamps, now: now), pid: mine.first?.pid, fromHook: fromHook, terminal: hook?.terminal ?? [:], ambiguousPID: mine.count > 1,
                              observedAt: fromHook ? since : digest.lastEvent ?? c.modified,
                              finishedTurn: (state == .idle && (fromHook || digest.kind == .turnEnded)) ||
                                  (fromHook && hook?.event == "IdlePrompt" && digest.kind != .questionEnded)))
        }
        cache = cache.filter { seen.contains($0.key) }
        let byPID = Dictionary(grouping: lines, by: \.pid)
        let ambiguous = byPID.filter { Set($0.value.map(\.id)).count > 1 }
        for index in lines.indices where ambiguous[lines[index].pid] != nil { lines[index].ambiguousPID = true }
        return mergingAgents(into: lines, hooks: hooks)
    }

    func mergingAgents(into lines: [Line], hooks: [String: HookEvent] = [:]) -> [Line] {
        var agents = reported
        let merged = lines.map { line in
            guard var live = agents.removeValue(forKey: line.id) else { return line }
            live.activity = line.activity
            if live.cwd.isEmpty { live.cwd = line.cwd }
            live.model = live.model ?? line.model
            live.cliVersion = live.cliVersion ?? line.cliVersion
            live.terminal = line.terminal
            live.pid = live.pid ?? line.focusPID
            return live
        }
        return Self.order(merged + agents.values.map { line in
            var live = line
            if let id = live.agent?.sessionId { live.terminal = hooks[id]?.terminal ?? [:] }
            return live
        })
    }

    /// A process runs in the session's folder, or in a folder above or below it (a session may `cd`). Home and / only match exactly.
    static func sameFolder(_ proc: String, _ session: String, home: String = NSHomeDirectory()) -> Bool {
        if proc == session { return true }
        func inside(_ outer: String, _ inner: String) -> Bool { outer != home && outer != "/" && outer.count > 1 && inner.hasPrefix(outer + "/") }
        return inside(proc, session) || inside(session, proc)
    }

    /// Waiting lines first (the one that started waiting last on top), then exited, working, idle.
    static func order(_ lines: [Line]) -> [Line] {
        func rank(_ s: LineState) -> Int {
            switch s { case .waitingPermission, .waitingTurn, .blocked: 0; case .exited, .failed, .stopped, .unknown: 1; case .working, .longStep: 2; case .idle, .done: 3 }
        }
        return lines.sorted { a, b in
            let (ra, rb) = (rank(a.state), rank(b.state))
            return ra != rb ? ra < rb : (a.since != b.since ? a.since > b.since : a.id < b.id)
        }
    }
}
