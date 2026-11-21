import AppKit
import SwiftUI

/// `Switchboard -intro-preview <dir>`: start, middle and end frame of every intro scene, off-screen only.
@MainActor
enum IntroPreview {
    static func runIfAsked() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-intro-preview"), i + 1 < args.count else { return false }
        NSApp.setActivationPolicy(.prohibited)
        Layout.frozen = true
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scene in 0..<IntroModel.titles.count {
            for (label, t) in [("start", 0.2), ("dusk", 0.55), ("middle", 2.2), ("end", 4.2)] {
                let demo = Demo(scene: scene)
                demo.jump(to: t)
                let intro = IntroModel(scene: scene, preview: demo)
                let host = NSHostingView(rootView: IntroView(intro: intro).padding(24).background(Color(hex: 0x2A2B2E)).environment(\.colorScheme, .dark))
                host.appearance = NSAppearance(named: .darkAqua)
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("intro-\(scene + 1)-\(label).png"))
            }
        }
        NSApp.terminate(nil)
        return true
    }
}
