import AppKit
import SwiftUI

/// `Switchboard -perf`: headless numbers, no window, no status item. Prints how long a scan takes and how long
/// the board's first layout takes off-screen, then exits.
@MainActor
enum Perf {
    static func runIfAsked() -> Bool {
        guard CommandLine.arguments.contains("-perf") else { return false }
        NSApp.setActivationPolicy(.prohibited)
        Task {
            let engine = Engine()
            var scans: [Double] = []
            for _ in 0..<6 { scans.append(await engine.tick(precise: false).ms) }
            let model = SwitchModel(live: false)
            model.load(Demo.fleet(waiting: true))
            let t0 = CACurrentMediaTime()
            let host = NSHostingView(rootView: BoardView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: Layout.width, height: 300)
            host.layoutSubtreeIfNeeded()
            let layout = (CACurrentMediaTime() - t0) * 1000
            print(String(format: "first scan %.1f ms, later scans %@ ms, off-screen first layout of 4 lines %.1f ms",
                         scans[0], scans.dropFirst().map { String(format: "%.1f", $0) }.joined(separator: "/"), layout))
            NSApp.terminate(nil)
        }
        return true
    }

    /// `-snapshot`: what the board would show right now, as counts only (no names, no paths).
    static func snapshotIfAsked() -> Bool {
        guard CommandLine.arguments.contains("-snapshot") else { return false }
        NSApp.setActivationPolicy(.prohibited)
        Task {
            let procs = Procs.scan()
            let snap = await Engine().tick(precise: false)
            print("processes: claude \(procs.filter { $0.tool == .claude }.count), codex \(procs.filter { $0.tool == .codex }.count)")
            for l in snap.lines { print("\(l.tool.rawValue) \(l.state.rawValue) since \(Int(Date().timeIntervalSince(l.since))) s, process \(l.pid != nil)") }
            NSApp.terminate(nil)
        }
        return true
    }
}
