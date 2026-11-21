import AppKit
import Carbon
import SwiftUI
import UserNotifications

/// One borderless panel for the app's whole life; opening it is just `orderFront`.
final class BoardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class SettingsWindow: NSWindow { override var canBecomeKey: Bool { true } }

@main
@MainActor
final class SwitchboardApp: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static func main() {
        if CommandLine.arguments.contains("-repo-rows-only"), CommandLine.arguments.contains("-qa") {
            NSApp?.setActivationPolicy(.prohibited)
            _ = QA.renderRepoRows(); return
        }
        if CommandLine.arguments.contains("-inbox-only"), QA.renderNeedsInbox() { return }
        if CommandLine.arguments.contains("-automation-only"), QA.renderAutomationHint() { return }
        let app = NSApplication.shared
        let delegate = SwitchboardApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let model = SwitchModel()
    private var statusItem: NSStatusItem!
    private var panel: BoardPanel!
    private var host: NSHostingView<BoardView>!
    private var monitor: Any?
    private var menuOpen = false
    private var lastResignClose = Date.distantPast
    private var closing: DispatchWorkItem?
    private let intro = IntroController()
    private var openedOnce = false
    private var settings: SettingsWindow?
    private var waiting = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if QA.runIfAsked() || IntroPreview.runIfAsked() || Perf.runIfAsked() || Perf.snapshotIfAsked() { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = StatusImage.make(waiting: 0)
            button.target = self
            button.action = #selector(toggle)
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        }
        model.onSummary = { [weak self] w, _ in self?.setWaiting(w) }
        makePanel()
        model.onShowBoard = { [weak self] in if self?.model.isOpen == false { self?.show() } }
        UNUserNotificationCenter.current().delegate = self
        registerHotKey()
        model.onHotKey = { [weak self] in self?.registerHotKey() }
        model.onShowIntro = { [weak self] in self?.hide(); self?.intro.show() }
        model.onSettings = { [weak self] in self?.hide(); self?.showSettings() }
        model.start()
        if !IntroController.seen, !FilmDemo.on { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in MainActor.assumeIsolated { self?.hide(); self?.intro.show() } } }
    }

    @objc func mouseEntered(_ event: NSEvent) { model.prewarm() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let id = response.notification.request.identifier
        await model.openNotification(id)
    }

    private func registerHotKey() {
        HotKeys.shared.unregister(1)
        guard let k = model.prefs.hotKey else { return }
        let f = NSEvent.ModifierFlags(rawValue: k.modifiers)
        var mods: UInt32 = 0
        if f.contains(.command) { mods |= UInt32(cmdKey) }
        if f.contains(.option) { mods |= UInt32(optionKey) }
        if f.contains(.control) { mods |= UInt32(controlKey) }
        if f.contains(.shift) { mods |= UInt32(shiftKey) }
        HotKeys.shared.register(1, .init(keyCode: UInt32(k.keyCode), modifiers: mods)) { [weak self] in self?.toggle() }
    }

    /// The icon updates on every change of the waiting count; the dot pops in when the first line starts waiting.
    private func setWaiting(_ n: Int) {
        let old = waiting
        waiting = n
        guard let b = statusItem?.button, n != old else { return }
        if old == 0, n > 0, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            Task { for p in [0.3, 1.25, 1.0] { b.image = StatusImage.make(waiting: n, pop: p); try? await Task.sleep(for: .milliseconds(55)) } }
        } else { b.image = StatusImage.make(waiting: n) }
    }


    // MARK: settings

    private func showSettings() {
        if let w = settings { NSApp.activate(); w.makeKeyAndOrderFront(nil); return }
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(KitColor.window)
        w.contentView = NSHostingView(rootView: SettingsRoot(model: model))
        w.center()
        settings = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settings = nil }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: panel

    private func makePanel() {
        panel = BoardPanel(contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: 200),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        host = NSHostingView(rootView: BoardView(model: model, onHeight: { [weak self] h in self?.resize(to: h) }))
        host.sizingOptions = []
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible, self.model.shown, !self.menuOpen else { return }
                self.lastResignClose = Date()
                self.hide()
            }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.menuOpen = false
                if self.panel.isVisible, self.model.shown, !self.panel.isKeyWindow { self.hide() }
            }
        }
        host.frame = NSRect(x: 0, y: 0, width: Layout.width, height: 300)
        host.layoutSubtreeIfNeeded()     // warm up without showing anything
    }

    private func resize(to height: CGFloat) {
        guard height > 1, let panel else { return }
        var f = panel.frame
        guard abs(f.height - height) > 0.5 else { return }
        f.origin.y += f.height - height
        f.size.height = height
        if !panel.isVisible || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(f, display: false)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(f, display: true)
            }
        }
        panel.invalidateShadow()
    }

    @objc private func toggle() {
        if intro.isShowing { hide(); intro.show(); return }    // never the intro and the panel together
        if panel.isVisible && model.shown { hide(); return }
        if Date().timeIntervalSince(lastResignClose) < 0.25 { return }
        show()
    }

    private func show() {
        guard let button = statusItem.button, let bw = button.window else { return }
        model.isOpen = true
        let b = bw.frame
        let vis = (bw.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let size = panel.frame.size
        let x = min(max(b.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: b.minY - 6 - size.height))
        closing?.cancel()
        model.counted = false
        if !openedOnce { openedOnce = true; model.pulse += 1 }
        panel.orderFrontRegardless()
        panel.makeKey()
        model.shown = true
        panel.displayIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in MainActor.assumeIsolated { if self?.model.shown == true { self?.model.counted = true } } }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func hide() {
        model.automationTarget = nil
        model.shown = false
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.panel.orderOut(nil); self?.model.counted = false } }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
        model.isOpen = false
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
}

/// The settings content with the standard entrance from the centre.
struct SettingsRoot: View {
    let model: SwitchModel
    @State private var shown = false
    var body: some View {
        SettingsView(model: model).kitPanelEntrance(shown, anchor: .center).onAppear { shown = true }
    }
}
