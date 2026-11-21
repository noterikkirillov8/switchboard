import AppKit
import CoreServices
import Observation
import ServiceManagement
import SwiftUI
import UserNotifications

/// Settings that persist in UserDefaults and take effect live.
@MainActor
@Observable
final class Prefs {
    private let d: UserDefaults
    var notify: Bool { didSet { d.set(notify, forKey: "sbNotify") } }
    var soundOnWaiting: Bool { didSet { d.set(soundOnWaiting, forKey: "sbSoundWaiting") } }
    var quiet: Bool { didSet { d.set(quiet, forKey: "sbQuiet") } }
    var quietFrom: Int { didSet { d.set(quietFrom, forKey: "sbQuietFrom") } }
    var quietTo: Int { didSet { d.set(quietTo, forKey: "sbQuietTo") } }
    var showIdle: Bool { didSet { d.set(showIdle, forKey: "sbShowIdle") } }
    var hotKey: KitHotKey? { didSet { d.set(hotKey.flatMap { try? JSONEncoder().encode($0) }, forKey: "sbHotKey") } }
    var tab: String { didSet { d.set(tab, forKey: "sbSettingsTab") } }

    init(defaults d: UserDefaults = .standard) {
        self.d = d
        notify = d.bool(forKey: "sbNotify")
        soundOnWaiting = d.bool(forKey: "sbSoundWaiting")
        quiet = d.bool(forKey: "sbQuiet")
        quietFrom = d.object(forKey: "sbQuietFrom") as? Int ?? 22
        quietTo = d.object(forKey: "sbQuietTo") as? Int ?? 7
        showIdle = d.object(forKey: "sbShowIdle") as? Bool ?? true
        tab = d.string(forKey: "sbSettingsTab") ?? "general"
        hotKey = (d.data(forKey: "sbHotKey").flatMap { try? JSONDecoder().decode(KitHotKey.self, from: $0) })
            ?? KitHotKey(keyCode: 11, modifiers: NSEvent.ModifierFlags([.option, .command]).rawValue, display: "⌥⌘B")
    }

    var quietNow: Bool { quiet && QuietHours.contains(hour: Calendar.current.component(.hour, from: Date()), from: quietFrom, to: quietTo) }
}

/// FSEvents on the transcript folders. The callback only pokes the model; it never reads content.
final class Watcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let handler: @Sendable () -> Void
    init(paths: [String], handler: @escaping @Sendable () -> Void) {
        self.handler = handler
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, existing as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        if let stream { FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "switchboard.fsevents", qos: .utility)); FSEventStreamStart(stream) }
    }
    deinit { if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) } }
}

/// Local notifications: title and body never contain transcript text.
enum Notifier {
    static func requestAuth() { Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) } }
    static func post(_ line: Line) {
        let c = UNMutableNotificationContent()
        c.title = "\(line.project) is waiting for you"
        c.body = line.tool.title
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: line.id, content: c, trigger: nil))
    }
}

actor Engine {
    struct Snapshot: Sendable { let lines: [Line]; let ms: Double }
    private var discovery: Discovery
    private var gitLabels = GitLabelCache()
    init() {
        discovery = Discovery(hookFile: Hooks.eventsURL)
    }
    func tick(precise: Bool) -> Snapshot {
        let t0 = DispatchTime.now().uptimeNanoseconds
        discovery.precise = precise
        var lines = discovery.scan(procs: Procs.scan())
        gitLabels.apply(to: &lines)
        return Snapshot(lines: lines, ms: Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
    }
    func pollAgents() { discovery.updateAgents(ClaudeAgent.poll()) }
}

@MainActor
@Observable
final class SwitchModel {
    private(set) var lines: [Line] = []
    private(set) var inbox = NeedsInbox()
    private(set) var hasData = false
    private(set) var numbers: [String: Int] = [:]      // the jack number stays with a line
    var shown = false
    var counted = false
    var ledsLit = Int.max
    var pulse = 0
    var pulsePreview: Double?
    var isOpen = false { didSet { if isOpen != oldValue { restartLoop() } } }
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var preciseOn = false
    var lampOffer: LampOffer
    private var offerClock = Date()
    var offerVisible: Bool { !preciseOn && lampOffer.hiddenUntil <= offerClock }
    var preciseError: String?
    var automationTarget: String?
    private var automationLineID: String?
    @ObservationIgnored var onShowBoard: () -> Void = {}
    let prefs = Prefs(defaults: FilmDemo.on ? FilmDemo.defaults : .standard)

    @ObservationIgnored var onSummary: (_ waiting: Int, _ total: Int) -> Void = { _, _ in }
    @ObservationIgnored var onShowIntro: () -> Void = {}
    @ObservationIgnored var onSettings: () -> Void = {}
    @ObservationIgnored var onHotKey: () -> Void = {}
    @ObservationIgnored var onTick: (Double) -> Void = { _ in }
    @ObservationIgnored private let engine = Engine()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var agentLoop: Task<Void, Never>?
    @ObservationIgnored private var lastAgentPoll: ContinuousClock.Instant?
    @ObservationIgnored private var watcher: Watcher?
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var lastTick = Date.distantPast
    @ObservationIgnored private var gate = NotifyGate()
    @ObservationIgnored private var queued = false
    private let live: Bool
    private let demo = FilmDemo.on
    @ObservationIgnored private var demoLines: [Line] = []
    @ObservationIgnored private var demoTask: Task<Void, Never>?

    private let hookSetup: Hooks.Setup

    init(live: Bool = true) {
        self.live = live; shown = !live; counted = !live
        let roots = Discovery()
        hookSetup = Hooks.Setup(claude: roots.claudeRoot.deletingLastPathComponent().appendingPathComponent("settings.json"),
                                codex: roots.codexRoot.deletingLastPathComponent().appendingPathComponent("hooks.json"))
        lampOffer = LampOffer(defaults: live && !FilmDemo.on ? .standard : nil)
    }

    var visible: [Line] { prefs.showIdle ? lines : lines.filter { !$0.state.isQuiet } }
    var waitingCount: Int { lines.filter { $0.state.isWaiting }.count }
    var workingCount: Int { lines.filter { $0.state.isWorking }.count }
    func number(_ l: Line) -> Int { numbers[l.id] ?? 0 }

    func load(_ new: [Line]) { apply(new, alerts: false) }

    // MARK: refresh

    func start() {
        if demo { startDemo(); return }
        let roots = Discovery()
        watcher = Watcher(paths: [roots.claudeRoot.path, roots.codexRoot.path, Hooks.eventsURL.deletingLastPathComponent().path]) { [weak self] in
            Task { @MainActor in self?.requestRefresh() }
        }
        preciseOn = hookSetup.installed
        restartLoop()
    }

    /// Cursor entered the status item: data is fresh by the time of the click.
    func prewarm() { if Date().timeIntervalSince(lastTick) > 1.5 { refresh() } }

    /// File events and prewarm come through here; never more than one scan per 2 s.
    private func requestRefresh() {
        let wait = 2 - Date().timeIntervalSince(lastTick)
        if wait <= 0 { refresh(); return }
        guard !queued else { return }
        queued = true
        Task { try? await Task.sleep(for: .seconds(wait)); queued = false; refresh() }
    }

    /// 2 s while open; closed: 5 s while something is active, else 15 s.
    private func restartLoop() {
        loop?.cancel()
        agentLoop?.cancel()
        guard live, !demo else { return }
        agentLoop = Task { [weak self] in
            while let self, !Task.isCancelled {
                if let lastAgentPoll {
                    try? await Task.sleep(until: lastAgentPoll.advanced(by: .seconds(isOpen ? 5 : 30)), clock: .continuous)
                }
                guard !Task.isCancelled else { return }
                lastAgentPoll = .now
                await engine.pollAgents()
                await refreshNow()
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshNow()
                guard let self else { return }
                let active = lines.contains { $0.state.isWorking || $0.state.isWaiting }
                let s: Double = isOpen ? 2 : (active ? 5 : 15)
                try? await Task.sleep(for: .seconds(s), tolerance: .seconds(isOpen ? 0.2 : 2))
            }
        }
    }

    func refresh() { Task { await refreshNow() } }

    private func refreshNow() async {
        guard live, !demo, !busy else { return }
        busy = true
        let snap = await engine.tick(precise: preciseOn)
        busy = false
        lastTick = Date()
        if offerClock < lampOffer.hiddenUntil && lastTick >= lampOffer.hiddenUntil { offerClock = lastTick }
        onTick(snap.ms)
        apply(snap.lines, alerts: true)
    }

    private func apply(_ snapshot: [Line], alerts: Bool) {
        let new = inbox.update(snapshot, now: Date())
        let before = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.state) })
        var nums = numbers.filter { k, _ in new.contains { $0.id == k } }
        for l in new where nums[l.id] == nil {
            nums[l.id] = (1...).first { n in !nums.values.contains(n) }!
        }
        numbers = nums
        let shownOld = visible.map(\.id)
        let wasData = hasData
        let ids = { (a: [Line]) in a.map(\.id) }
        if ids(new) != ids(lines) { withAnimation(KitMotion.list) { lines = new } }
        else if new != lines { lines = new }
        _ = shownOld
        hasData = true
        onSummary(waitingCount, lines.count)
        guard alerts, wasData else { return }
        let started = gate.fire(old: before, new: new)
        guard !started.isEmpty, !prefs.quietNow else { return }
        if prefs.notify { started.forEach(Notifier.post) }
        if prefs.soundOnWaiting { KitSound.play(.chime) }     // one chime per refresh, however many lines
    }

    // MARK: demo (filming): scripted, in memory only

    private func startDemo() {
        preciseOn = true
        demoLines = FilmDemo.lines()
        pushDemo()
        demoTask = Task { [weak self] in
            for (delay, id, state) in [(4.0, "api-server", LineState.waitingPermission), (3.0, "storefront", .waitingTurn)] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled else { return }
                self.setDemo(id, state)
            }
            while !Task.isCancelled {       // keep the lines fresh, or the inbox marks them stale after 5 min
                try? await Task.sleep(for: .seconds(30))
                self?.pushDemo()
            }
        }
    }

    private func setDemo(_ id: String, _ state: LineState) {
        guard let i = demoLines.firstIndex(where: { $0.id == "demo:" + id }) else { return }
        demoLines[i].state = state
        demoLines[i].finishedTurn = state == .waitingTurn
        demoLines[i].since = Date()
        pushDemo()
    }

    private func answerDemo(_ line: Line) {
        guard line.state.isWaiting else { return }
        setDemo(String(line.id.dropFirst(5)), .working)
    }

    private func pushDemo() {
        let now = Date()
        for i in demoLines.indices { demoLines[i].observedAt = now }
        apply(demoLines, alerts: false)
    }

    // MARK: actions (each one runs from a click)

    func openNotification(_ id: String) async {
        guard live, !demo else { return }
        if !hasData || !lines.contains(where: { $0.id == id }) {
            await engine.pollAgents()
            let snapshot = await engine.tick(precise: preciseOn)
            apply(snapshot.lines, alerts: false)
        }
        if let line = lines.first(where: { $0.id == id }) { open(line) }
    }

    func continueFocus() {
        guard live, let target = automationTarget, let id = automationLineID else { return }
        UserDefaults.standard.set(true, forKey: "sbFocusExplained." + target)
        automationTarget = nil
        if let line = lines.first(where: { $0.id == id }) { open(line) }
    }

    func open(_ line: Line) {
        guard live else { return }
        if demo { answerDemo(line); return }
        automationTarget = nil
        Task {
            let env = line.terminal
            func host(_ chain: [Int32]) -> NSRunningApplication? {
                chain.compactMap { NSRunningApplication(processIdentifier: $0) }.first { $0.activationPolicy == .regular }
            }
            let chain = line.focusPID.map { [$0] + Procs.ancestors(of: $0) } ?? []
            var app = host(chain)
            let program = env["TERM_PROGRAM"]?.lowercased() ?? ""
            var known = ["apple_terminal": "com.apple.Terminal", "iterm.app": "com.googlecode.iterm2", "ghostty": "com.mitchellh.ghostty", "warpterminal": "dev.warp.Warp-Stable", "cursor": "com.todesktop.230313mzl4w4u92", "vscode": "com.microsoft.VSCode"][program]
            if program == "vscode", app?.bundleIdentifier == "com.todesktop.230313mzl4w4u92" { known = app?.bundleIdentifier }
            if let known, app?.bundleIdentifier != known { app = NSRunningApplication.runningApplications(withBundleIdentifier: known).first ?? app }

            let tty = await Task.detached {
                env["tty"].flatMap(SessionFocus.tty) ?? line.focusPID.flatMap {
                    SessionFocus.run("/bin/ps", ["-p", String($0), "-o", "tty="]).flatMap(SessionFocus.tty)
                }
            }.value
            if env["TMUX_PANE"] != nil || env["TMUX"] != nil || chain.contains(where: { Procs.exePath($0).hasSuffix("/tmux") }) {
                if let tmux = SessionFocus.executable("tmux"),
                   let client = await Task.detached(operation: { SessionFocus.selectPane(env: env, tty: tty, tmux: tmux) }).value,
                   let outer = host(Procs.ancestors(of: client)) { if outer.activate() { inbox.opened(line) }; return }
            }
            if let url = SessionFocus.revealURL(env), NSWorkspace.shared.open(url) { inbox.opened(line); return }
            guard let app, let bundle = app.bundleIdentifier else { app?.activate(); return }
            if let cli = ["com.microsoft.VSCode": "code", "com.todesktop.230313mzl4w4u92": "cursor"][bundle], line.cwd.hasPrefix("/"),
               let path = SessionFocus.executable(cli, bundled: app.bundleURL?.appendingPathComponent("Contents/Resources/app/bin/" + cli).path),
               await Task.detached(operation: { SessionFocus.run(path, ["-r", line.cwd]) != nil }).value { inbox.opened(line); return }
            if bundle == "com.mitchellh.ghostty" {
                let version = app.bundleURL.flatMap { Bundle(url: $0) }?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                if version.compare("1.4", options: .numeric) == .orderedAscending { app.activate(); return }
            }
            if let tty, let script = SessionFocus.script(for: bundle) {
                guard UserDefaults.standard.bool(forKey: "sbFocusExplained." + bundle) else {
                    automationLineID = line.id; automationTarget = bundle; onShowBoard(); return
                }
                if await Task.detached(operation: { SessionFocus.run("/usr/bin/osascript", ["-e", script, tty]) != nil }).value { inbox.opened(line); return }
            }
            app.activate()
        }
    }

    func reveal(_ l: Line) {
        guard !l.cwd.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: l.cwd)])
    }

    func setLaunchAtLogin(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setNotify(_ on: Bool) { prefs.notify = on; if on, !demo { Notifier.requestAuth() } }

    func preciseSwitch(_ on: Bool) {
        guard live, !demo else { return }
        preciseError = nil
        do { try hookSetup.setEnabled(on) }
        catch { preciseError = "Could not update both hook files. Check their format and permissions." }
        preciseOn = hookSetup.installed
        refresh()
    }
}
