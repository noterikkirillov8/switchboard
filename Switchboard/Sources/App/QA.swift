import AppKit
import SwiftUI

/// `Switchboard -qa <dir>`: renders the real views with fake data to PNGs, then quits. Nothing is shown on screen.
@MainActor
enum QA {
    static var mismatches = 0

    static func renderRepoRows() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-qa"), index + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        Layout.frozen = true
        let model = SwitchModel(live: false), now = Date()
        let rows = [Line(id: "orbit", tool: .claude, cwd: "/demo/orbit/ui", model: "Sonnet 4.5", cliVersion: "2.1.0", git: GitLabel(repo: "orbit", branch: "main", worktree: false), state: .working, since: now, activity: [0, 2, 3, 0, 5, 2, 0, 3, 1, 2, 5, 3]),
                    Line(id: "fern", tool: .codex, cwd: "/demo/fern-preview", model: "gpt-5", cliVersion: "0.92.0", git: GitLabel(repo: "fern", branch: "feature/preview", worktree: true), state: .waitingTurn, since: now, activity: [0, 2, 4, 1, 5, 3, 2, 1, 0, 0, 0, 0])]
        model.load(rows)
        let panel = KitPanel(title: "Switchboard", width: Layout.width, trailing: { EmptyView() }) {
            ForEach(model.lines) { row in RowView(model: model, line: row, last: row.id == model.lines.last?.id) }
        }
        let renderer = ImageRenderer(content: panel.kitAccent(boardAccent).padding(16).background(Color(hex: 0x3A3B3E)).environment(\.colorScheme, .dark))
        renderer.scale = 2
        if let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try png.write(to: dir.appendingPathComponent("30-repo-rows.png"))
            } catch { print("Repo row QA: \(error)") }
        }
        return true
    }

    static func renderAutomationHint() -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "-qa"), index + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[index + 1], isDirectory: true)
        let panel = KitPanel(title: "Switchboard", width: Layout.width, trailing: { EmptyView() }) { AutomationHint {} }
        let renderer = ImageRenderer(content: panel.kitAccent(boardAccent).padding(16).background(Color(hex: 0x3A3B3E)).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return true }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent("18-session-automation-detail.png"))
        } catch { print("Automation QA: \(error)") }
        return true
    }

    /// `-qa <dir> -demo-qa`: the demo board before and after the scripted change (api-server waits, then storefront finishes).
    static func renderDemo(_ dir: URL) {
        let model = SwitchModel(live: false)
        model.preciseOn = true
        var lines = FilmDemo.lines()
        for (name, change) in [("40-demo-before", [:]), ("41-demo-api-waiting", ["api-server": LineState.waitingPermission]), ("42-demo-storefront-done", ["api-server": .waitingPermission, "storefront": .waitingTurn])] as [(String, [String: LineState])] {
            for i in lines.indices { if let s = change[String(lines[i].id.dropFirst(5))] { lines[i].state = s; lines[i].finishedTurn = s == .waitingTurn } }
            model.load(lines)
            let host = NSHostingView(rootView: BoardView(model: model).padding(24).background(Color(hex: 0x3A3B3E)).environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }

    static func runIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-qa"), i + 1 < args.count else { return false }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Layout.frozen = true
        NSApp.setActivationPolicy(.prohibited)
        if args.contains("-demo-qa") { renderDemo(dir); NSApp.terminate(nil); return true }
        _ = renderRepoRows()

        func ln(_ id: String, _ tool: Tool, _ project: String, _ model: String?, _ state: LineState, mins: Double, _ act: [Int], pid: Int32? = 1) -> Line {
            Line(id: id, tool: tool, cwd: "/Users/you/Projects/" + project, model: model, state: state, since: Date().addingTimeInterval(-mins * 60), activity: act, pid: pid, observedAt: Date())
        }
        let busy = [2, 5, 4, 9, 7, 3, 6, 11, 8, 5, 9, 12], calm = [0, 1, 0, 0, 3, 1, 0, 0, 2, 0, 0, 1], none = [Int](repeating: 0, count: 12)
        let lines = Discovery.order([
            ln("c1", .claude, "orbit", "Opus 4.5", .waitingPermission, mins: 3, busy),
            ln("c2", .claude, "copper-shop", "Sonnet 5.5", .working, mins: 12, busy),
            ln("x1", .codex, "paper-planes", "gpt-6.2-astra", .waitingTurn, mins: 7, calm),
            ln("c3", .claude, "atlas-web", "Opus 4.5", .working, mins: 1, calm),
            ln("c4", .claude, "harbor", "Opus 4.5", .idle, mins: 95, none),
        ])
        func scene(_ name: String, dark: Bool = true, lines: [Line] = lines, forceHover: String? = nil, data: Bool = true, tweak: (SwitchModel) -> Void = { _ in }) {
            let model = SwitchModel(live: false)
            model.preciseOn = true
            if data { model.load(lines) }
            tweak(model)
            let view = BoardView(model: model, forceHover: forceHover)
            let host = NSHostingView(rootView: view.padding(24).background(dark ? Color(hex: 0x3A3B3E) : Color(hex: 0xC9C8C3)).environment(\.colorScheme, dark ? .dark : .light))
            capture(host, dark: dark, name: name)
            let measured = host.fittingSize.height - 48
            if abs(measured - view.targetHeight) > 0.5 { mismatches += 1; print("height mismatch in \(name): layout \(measured), computed \(view.targetHeight)") }
        }
        func capture(_ host: NSView, dark: Bool, name: String, size: NSSize? = nil) {
            host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            host.frame = NSRect(origin: .zero, size: size ?? host.fittingSize)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        scene("18-session-automation") { $0.automationTarget = "com.apple.Terminal" }
        scene("17-accurate-lamps") { $0.preciseOn = false }
        if args.contains("-accurate-lamps-only") {
            settingsShot(SwitchModel(live: false), .sources, true, "21-settings-sources", capture)
            print(mismatches == 0 ? "panel heights match layout" : "\(mismatches) height mismatches")
            NSApp.terminate(nil); return true
        }
        var notificationLines = [ln("c1", .claude, "orbit", nil, .waitingTurn, mins: 3, calm),
                                 ln("c2", .claude, "harbor", nil, .waitingPermission, mins: 3, calm)]
        for index in notificationLines.indices { notificationLines[index].fromHook = true }
        scene("16-notification-lamps", lines: notificationLines)
        if args.contains("-notification-lamps-only") { NSApp.terminate(nil); return true }
        var fin = ln("f1", .codex, "paper-planes", "gpt-6.2-astra", .waitingTurn, mins: 1, calm); fin.finishedTurn = true
        scene("19-needs-you", lines: [fin, ln("c1", .claude, "orbit", "Opus 4.5", .waitingPermission, mins: 12, busy), lines[1], lines[3], lines[4]])
        scene("28-all-working", lines: lines.filter { $0.state == .working })
        scene("29-hover-waiting", lines: lines, forceHover: "c1")
        scene("01-list")
        scene("15-long-step", lines: [lines[0], ln("x2", .codex, "copper-shop", "gpt-6.2-astra", .longStep, mins: 4, busy)])
        scene("02-hover-keys", forceHover: "c2")
        scene("03-all-waiting", lines: lines.map { var l = $0; if l.state != .idle { l.state = .waitingTurn }; return l })
        scene("04-exited", lines: [ln("c1", .claude, "orbit", "Opus 4.5", .exited, mins: 4, calm, pid: nil)] + lines.dropFirst())
        scene("05-empty", lines: [])
        scene("06-skeleton", data: false)
        scene("07-one-line", lines: [lines[0]])
        var many: [Line] = []
        for i in 0..<12 {
            let codex = i % 3 == 2
            let state: LineState = i < 3 ? .waitingTurn : (i < 9 ? .working : .idle)
            many.append(ln("m\(i)", codex ? .codex : .claude, "app-\(i + 1)", codex ? "gpt-6.2-astra" : "Opus 4.5", state, mins: Double(2 + i * 5), i % 2 == 0 ? busy : calm))
        }
        scene("08-many-scrolls", lines: many)
        scene("09-light", dark: false, forceHover: "c2")
        scene("10-light-list", dark: false)
        scene("11-power-line-middle") { $0.pulsePreview = 0.5 }
        scene("12-lamps-lit-3", lines: lines) { $0.ledsLit = 2 }
        if let sample = Bundle.main.url(forResource: "claude-agents", withExtension: "json"),
           let data = try? Data(contentsOf: sample), let agents = ClaudeAgent.parse(data) {
            var discovery = Discovery(claudeRoot: dir, codexRoot: dir)
            discovery.updateAgents(agents)
            scene("13-claude-agents", lines: discovery.mergingAgents(into: []))
        }

        // settings, every tab
        for (name, tab, dark) in [("20-settings-general", SettingsTab.general, true), ("21-settings-sources", .sources, true), ("22-settings-alerts", .alerts, true),
                                  ("23-settings-about", .about, true), ("25-settings-general-light", .general, false)] {
            let model = SwitchModel(live: false)
            settingsShot(model, tab, dark, name, capture)
        }
        let on = SwitchModel(live: false); on.preciseOn = true; on.prefs.quiet = true
        settingsShot(on, .sources, true, "26-settings-sources-precise-on", capture)
        settingsShot(on, .alerts, true, "27-settings-alerts-quiet-on", capture)
        on.prefs.quiet = false      // QA must not leave a changed preference behind

        statusItems(dir)
        print(mismatches == 0 ? "panel heights match layout" : "\(mismatches) height mismatches")
        NSApp.terminate(nil)
        return true
    }

    private static func settingsShot(_ model: SwitchModel, _ tab: SettingsTab, _ dark: Bool, _ name: String, height: CGFloat = 560, _ capture: (NSView, Bool, String, NSSize?) -> Void) {
        let host = NSHostingView(rootView: SettingsView(model: model, tab: tab).environment(\.colorScheme, dark ? .dark : .light))
        capture(host, dark, name, NSSize(width: 520, height: height))
    }

    /// The menu bar image for 0, 1, 3 and 12 waiting, on a dark and a light bar, at 4x.
    private static func statusItems(_ dir: URL) {
        let counts = [0, 1, 3, 12]
        let scale: CGFloat = 4
        let tile = NSSize(width: 600 * scale, height: 56 * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(tile.width), pixelsHigh: Int(tile.height), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (half, dark) in [(0, true), (1, false)] {
            let bar = NSRect(x: CGFloat(half) * tile.width / 2, y: 0, width: tile.width / 2, height: tile.height)
            (dark ? NSColor(srgbRed: 0.1, green: 0.1, blue: 0.11, alpha: 1) : NSColor(srgbRed: 0.85, green: 0.85, blue: 0.83, alpha: 1)).setFill()
            bar.fill()
            var x = bar.minX + 20 * scale
            for n in counts {
                let img = StatusImage.make(waiting: n)
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r)
                    (dark ? NSColor.white : NSColor.black).setFill()
                    r.fill(using: .sourceIn)
                    return true
                }
                let r = NSRect(x: x, y: (tile.height - img.size.height * scale) / 2, width: img.size.width * scale, height: img.size.height * scale)
                tinted.draw(in: r)
                x += r.width + 20 * scale
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("14-menu-bar-image.png"))
    }
}
