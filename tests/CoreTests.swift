import Foundation

// Logic tests for Switchboard's state machine, hooks merge and discovery. Fixtures are placeholder text only;
// everything else runs on scratch folders under $TMPDIR. Never reads real transcripts or settings.
@main
struct CoreTests {
    nonisolated(unsafe) static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        print(ok ? "PASS \(name)" : "FAIL \(name)")
        if !ok { failures += 1 }
    }

    static let t0 = Transcript.parseDate("2026-11-20T10:00:00.000Z")!
    static func fixture(_ name: String) -> Data { try! Data(contentsOf: URL(fileURLWithPath: "fixtures/\(name).jsonl")) }

    /// State of a fixture `after` seconds after the base time.
    static func state(_ tool: Tool, _ name: String, after: Double, process: Bool = true, hook: HookEvent? = nil) -> (LineState, Digest) {
        let d = Transcript.digest(tool, tail: fixture(name), partial: false)
        let now = t0.addingTimeInterval(after)
        let r = Transcript.resolve(d, .init(now: now, fileModified: d.lastEvent ?? t0, hasProcess: process, hook: hook))
        return (r.state, d)
    }

    static func testNeedsInbox() {
        func line(_ id: String, _ state: LineState, _ age: Double) -> Line {
            Line(id: id, tool: .codex, cwd: "/demo/" + id, state: state, since: t0.addingTimeInterval(-age), activity: [], pid: 12, observedAt: t0)
        }
        var inbox = NeedsInbox()
        let permission = line("orbit", .waitingPermission, 600), question = line("atlas", .waitingTurn, 90)
        var finished = line("fern", .idle, 60); finished.finishedTurn = true
        let snapshot = [finished, question, line("wren", .blocked, 60), permission, line("cloud", .idle, 20)]
        _ = inbox.update(snapshot, now: t0)
        check(inbox.items.map(\.kind) == [.permission, .question, .finished, .blocked], "inbox: oldest first, stable ties and explicit wait kinds")
        inbox.opened(question)
        _ = inbox.update(snapshot.reversed(), now: t0.addingTimeInterval(299))
        check(inbox.items.count == 3 && inbox.items.first?.line.since == permission.since, "inbox: refresh preserves wait time and opened items stay dismissed")
        let stale = inbox.update(snapshot, now: t0.addingTimeInterval(300))
        check(stale.allSatisfy { $0.state == .unknown } && inbox.items.map(\.kind) == [.unknown, .unknown, .unknown], "inbox: five minutes without source data is Unknown, even for a finished turn")
        var working = question; working.state = .working; working.observedAt = t0.addingTimeInterval(301)
        _ = inbox.update([working], now: working.observedAt!)
        var again = question; again.since = t0.addingTimeInterval(302); again.observedAt = again.since
        _ = inbox.update([again], now: again.since)
        check(inbox.items.contains { $0.id == again.id && $0.kind == .question }, "inbox: new wait after the session moves on is not dismissed")
        var gone = again; gone.pid = nil
        let vanished = inbox.update([gone], now: again.since)
        check(vanished.first { $0.id == gone.id }?.state == .unknown && inbox.items.first { $0.id == gone.id }?.kind == .unknown, "inbox: vanished process without an outcome is Unknown immediately")
        _ = inbox.update([], now: again.since)
        check(inbox.items.contains { $0.id == gone.id && $0.kind == .unknown }, "inbox: missing session keeps its pending item as Unknown")
        var done = gone; done.state = .done; done.since = t0.addingTimeInterval(303); done.observedAt = done.since
        _ = inbox.update([done], now: done.since)
        check(inbox.items.contains { $0.id == gone.id && $0.kind == .finished }, "inbox: known outcome replaces Unknown")
        _ = inbox.update([done], now: done.since.addingTimeInterval(300))
        check(inbox.items.first { $0.id == gone.id }?.kind == .unknown, "inbox: stale Done report is Unknown")
        working.observedAt = done.since.addingTimeInterval(301)
        _ = inbox.update([working], now: working.observedAt!)
        check(!inbox.items.contains { $0.id == working.id }, "inbox: fresh work clears an unopened item")
    }

    static func plainChecks() {
        let now = Date()
        func line(_ state: LineState, mins: Double, finished: Bool = false) -> Line {
            var l = Line(id: "x", tool: .claude, cwd: "/demo/storefront", model: "Opus 5.5", cliVersion: "2.1.0", git: GitLabel(repo: "storefront", branch: "feat/checkout", worktree: true),
                         state: state, since: now.addingTimeInterval(-mins * 60), activity: [1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0], pid: 1)
            l.finishedTurn = finished
            return l
        }
        check(Plain.state(line(.working, mins: 3), now: now) == "Working, 3 min" && Plain.state(line(.working, mins: 0.5), now: now) == "Working", "plain: working shows time once past a minute")
        check(Plain.state(line(.waitingPermission, mins: 9), now: now) == "Waiting: needs permission", "plain: permission wait")
        check(Plain.state(line(.waitingTurn, mins: 9), now: now) == "Waiting: asked a question" && Plain.state(line(.waitingTurn, mins: 9, finished: true), now: now) == "Finished", "plain: question versus finished")
        check(Plain.isWaiting(line(.waitingPermission, mins: 1)) && !Plain.isWaiting(line(.waitingTurn, mins: 1, finished: true)) && !Plain.isWaiting(line(.working, mins: 1)), "plain: amber only for a real wait")
        check(Plain.header(waiting: 2, working: 1, total: 4) == "2 waiting" && Plain.header(waiting: 0, working: 3, total: 3) == "All working"
              && Plain.header(waiting: 0, working: 1, total: 3) == "1 working" && Plain.header(waiting: 0, working: 0, total: 0) == "No sessions" && Plain.header(waiting: 0, working: 0, total: 2) == "All idle", "plain: header says one thing")
        check(Plain.details(line(.working, mins: 1), number: 2) == "feat/checkout (worktree) · Claude Code · Opus 5.5 · CLI 2.1.0 · 3 events · No. 02" && Plain.summary(line(.working, mins: 1)) == "feat/checkout (worktree) · Claude Code · Opus 5.5 · CLI 2.1.0", "plain: hover keeps branch, tool, model, CLI, events and number")
    }

    static func main() throws {
        let root = "/demo/fern", common = root + "/.git"
        let main = GitLabel.parse("\(root)\n\(common)\n\(common)\nmain\n")
        check(main == GitLabel(repo: "fern", branch: "main", worktree: false), "git label: primary checkout")
        check(GitLabel.parse("/demo/preview\n\(common)/worktrees/preview\n\(common)\nfeature/preview\n") == GitLabel(repo: "fern", branch: "feature/preview", worktree: true), "git label: linked checkout uses shared repo and full branch")
        check(GitLabel.parse("\(root)\n\(common)\n\(common)\nHEAD\n")?.branch == "detached HEAD" && GitLabel.parse("fatal: not a repository\n") == nil, "git label: detached and unavailable")
        var labels = GitLabelCache(), reads = 0
        var samples = [root, root, "/demo/plain"].map { Line(id: $0, tool: .codex, cwd: $0, state: .working, since: t0, activity: []) }
        for age in [0, 59, 60] {
            labels.apply(to: &samples, now: t0.addingTimeInterval(Double(age))) { cwd in reads += 1; return cwd == root ? main : nil }
            check(reads == (age == 60 ? 4 : 2) && samples.map(\.git) == [main, main, nil], "git label: cache hits and misses at \(age)s")
        }
        let claudeVersion = Transcript.digest(.claude, tail: Data(#"{"type":"user","version":"2.1.0"}"#.utf8), partial: false)
        let codexVersion = Transcript.digest(.codex, tail: Data(#"{"type":"session_meta","payload":{"cli_version":"0.92.0"}}"#.utf8), partial: false)
        check(claudeVersion.cliVersion == "2.1.0" && codexVersion.cliVersion == "0.92.0", "rows: transcript CLI versions")
        var statusSource = Discovery()
        statusSource.updateAgents(ClaudeAgent.parse(Data(#"[{"kind":"interactive","sessionId":"fern","status":"busy","model":"claude-sonnet-4-5","version":"2.1.0"}]"#.utf8)))
        let mergedRow = statusSource.mergingAgents(into: [Line(id: "claude:fern", tool: .claude, cwd: root, model: "older", state: .working, since: t0, activity: [])]).first
        check(mergedRow?.model == "Sonnet 4.5" && mergedRow?.cliVersion == "2.1.0" && mergedRow?.cwd == root, "rows: status metadata and transcript folder survive merge")
        testNeedsInbox()
        check([" ttys042\n", "/dev/ttys042", "s042"].allSatisfy { SessionFocus.tty($0) == "/dev/ttys042" }, "focus: ps tty normalizes to a device path")
        check([" ??\n", "", "tty", "ttys", "ttys1\nttys2", "ttys001;bad", "/dev/other"].allSatisfy { SessionFocus.tty($0) == nil }, "focus: unknown and malformed ttys rejected")
        for (bundle, selection) in [("com.apple.Terminal", ["tabs of win", "if tty of targetTab is targetTTY", "set selected of targetTab to true", "set index of win to 1"]),
                                   ("com.googlecode.iterm2", ["sessions of targetTab", "if tty of targetSession is targetTTY", "select targetSession", "select targetTab", "select win"])] {
            let script = SessionFocus.script(for: bundle) ?? ""
            check((["on run argv", "item 1 of argv", "tell application id \"\(bundle)\""] + selection).allSatisfy(script.contains) && !script.contains("/dev/"), "focus: \(bundle) selects by tty argument")
        }
        let reveal = SessionFocus.revealURL(["ITERM_SESSION_ID": "w0t2p0:test&id"])
        check(reveal.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } == [URLQueryItem(name: "sessionid", value: "w0t2p0:test&id")], "focus: iTerm session ID stays one URL argument")
        let warp = "warp://action/focus_pane?pane_id=test"
        check(SessionFocus.revealURL(["WARP_FOCUS_URL": warp])?.absoluteString == warp && SessionFocus.revealURL(["WARP_FOCUS_URL": "file:///tmp/test"]) == nil, "focus: Warp only opens a focus URL")
        var commands: [[String]] = []
        let client = SessionFocus.selectPane(env: ["TMUX": "/demo/socket,12,0", "TMUX_PANE": "%7"], tty: nil, tmux: "tmux") { _, args in
            commands.append(args)
            if args.contains("display-message") { return "$3:@2\n" }
            return args.contains("list-clients") ? "42\n" : ""
        }
        check(client == 42 && commands.contains(["-S", "/demo/socket", "select-window", "-t", "$3:@2", ";", "select-pane", "-t", "%7"]), "focus: tmux selects recorded server, window and pane")
        // Claude state machine
        check(state(.claude, "claude-working", after: 8).0 == .working, "claude: tool result just came back is working")
        check(state(.claude, "claude-working", after: 60).0 == .working, "claude: still working a minute later")
        check(state(.claude, "claude-waiting-turn", after: 5).0 == .waitingTurn, "claude: finished turn waits for you")
        check(state(.claude, "claude-waiting-turn", after: 3 * 3600, process: false).0 == .idle, "claude: old finished turn without a process is idle")
        check(state(.claude, "claude-pending-tool", after: 10).0 == .working, "claude: tool call 6 s old is working")
        check(state(.claude, "claude-pending-tool", after: 24).0 == .working, "claude: still working at exactly 20 s")
        let longStep = state(.claude, "claude-pending-tool", after: 25).0
        check(longStep == .longStep && longStep.isWorking && !longStep.isWaiting, "claude: long pending tool without hooks is working, not waiting")
        check(state(.claude, "claude-pending-tool", after: 200, process: false).0 == .exited, "claude: no process and silent is exited")
        check(state(.claude, "claude-pending-tool", after: 3600).0 == .longStep, "claude: live long-running tool stays active")
        check(state(.claude, "claude-generating", after: 20).0 == .working, "claude: partial assistant text is working")
        check(state(.claude, "claude-interrupted", after: 20).0 == .idle, "claude: interruption is not a question")
        let side = state(.claude, "claude-sidechain-ignored", after: 10)
        check(side.1.kind == .pendingTool, "claude: sidechain records are ignored")
        check(side.1.cwd == "/Users/test/Projects/alpha" && side.1.model == "claude-opus-4-5-20251101", "claude: cwd and model read")
        let hookStop = HookEvent(ts: t0.addingTimeInterval(25), event: "Stop", session: "s1", cwd: "")
        let permission = HookEvent(ts: t0.addingTimeInterval(25), event: "PermissionRequest", session: "s1", cwd: "")
        check(state(.claude, "claude-working", after: 30, hook: hookStop).0 == .idle, "hook: Stop alone is not a question")
        let prompted = state(.claude, "claude-pending-tool", after: 30, hook: permission).0
        check(prompted == .waitingPermission && prompted.isWaiting, "hook: permission request on a long pending tool is waiting")
        let oldHook = HookEvent(ts: t0.addingTimeInterval(1), event: "PermissionRequest", session: "s1", cwd: "")
        check(state(.claude, "claude-pending-tool", after: 30, hook: oldHook).0 == .longStep, "hook: an older permission request is ignored")

        // Codex
        check(state(.codex, "codex-working", after: 8).0 == .working, "codex: tool output just came back is working")
        check(state(.codex, "codex-waiting-turn", after: 4).0 == .waitingTurn, "codex: task_complete waits for you")
        check(state(.codex, "codex-pending-tool", after: 40).0 == .longStep, "codex: pending tool without hooks is a long step")
        check(state(.codex, "codex-aborted", after: 10).0 == .idle, "codex: aborted turn is not a question")
        for (tool, name) in [(Tool.claude, "claude-waiting-turn"), (.codex, "codex-waiting-turn")] {
            let waiting = Transcript.digest(tool, tail: fixture(name), partial: false)
            let asked = waiting.lastEvent!
            for minutes in [31, 120] {
                let result = Transcript.resolve(waiting, .init(now: asked.addingTimeInterval(Double(minutes * 60)), fileModified: asked, hasProcess: true))
                check(result == (.waitingTurn, asked, false), "\(tool.title): live unanswered turn keeps its start time at \(minutes) min")
            }
            let reply = String(decoding: fixture(name), as: UTF8.self).replacingOccurrences(of: "Which sample should I use?", with: "The sample is ready.")
            let digest = Transcript.digest(tool, tail: Data(reply.utf8), partial: false)
            check(Transcript.resolve(digest, .init(now: t0, fileModified: t0, hasProcess: true)).state == .idle, "\(tool.title): a finished statement does not light a waiting lamp")
        }
        check(state(.codex, "codex-working", after: 8).1.model == "gpt-6.2-astra", "codex: model and cwd read")
        check(state(.codex, "codex-working", after: 8).1.cwd == "/Users/test/Projects/beta", "codex: cwd read")

        // tail window cut in the middle of the only record
        let big = Data(repeating: UInt8(ascii: "x"), count: 5000)
        check(Transcript.digest(.claude, tail: big, partial: true).kind == .working, "tail: one huge last record counts as working")
        var cut = fixture("claude-waiting-turn"); cut.insert(contentsOf: Array("ceholder\"}\n".utf8), at: 0)
        check(Transcript.digest(.claude, tail: cut, partial: true).kind == .questionEnded, "tail: a cut first line is dropped")

        // helpers
        let bins = Transcript.activity([t0, t0.addingTimeInterval(-30), t0.addingTimeInterval(-590), t0.addingTimeInterval(-700), t0.addingTimeInterval(5)], now: t0)
        check(bins.count == 12 && bins[11] == 2 && bins[0] == 1 && bins.reduce(0, +) == 3, "activity: 12 bins over 10 min, outside events dropped")
        check(Transcript.modelName("claude-opus-4-5-20251101") == "Opus 4.5", "model name: opus 4.5")
        check(Transcript.modelName("claude-sonnet-5-5") == "Sonnet 5.5" && Transcript.modelName("gpt-6.2-astra") == "gpt-6.2-astra", "model name: others")
        check(Transcript.duration(20) == "under 1 min" && Transcript.duration(180) == "3 min" && Transcript.duration(7300) == "2 h", "duration text")
        check(Discovery.sameFolder("/u/p/a", "/u/p/a/app", home: "/u") && Discovery.sameFolder("/u/p/a/app", "/u/p/a", home: "/u") && !Discovery.sameFolder("/u", "/u/p/a", home: "/u") && !Discovery.sameFolder("/u/p/a", "/u/p/ab", home: "/u"), "folder match: same, above or below, never home")
        check(Discovery.encode("/Users/a.b/_x y") == "-Users-a-b--x-y", "folder encoding")
        check(Procs.allPids().contains(1), "procs: the pid list reaches the oldest process (launchd)")
        check(Procs.classify(exe: "/x/claude-code/2.1.1/claude.app/Contents/MacOS/claude", argv: ["/x/claude", "--verbose"]) == .claude, "proc: claude binary")
        check(Procs.classify(exe: "/usr/local/bin/node", argv: ["node", "/x/bin/claude"]) == .claude, "proc: claude under node")
        check(Procs.classify(exe: "/x/CodexCLI.app/Contents/MacOS/codex", argv: ["codex"]) == .codex, "proc: codex cli")
        check(Procs.classify(exe: "/x/codex", argv: ["codex", "app-server"]) == nil, "proc: codex app-server is not a session")
        check(Procs.classify(exe: "/Applications/Claude.app/Contents/MacOS/Claude", argv: ["/Applications/Claude.app/Contents/MacOS/Claude"]) == nil, "proc: Claude desktop is not a session")
        check(Procs.parseArgs([2, 0, 0, 0] + Array("/x/codex".utf8) + [0, 0] + Array("codex".utf8) + [0] + Array("--flag".utf8) + [0] + Array("HOME=/x".utf8) + [0]) == ["codex", "--flag"], "proc: argv parsing drops env")

        // notify gate
        var gate = NotifyGate()
        func line(_ s: LineState) -> Line { Line(id: "claude:s1", tool: .claude, cwd: "/p/a", model: nil, state: s, since: t0, activity: [], pid: nil) }
        check(gate.fire(old: ["claude:s1": .working], new: [line(.waitingTurn)], now: t0).count == 1, "notify: starts waiting fires once")
        check(gate.fire(old: ["claude:s1": .waitingTurn], new: [line(.waitingTurn)], now: t0.addingTimeInterval(10)).isEmpty, "notify: still waiting stays quiet")
        check(gate.fire(old: ["claude:s1": .working], new: [line(.waitingTurn)], now: t0.addingTimeInterval(120)).isEmpty, "notify: at most one per line per 5 min")
        check(gate.fire(old: ["claude:s1": .working], new: [line(.waitingTurn)], now: t0.addingTimeInterval(400)).count == 1, "notify: fires again after 5 min")

        check(QuietHours.contains(hour: 23, from: 22, to: 7) && QuietHours.contains(hour: 3, from: 22, to: 7) && !QuietHours.contains(hour: 12, from: 22, to: 7) && !QuietHours.contains(hour: 5, from: 8, to: 8), "quiet hours wrap past midnight")

        // hooks merge, against a scratch copy
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("switchboard-test-\(getpid())")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let settings = tmp.appendingPathComponent("settings.json"), backups = tmp.appendingPathComponent("backups")
        let original = #"{"model":"x","permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}],"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo pre"}]}]}}"#
        try original.write(to: settings, atomically: true, encoding: .utf8)
        check(!Hooks.isInstalled(settings: settings), "hooks: not installed at first")
        let codexSettings = tmp.appendingPathComponent("config/hooks.json")
        try FileManager.default.createDirectory(at: codexSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        let codexOriginal = Data(#"{"hooks":{"SessionStart":[]}}"#.utf8)
        try codexOriginal.write(to: codexSettings)
        let setup = Hooks.Setup(claude: settings, codex: codexSettings)
        var offer = LampOffer(defaults: nil)
        offer.deferForWeek(now: t0)
        check(offer.hiddenUntil == t0.addingTimeInterval(604800), "lamps: Not now defers the offer for seven days")
        check(!setup.installed && (try! Data(contentsOf: settings)) == Data(original.utf8) && (try! Data(contentsOf: codexSettings)) == codexOriginal && !FileManager.default.fileExists(atPath: backups.path), "lamps: checking setup and deferring the offer do not edit agent settings")
        let codexBackups = codexSettings.deletingLastPathComponent().appendingPathComponent("backups")
        try Data().write(to: codexBackups)
        do {
            try setup.setEnabled(true)
            check(false, "lamps: failed backup must stop setup")
        } catch {
            check((try Data(contentsOf: settings)) == Data(original.utf8) && (try! Data(contentsOf: codexSettings)) == codexOriginal, "lamps: if either backup fails neither settings file changes")
        }
        try FileManager.default.removeItem(at: codexBackups)
        try setup.setEnabled(true)
        let b1 = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil).first
        let codexBackup = try FileManager.default.contentsOfDirectory(at: codexBackups, includingPropertiesForKeys: nil).first
        let savedCodex = try codexBackup.map { try Data(contentsOf: $0) }
        check(setup.installed && savedCodex == codexOriginal, "lamps: Turn on installs both agents’ hooks with the original Codex file backed up")
        func obj() -> [String: Any] { try! JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as! [String: Any] }
        func groups(_ e: String) -> [[String: Any]] { ((obj()["hooks"] as! [String: Any])[e] as? [[String: Any]]) ?? [] }
        check(b1 != nil && (try! String(contentsOf: b1!, encoding: .utf8)) == original, "hooks: backup is the untouched original")
        check(obj()["model"] as? String == "x" && ((obj()["permissions"] as! [String: Any])["allow"] as! [String]) == ["Bash(ls)"], "hooks: other keys untouched")
        check(groups("Stop").count == 2 && groups("PermissionRequest").count == 1 && groups("PreToolUse").count == 1, "hooks: our groups added next to existing hooks")
        check(Hooks.isInstalled(settings: settings), "hooks: installed")
        try setup.setEnabled(true)
        check(groups("Stop").count == 2 && groups("PermissionRequest").count == 1 && groups("Notification").count == 1, "hooks: installing twice adds nothing")
        let notification = (groups("Notification")[0]["hooks"] as! [[String: Any]])[0]["command"] as! String
        let payloads = [
            #"{"session_id":"orbit","message":"Claude is waiting for your input"}"#,
            #"{"session_id":"harbor","message":"Claude needs your permission to use Read"}"#,
            #"{"session_id":"orbit-typed","notification_type":"idle_prompt","message":"Claude needs your permission to use Read"}"#,
            #"{"session_id":"harbor-typed","notification_type":"permission_prompt","message":"Claude is waiting for your input"}"#,
            #"{"session_id":"notice","notification_type":"auth_success","message":"Signed in"}"#,
            #"{"session_id":"notice","message":"Signed in"}"#
        ]
        check(Hooks.events.map(Hooks.command(for:)).allSatisfy { $0.hasPrefix("/usr/bin/python3 ") && !$0.contains("jq") && $0.contains(Hooks.marker) }, "hooks: every generated command uses system Python without jq")
        func runHook(_ command: String, _ payload: String) throws -> Bool {
            let hookProcess = Process(), input = Pipe()
            hookProcess.executableURL = URL(fileURLWithPath: "/bin/sh")
            hookProcess.arguments = ["-c", command]; hookProcess.environment = ["HOME": tmp.path, "PATH": "", "TERM_PROGRAM": "iTerm.app", "ITERM_SESSION_ID": "w0t2p0:demo"]
            hookProcess.standardInput = input
            try hookProcess.run(); input.fileHandleForWriting.write(Data(payload.utf8))
            try input.fileHandleForWriting.close(); hookProcess.waitUntilExit()
            return hookProcess.terminationStatus == 0
        }
        for payload in payloads { check(try runHook(notification, payload), "hooks: notification command succeeds with empty PATH") }
        let journal = tmp.appendingPathComponent("Library/" + Hooks.marker), events = Hooks.latest(in: journal)
        check(events["orbit"]?.terminal["ITERM_SESSION_ID"] == "w0t2p0:demo" && events["orbit"]?.terminal["TERM_PROGRAM"] == "iTerm.app", "focus: hook records terminal identity from its own environment")
        func lamp(_ session: String) -> LineState? {
            guard let event = events[session] else { return nil }
            let result = Transcript.resolve(Digest(), .init(now: event.ts, fileModified: .distantPast, hasProcess: true, hook: event))
            return result.fromHook ? result.state : nil
        }
        check(lamp("orbit") == .waitingTurn && lamp("harbor") == .waitingPermission, "hooks: notification message distinguishes Your turn from Needs permission")
        check(lamp("orbit-typed") == .waitingTurn && lamp("harbor-typed") == .waitingPermission, "hooks: notification_type takes precedence over message")
        let journalText = try String(contentsOf: journal, encoding: .utf8)
        check(events.count == 4 && !journalText.contains("message") && !journalText.contains("Claude"), "hooks: unrelated notifications ignored and message text never logged")
        for event in ["Stop", "PermissionRequest"] {
            let ok = try runHook(Hooks.command(for: event), "{\n\"session_id\":\"orbit\",\n\"cwd\":\"/demo/orbit\",\"extra\":\"discard\"}")
            let record = Hooks.latest(in: journal)["orbit"]
            let text = try String(contentsOf: journal, encoding: .utf8)
            check(ok && record?.event == event && record?.cwd == "/demo/orbit" && !text.contains("discard"), "hooks: \(event) logs only metadata with empty PATH")
        }
        try setup.setEnabled(false)
        check(!Hooks.isInstalled(settings: codexSettings, events: Hooks.codexEvents), "lamps: switching off also removes the Codex hooks")
        check(groups("Stop").count == 1 && (groups("Stop")[0]["hooks"] as! [[String: Any]])[0]["command"] as? String == "echo mine", "hooks: uninstall keeps the user's own Stop hook")
        check(((obj()["hooks"] as! [String: Any])["PermissionRequest"]) == nil && groups("PreToolUse").count == 1 && !Hooks.isInstalled(settings: settings), "hooks: uninstall removes only ours")
        try "not json".write(to: settings, atomically: true, encoding: .utf8)
        var threw = false
        do { try setup.setEnabled(true) } catch { threw = true }
        let left = try String(contentsOf: settings, encoding: .utf8)
        check(threw && left == "not json", "hooks: an unreadable settings file is left alone")
        check(!Hooks.command(for: "Stop").contains("prompt"), "hooks: Stop command does not read prompt text")
        let ev = tmp.appendingPathComponent("events.jsonl")
        let retained = (1...2_000).map { "line-\($0)" }.joined(separator: "\n")
        let exact = String(repeating: "x", count: 1_048_576 - retained.utf8.count - 1) + "\n" + retained
        try Data(exact.utf8).write(to: ev)
        try Hooks.trimIfNeeded(ev)
        check(try Data(contentsOf: ev) == Data(exact.utf8), "hooks: log at 1 MiB stays untouched")
        for ending in ["", "\n"] {
            try Data(("x" + exact + ending).utf8).write(to: ev)
            _ = Hooks.latest(in: ev)
            check(try Data(contentsOf: ev) == Data((retained + ending).utf8), "hooks: read trims oversized log to its last 2,000 lines (final newline: \(!ending.isEmpty))")
        }
        try ("{\"ts\":1000.5,\"event\":\"Stop\",\"session\":\"s1\",\"cwd\":\"/p\"}\n{\"ts\":1010.5,\"event\":\"PermissionRequest\",\"session\":\"s1\",\"cwd\":\"/p\"}\nbroken\n").write(to: ev, atomically: true, encoding: .utf8)
        check(Hooks.latest(in: ev)["s1"]?.event == "PermissionRequest", "hooks: newest event per session")

        // discovery on scratch folders
        let defaults = Discovery(home: tmp, environment: [:])
        check(defaults.claudeRoot.path == tmp.appendingPathComponent(".claude/projects").path && defaults.codexRoot.path == tmp.appendingPathComponent(".codex/sessions").path, "discovery: unset config folders use fake-home defaults")
        let claudeConfig = tmp.appendingPathComponent("custom claude"), codexHome = tmp.appendingPathComponent("custom codex")
        let claude = claudeConfig.appendingPathComponent("projects"), codex = codexHome.appendingPathComponent("sessions")
        let now = t0.addingTimeInterval(40)
        let cal = Calendar.current, c = cal.dateComponents([.year, .month, .day], from: now)
        let day = codex.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        func put(_ name: String, to url: URL, age: Double) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fixture(name).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        try put("claude-pending-tool", to: claude.appendingPathComponent(Discovery.encode("/Users/test/Projects/alpha") + "/s1.jsonl"), age: 35)
        try put("claude-waiting-turn", to: claude.appendingPathComponent("-Users-test-Projects-gamma/s2.jsonl"), age: 30)
        try put("claude-working", to: claude.appendingPathComponent("-Users-test-Projects-old/s3.jsonl"), age: 7200)
        let oldURL = claude.appendingPathComponent("-Users-test-Projects-old/s3.jsonl")
        try String(contentsOf: oldURL, encoding: .utf8).replacingOccurrences(of: "Projects/alpha", with: "Projects/old").write(to: oldURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-7200)], ofItemAtPath: oldURL.path)
        try put("codex-waiting-turn", to: day.appendingPathComponent("rollout-2026-11-20T10-00-00-c1.jsonl"), age: 30)
        var disc = Discovery(home: tmp, environment: ["CLAUDE_CONFIG_DIR": claudeConfig.path, "CODEX_HOME": codexHome.path])
        let procs = [AgentProc(pid: 11, ppid: 1, tool: .claude, cwd: "/Users/test/Projects/alpha", started: nil)]
        let lines = disc.scan(procs: procs, now: now)
        check(lines.contains { $0.id == "claude:s1" } && lines.contains { $0.id == "codex:c1" }, "discovery: finds sessions under CLAUDE_CONFIG_DIR and CODEX_HOME")
        check(lines.count == 3, "discovery: two recent claude sessions and one codex, the 2 h old one hidden")
        check(lines.first(where: { $0.id == "claude:s1" })?.state == .longStep && lines.first(where: { $0.id == "claude:s1" })?.pid == 11, "discovery: process joined by folder, long step found")
        check(lines.filter { $0.pid == 11 }.allSatisfy { $0.focusPID == nil }, "focus: shared folder is not proof of a session tty")
        check(lines.first(where: { $0.id == "codex:c1" })?.state == .waitingTurn, "discovery: codex rollout found")
        var precise = disc
        precise.precise = true; precise.hookFile = journal
        try Data("{\"ts\":\(now.timeIntervalSince1970),\"event\":\"PermissionRequest\",\"session\":\"c1\",\"terminal\":{\"TMUX_PANE\":\"%7\"}}\n".utf8).write(to: journal)
        let hookedLines = precise.scan(procs: procs, now: now)
        check(hookedLines.contains { $0.id == "codex:c1" && $0.fromHook && $0.state == .waitingPermission }, "lamps: Codex permission hook lights the matching session")
        check(hookedLines.first { $0.id == "codex:c1" }?.terminal["TMUX_PANE"] == "%7", "focus: discovery carries the matching session's pane without a pid")
        check(lines.prefix(2).allSatisfy { $0.state.isWaiting } && lines.last?.state == .longStep, "discovery: waiting lines before long steps")
        let sample = try Data(contentsOf: URL(fileURLWithPath: "fixtures/claude-agents.json"))
        let agents = ClaudeAgent.parse(sample)
        check(agents?.compactMap(\.lineState) == [.working, .waitingPermission, .waitingTurn, .blocked, .done, .failed, .stopped], "agents: captured busy record and fictional fleet parse")
        func reported(_ kind: String, _ fields: String) -> LineState? {
            ClaudeAgent.parse(Data("[{\"kind\":\"\(kind)\",\(fields)}]".utf8))?.first?.lineState
        }
        check(["approval", "sandbox request", "input", "dialog open"].map { reported("interactive", "\"status\":\"waiting\",\"waitingFor\":\"\($0)\"") } == [.waitingPermission, .waitingPermission, .waitingTurn, .waitingTurn], "agents: permission and input lamps")
        check(reported("interactive", "\"status\":\"idle\"") == .done && reported("background", "\"state\":\"working\"") == .working, "agents: idle is done, background work is working")
        disc.updateAgents(agents, now: now)
        let merged = disc.scan(procs: procs, now: now)
        let orbit = merged.first { $0.id == "claude:s1" }
        check(merged.filter { $0.id == "claude:s1" }.count == 1 && orbit?.state == .working && orbit?.pid == 4101 && orbit?.project == "Orbit" && orbit?.cwd == "/demo/orbit" && orbit?.activity == lines.first(where: { $0.id == "claude:s1" })?.activity, "agents: command overrides transcript guess by session ID and keeps activity")
        check(merged.contains { $0.id == "claude:job:j3" && $0.state == .failed && $0.pid == nil } && merged.contains { $0.id == "claude:beacon" && $0.state == .waitingPermission }, "agents: command-only background and same-folder sessions stay separate")
        check(merged.contains { $0.id == "claude:s2" && $0.state == .waitingTurn } && merged.contains { $0.id == "codex:c1" && $0.state == .waitingTurn }, "agents: unmatched transcripts and Codex keep their states")
        disc.updateAgents(agents, now: now.addingTimeInterval(5))
        check(disc.mergingAgents(into: []).first { $0.id == "claude:s1" }?.since == now, "agents: repeated status keeps its age")
        disc.updateAgents(ClaudeAgent.parse(Data("broken".utf8)), now: now)
        check(disc.scan(procs: procs, now: now) == lines, "agents: failed poll restores transcript fallback")
        let withOld = disc.scan(procs: procs + [AgentProc(pid: 12, ppid: 1, tool: .claude, cwd: "/Users/test/Projects/old", started: nil)], now: now)
        check(withOld.contains { $0.id == "claude:s3" }, "discovery: an old transcript shows while its folder has a process")
        let gone = disc.scan(procs: [], now: now.addingTimeInterval(120))
        check(gone.first(where: { $0.id == "claude:s1" })?.state == .exited, "discovery: pending call, no process, silent is exited")
        check(gone.first(where: { $0.id == "claude:s2" })?.state == .waitingTurn, "discovery: finished turn without a process still waits")
        // The desktop app runs many sessions from one folder: an older one that still waits must not vanish after 10 min.
        let alpha = claude.appendingPathComponent(Discovery.encode("/Users/test/Projects/alpha"))
        for (stem, name) in [("s4", "claude-waiting-turn"), ("s5", "claude-working")] {
            let url = alpha.appendingPathComponent(stem + ".jsonl")
            try String(decoding: fixture(name), as: UTF8.self).replacingOccurrences(of: "\"sessionId\":\"s1\"", with: "\"sessionId\":\"\(stem)\"")
                .write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-900)], ofItemAtPath: url.path)
        }
        let shared = disc.scan(procs: procs, now: now)
        check(shared.first(where: { $0.id == "claude:s4" })?.state == .waitingTurn, "discovery: an older waiting session of a shared folder still shows")
        check(!shared.contains { $0.id == "claude:s5" }, "discovery: an older quiet session of a shared folder stays hidden")
        let later = disc.scan(procs: procs, now: now.addingTimeInterval(120 * 60))
        check(later.first { $0.id == "claude:s4" }?.state == .waitingTurn, "discovery: an older live wait stays visible after 2 h in a shared folder")
        let answered = t0.addingTimeInterval(121 * 60)
        let answer = #"{"type":"user","timestamp":"2026-11-20T12:01:00Z","message":{"content":"Use the first sample."}}"#
        let handle = try FileHandle(forWritingTo: alpha.appendingPathComponent("s4.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(("\n" + answer + "\n").utf8))
        try handle.close()
        let resumed = disc.scan(procs: procs, now: answered)
        check(resumed.first { $0.id == "claude:s4" }?.state == .working, "discovery: answering the two-hour wait clears the lamp")

        func findsRollout(daysBack: Int, modifiedAge: Double) throws -> Bool {
            let home = tmp.appendingPathComponent("resume-\(daysBack)-\(modifiedAge)")
            let date = cal.date(byAdding: .day, value: -daysBack, to: now)!
            let parts = cal.dateComponents([.year, .month, .day], from: date)
            let path = String(format: ".codex/sessions/%04d/%02d/%02d/rollout-sample.jsonl", parts.year!, parts.month!, parts.day!)
            try put("codex-waiting-turn", to: home.appendingPathComponent(path), age: modifiedAge)
            var discovery = Discovery(home: home, environment: [:])
            let proc = AgentProc(pid: 13, ppid: 1, tool: .codex, cwd: "/Users/test/Projects/beta", started: nil)
            return discovery.scan(procs: [proc], now: now).contains { $0.id == "codex:c1" }
        }
        check(try findsRollout(daysBack: 13, modifiedAge: 23 * 3600), "discovery: finds resumed rollout in the fourteenth day folder")
        check(try !findsRollout(daysBack: 13, modifiedAge: 24 * 3600 + 1), "discovery: skips older rollout not modified in 24 hours")
        check(try !findsRollout(daysBack: 14, modifiedAge: 30), "discovery: skips rollout outside the fourteen day folders")
        check(try findsRollout(daysBack: 2, modifiedAge: 25 * 3600), "discovery: keeps quiet rollout in the original three day folders")

        plainChecks()
        var pruneGate = NotifyGate()
        let wait = Line(id: "g1", tool: .claude, cwd: "/demo/orbit", state: .waitingPermission, since: Date(), activity: [], pid: nil)
        let t = Date()
        _ = pruneGate.fire(old: [:], new: [wait], now: t)
        _ = pruneGate.fire(old: [:], new: [], now: t.addingTimeInterval(400))
        check(pruneGate.fire(old: [:], new: [wait], now: t.addingTimeInterval(401)).count == 1, "gate: stale entries are pruned and a new wait notifies again")
        let twin = { (state: LineState, mins: Double) in Line(id: "claude:s9", tool: .claude, cwd: "/demo/orbit", state: state, since: Date().addingTimeInterval(-mins * 60), activity: [], pid: nil) }
        let ordered = Discovery.order([twin(.idle, 1), twin(.waitingPermission, 5)])
        check(ordered.count == 1 && ordered[0].state == .waitingPermission, "order: two transcripts with one session id make one line, the waiting one")
        introFlowChecks { check($0, $1) }
        print(failures == 0 ? "all passed" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
