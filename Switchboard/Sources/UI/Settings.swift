import SwiftUI

enum SettingsTab: String { case general, sources, alerts, about }

struct SettingsView: View {
    let model: SwitchModel
    @Bindable var prefs: Prefs
    var tabOverride: SettingsTab?
    @State private var selection: SettingsTab = .general

    init(model: SwitchModel, tab: SettingsTab? = nil) {
        self.model = model; self.prefs = model.prefs; self.tabOverride = tab
        _selection = State(initialValue: tab ?? SettingsTab(rawValue: model.prefs.tab) ?? .general)
    }

    var body: some View {
        KitSettings(title: "Switchboard settings", tabs: [(.general, "General"), (.sources, "Sources"), (.alerts, "Alerts"), (.about, "About")],
                    selection: $selection) { tab in
            switch tab {
            case .general: general
            case .sources: sources
            case .alerts: alerts
            case .about: KitAboutView(name: "Switchboard", tagline: "Every Claude Code and Codex session on one board, and which ones wait for you.",
                                      repoURL: URL(string: "https://github.com/noterikkirillov8/switchboard"))
            }
        }
        .kitAccent(boardAccent)
        .onChange(of: selection) { _, t in if tabOverride == nil { prefs.tab = t.rawValue } }
    }

    @ViewBuilder private var general: some View {
        KitSection(title: "Startup") {
            KitToggleRow(title: "Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            KitRow(title: "Open the board", detail: "Works from any app") {
                KitHotKeyField(hotKey: $prefs.hotKey).onChange(of: prefs.hotKey) { _, _ in model.onHotKey() }
            }
            KitRow(title: "Intro") { Button("Show intro") { model.onShowIntro() }.buttonStyle(.kitSecondary) }
        }
        KitSoundSection()
    }

    @ViewBuilder private var sources: some View {
        KitSection(title: "Folders", footer: "Switchboard only reads the end of each transcript, on this Mac. Nothing is uploaded or logged.") {
            sourceRow("Claude Code", "~/.claude/projects", exists: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.claude/projects"))
            sourceRow("Codex", "~/.codex/sessions", exists: FileManager.default.fileExists(atPath: NSHomeDirectory() + "/.codex/sessions"))
        }
        KitSection(title: "Board") {
            KitToggleRow(title: "Show idle lines", detail: "Sessions that finished a while ago", isOn: $prefs.showIdle)
        }
        KitSection(title: "Lamps", footer: "Existing files are backed up first. Turning this off removes only Switchboard’s hooks.") {
            KitToggleRow(title: "Accurate lamps", detail: accurateLampDetail,
                         isOn: Binding(get: { model.preciseOn }, set: { model.preciseSwitch($0) }))
        }
        if let e = model.preciseError { Text(e).font(KitFont.detail).foregroundStyle(KitColor.red) }
    }

    private func sourceRow(_ name: String, _ path: String, exists: Bool) -> some View {
        KitRow(title: name, detail: path) {
            HStack(spacing: 6) { KitLed(on: exists); Text(exists ? "Found" : "Not found").font(KitFont.key).foregroundStyle(KitColor.text2) }
        }
    }

    @ViewBuilder private var alerts: some View {
        KitSection(title: "When a line starts waiting", footer: "At most one notification per line every 5 minutes. macOS asks for permission when you turn notifications on.") {
            KitToggleRow(title: "Notification", detail: "\"orbit is waiting for you\"", isOn: Binding(get: { prefs.notify }, set: { model.setNotify($0) }))
            KitToggleRow(title: "Play a chime", isOn: $prefs.soundOnWaiting)
        }
        KitSection(title: "Quiet hours", footer: "No notifications or chimes in this window.") {
            KitToggleRow(title: "Quiet hours", isOn: $prefs.quiet)
            KitRow(title: "From") { KitStepper(value: $prefs.quietFrom, range: 0...23, format: Self.hour) }.disabled(!prefs.quiet)
            KitRow(title: "To") { KitStepper(value: $prefs.quietTo, range: 0...23, format: Self.hour) }.disabled(!prefs.quiet)
        }
    }

    static func hour(_ h: Int) -> String { String(format: "%02d:00", h) }
}

