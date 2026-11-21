import SwiftUI

enum Layout {
    static let width: CGFloat = 440
    static let rowHeight: CGFloat = 56
    static let maxList: CGFloat = 448        // eight rows, then the list scrolls
    static let sideColumn: CGFloat = 84      // activity strip, or the two hover keys
    static let emptyBoard: CGFloat = 196
    /// QA: stop animations so a frame can be captured at a fixed progress.
    nonisolated(unsafe) static var frozen = false
}

struct Entrance: ViewModifier {
    var shown: Bool
    @Environment(\.accessibilityReduceMotion) private var reduce
    func body(content: Content) -> some View {
        if reduce { content.opacity(shown ? 1 : 0).animation(KitMotion.soft, value: shown) } else { content.kitPanelEntrance(shown) }
    }
}

let boardAccent = Color(hex: 0x8AA4C8)
let accurateLampDetail = "Adds a small hook to Claude Code and Codex so Switchboard knows exactly when they wait for you."

struct AutomationHint: View {
    let proceed: () -> Void

    var body: some View {
        HStack {
            Text("Allow Automation so Switchboard can select this tab.").font(KitFont.detail).foregroundStyle(KitColor.text2)
            Spacer()
            Button("Continue", action: proceed).buttonStyle(.kitSecondary)
        }
        .padding(.horizontal, KitSpace.l).frame(height: 40)
    }
}

struct NeedsInboxView: View {
    let items: [NeedsInbox.Item]
    let now: Date
    let open: (Line) -> Void

    static func height(_ count: Int) -> CGFloat { count == 0 ? 0 : 31 + CGFloat(min(count, 3)) * 32 + 1 }

    var body: some View {
        VStack(spacing: 0) {
            Text("Needs you").font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, KitSpace.l).frame(height: 31)
            if items.count > 3 { ScrollView { rows }.frame(height: 96) } else { rows }
            KitDivider()
        }
        .background(KitColor.well)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                Button { open(item.line) } label: {
                    HStack(spacing: KitSpace.s) {
                        KitLed(on: item.kind != .unknown, color: KitColor.amber, size: 6)
                        Text(item.line.project).font(KitFont.bodyMedium).foregroundStyle(KitColor.text).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(item.kind.rawValue).fixedSize()
                        Text(Transcript.duration(now.timeIntervalSince(item.line.since))).monospacedDigit().frame(minWidth: 55, alignment: .trailing)
                    }
                    .font(KitFont.detail).foregroundStyle(KitColor.text2)
                    .padding(.horizontal, KitSpace.l).frame(height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Go to this session")
            }
        }
    }
}

struct BoardView: View {
    let model: SwitchModel
    var forceHover: String?
    var onHeight: (CGFloat) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        KitPanel(title: "Switchboard", width: Layout.width) {
            header
        } content: {
            content
        } footer: {
            footer
        }
        .kitAccent(boardAccent)
        .overlay(alignment: .top) { PowerLine(trigger: model.pulse, preview: model.pulsePreview).padding(.top, 52) }
        .modifier(Entrance(shown: model.shown))
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: targetHeight, initial: true) { _, h in onHeight(h) }
    }

    private var inboxHeight: CGFloat { NeedsInboxView.height(model.inbox.items.count) }
    private var listHeight: CGFloat { min(CGFloat(model.visible.count) * Layout.rowHeight, Layout.maxList - inboxHeight) }

    var targetHeight: CGFloat {
        let body: CGFloat
        if !model.hasData { body = 3 * Layout.rowHeight }
        else if model.visible.isEmpty && inboxHeight == 0 { body = Layout.emptyBoard }
        else { body = listHeight }
        return 52 + 1 + inboxHeight + (model.offerVisible ? 85 : 0) + (model.automationTarget != nil ? 41 : 0) + body + 1 + 24 + 28
    }

    private var header: some View {
        let w = model.counted ? model.waitingCount : 0
        let working = model.counted ? model.workingCount : 0
        return HStack(spacing: KitSpace.m) {
            if w > 0 {
                KitBadge(text: "\(w) waiting", lit: true, color: KitColor.amber).kitRollingNumber(w)
            } else {
                KitBadge(text: "\(working) working", lit: working > 0).kitRollingNumber(working)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !model.inbox.items.isEmpty {
            TimelineView(.periodic(from: .now, by: 15)) { clock in
                NeedsInboxView(items: model.inbox.items, now: clock.date, open: model.open)
            }
        }
        if model.automationTarget != nil {
            AutomationHint(proceed: model.continueFocus)
            KitDivider()
        }
        if model.offerVisible {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: KitSpace.m) {
                    Text("Turn on accurate lamps").font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
                    Spacer()
                    Button("Not now") { model.lampOffer.deferForWeek() }.buttonStyle(.plain).font(KitFont.detail).foregroundStyle(KitColor.text2)
                    Button("Turn on") { model.preciseSwitch(true) }.buttonStyle(.kitPrimary)
                }
                Text(model.preciseError ?? accurateLampDetail).font(KitFont.detail).foregroundStyle(KitColor.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, KitSpace.l)
            .frame(height: 84)
            KitDivider()
        }
        if !model.hasData { Skeleton() }
        else if model.visible.isEmpty && inboxHeight == 0 { EmptyBoard().frame(height: Layout.emptyBoard) }
        else if !model.visible.isEmpty {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.visible.enumerated()), id: \.element.id) { i, line in
                        RowView(model: model, line: line, index: i, forced: forceHover == line.id, last: i == model.visible.count - 1)
                            .transition(rowTransition)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(height: listHeight)
        }
    }

    private var rowTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: AnyTransition(Collapse()))
    }

    private var footer: some View {
        let c = model.lines.filter { $0.tool == .claude }.count, x = model.lines.filter { $0.tool == .codex }.count
        return HStack(spacing: KitSpace.s) {
            HStack(spacing: 6) {
                Text("\(model.counted ? c : 0)").kitRollingNumber(model.counted ? c : 0)
                Text("Claude Code").foregroundStyle(KitColor.text2)
                Text("\(model.counted ? x : 0)").kitRollingNumber(model.counted ? x : 0).padding(.leading, 6)
                Text("Codex").foregroundStyle(KitColor.text2)
            }
            .font(.system(size: 11).monospacedDigit()).foregroundStyle(KitColor.text2)
            Spacer()
            MoreMenu(model: model)
        }
        .frame(height: 28)
    }
}

/// First open of a session: the hairline under the title lights in the accent from the centre outward.
struct PowerLine: View {
    let trigger: Int
    var preview: Double? = nil
    @State private var width = 0.0
    @State private var alpha = 0.0
    @Environment(\.kitAccent) private var accent

    var body: some View {
        Rectangle().fill(accent).frame(height: 1)
            .scaleEffect(x: preview ?? width, y: 1)
            .opacity(preview == nil ? alpha : 1)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                width = 0; alpha = 1
                withAnimation(.easeOut(duration: 0.25)) { width = 1 }
                Task { try? await Task.sleep(for: .milliseconds(250)); withAnimation(KitMotion.soft) { alpha = 0 } }
            }
    }
}

struct Collapse: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        let t = phase == .didDisappear ? 1.0 : 0.0
        content.frame(height: Layout.rowHeight * (1 - t), alignment: .top).clipped().opacity(1 - t)
    }
}

// MARK: - Row

enum StateText {
    static func word(_ s: LineState, reported: Bool) -> String {
        switch s {
        case .longStep: "Running a long step"
        case .working: "working"; case .waitingTurn: reported ? "Your turn" : "waiting"; case .waitingPermission: reported ? "Needs permission" : "approval"
        case .idle: "idle"; case .exited: "exited"; case .blocked: "Blocked"; case .done: "Done"; case .failed: "Failed"; case .stopped: "Stopped"; case .unknown: "Unknown"
        }
    }
    static func color(_ s: LineState) -> Color {
        switch s { case .waitingTurn, .waitingPermission, .blocked: KitColor.amber; case .exited, .failed: KitColor.red; default: KitColor.text2 }
    }
    static func text(_ s: LineState, since: Date, now: Date, reported: Bool) -> String {
        let d = now.timeIntervalSince(since)
        let label = word(s, reported: reported)
        return d < 60 || s == .longStep ? label : label + " " + Transcript.duration(d)
    }
}

struct RowView: View {
    let model: SwitchModel
    let line: Line
    var index = 0
    var forced = false
    var last = false
    @State private var hover = false
    @Environment(\.kitAccent) private var accent

    private var showKeys: Bool { hover || forced }

    var body: some View {
        HStack(spacing: 0) {
            Lamp(state: line.state, lit: index < model.ledsLit).padding(.trailing, 12).frame(width: 21)
            Jack(number: model.number(line), raised: showKeys).padding(.trailing, 12)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(line.git?.repo ?? line.project).font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
                    if let git = line.git {
                        Image(systemName: "arrow.triangle.branch").accessibilityHidden(true)
                        Text(verbatim: git.branch).truncationMode(.middle)
                        if git.worktree { Text("· worktree").fixedSize() }
                    }
                }
                .font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1)
                Detail(line: line)
                let metadata = [line.git != nil ? line.agent?.name : nil, line.model, line.cliVersion.map { "CLI \($0)" }].compactMap { $0 }.joined(separator: " · ")
                if !metadata.isEmpty { Text(verbatim: metadata).font(KitFont.detail).foregroundStyle(KitColor.text2).lineLimit(1) }
            }
            Spacer(minLength: KitSpace.s)
            ZStack(alignment: .trailing) {
                if showKeys {
                    HStack(spacing: 3) {
                        KitIconButton(symbol: "arrow.up.forward.app", help: "Go to this session") { model.open(line) }.disabled(line.focusPID == nil && line.terminal.isEmpty)
                        KitIconButton(symbol: "folder", help: "Reveal folder in Finder") { model.reveal(line) }.disabled(line.cwd.isEmpty)
                    }
                    .transition(.opacity.combined(with: .offset(x: 4)))
                } else {
                    VStack(alignment: .trailing, spacing: 6) {
                        ActivityStrip(bins: model.counted ? line.activity : Array(repeating: 0, count: 12), waiting: line.state.isWaiting, dim: line.state.isQuiet)
                            .frame(width: 82, height: 14)
                        let n = line.activity.reduce(0, +)
                        Text("\(model.counted ? n : 0) \(n == 1 ? "event" : "events")").font(.system(size: 11).monospacedDigit()).foregroundStyle(KitColor.text2)
                            .kitRollingNumber(model.counted ? n : 0).lineLimit(1).fixedSize()
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: Layout.sideColumn, alignment: .trailing)
        }
        .padding(.horizontal, KitSpace.l)
        .frame(height: Layout.rowHeight)
        .background(showKeys ? KitColor.well : Color.clear)
        .overlay(alignment: .bottom) { if !last { KitDivider() } }
        .opacity(model.shown ? 1 : 0)
        .offset(y: model.shown ? 0 : 8)
        .animation(model.shown ? KitMotion.stagger(index) : nil, value: model.shown)
        .contentShape(Rectangle())
        .onTapGesture { model.open(line) }
        .onHover { h in withAnimation(KitMotion.soft) { hover = h } }
        .help((line.cwd as NSString).abbreviatingWithTildeInPath)
    }
}

/// The state ticks on its own 30 s clock.
struct Detail: View {
    let line: Line
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            (Text(line.tool.title + ", ").foregroundStyle(KitColor.text2)
             + Text(StateText.text(line.state, since: line.since, now: Layout.frozen ? line.since.addingTimeInterval(180) : ctx.date, reported: line.fromHook || line.agent != nil)).foregroundStyle(StateText.color(line.state)))
                .font(KitFont.detail).lineLimit(1)
        }
    }
}

/// The lamp: amber and blinking at 1 Hz when the line waits, steady accent when working, unlit when idle, red when exited.
/// When a line starts waiting its lamp flickers on first.
struct Lamp: View {
    let state: LineState
    var lit = true
    @State private var flick = false
    @Environment(\.kitAccent) private var accent

    private var color: Color {
        switch state { case .waitingTurn, .waitingPermission, .blocked: KitColor.amber; case .exited, .failed: KitColor.red; default: accent }
    }

    var body: some View {
        Group {
            if state.isWaiting && !Layout.frozen {
                TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 0.5)) { ctx in
                    let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
                    KitLed(on: lit && phase && !flick, color: color, size: 9).animation(KitMotion.soft, value: phase)
                }
            } else {
                KitLed(on: lit && !state.isQuiet && state != .stopped && state != .unknown, color: color, size: 9)
            }
        }
        .animation(KitMotion.soft, value: state)
        .onChange(of: state.isWaiting) { _, w in
            guard w, !Layout.frozen else { return }
            Task { for v in [true, false, true, false] { flick = v; try? await Task.sleep(for: .milliseconds(46)) } }
        }
    }
}

/// The jack label: the line number as a plain figure. It stays with the line when rows move.
struct Jack: View {
    let number: Int
    var raised = false
    var body: some View {
        Text(String(format: "%02d", number))
            .font(KitFont.figure(17)).foregroundStyle(KitColor.text)
            .lineLimit(1).frame(width: 44, alignment: .leading)
    }
}

/// 12 slots of 50 s, oldest left: bar height is how busy the line was. Heights animate.
struct ActivityStrip: View {
    let bins: [Int]
    var waiting = false
    var dim = false
    @Environment(\.kitAccent) private var accent

    var body: some View {
        let peak = CGFloat(max(bins.max() ?? 1, 6))
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<12, id: \.self) { i in
                let n = i < bins.count ? bins[i] : 0
                RoundedRectangle(cornerRadius: 1)
                    .fill(n == 0 ? KitColor.line : (waiting ? KitColor.amber : dim ? KitColor.text3 : accent))
                    .frame(width: 5, height: n == 0 ? 2 : 3 + 11 * min(1, CGFloat(n) / peak))
            }
        }
        .animation(Layout.frozen ? nil : KitMotion.list, value: bins)
    }
}

struct MoreMenu: View {
    let model: SwitchModel
    @State private var hover = false
    var body: some View {
        Menu {
            Button("Settings…") { model.onSettings() }.keyboardShortcut(",")
            Button("Show intro") { model.onShowIntro() }
            Divider()
            Button("Quit Switchboard") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? KitColor.text : KitColor.text2)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: KitSpace.controlRadius).fill(hover ? KitColor.well : .clear))
                .overlay(RoundedRectangle(cornerRadius: KitSpace.controlRadius).strokeBorder(hover ? KitColor.line : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .onHover { hover = $0 }
    }
}

struct EmptyBoard: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("0").font(KitFont.figure(56, .semibold)).foregroundStyle(KitColor.text3)
            Text("No agent sessions").font(KitFont.bodyMedium).foregroundStyle(KitColor.text)
            Text("Start Claude Code or Codex and it shows up here.").font(KitFont.detail).foregroundStyle(KitColor.text2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 32)
    }
}

struct Skeleton: View {
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 0) {
                    KitLed(on: false, size: 9).padding(.trailing, 12).frame(width: 21)
                    RoundedRectangle(cornerRadius: 3).fill(KitColor.well).frame(width: 28, height: 16).frame(width: 44, alignment: .leading).padding(.trailing, 12)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(KitColor.well).frame(width: 110 - CGFloat(i) * 16, height: 10)
                        RoundedRectangle(cornerRadius: 2).fill(KitColor.well).frame(width: 150, height: 8)
                    }
                    Spacer()
                    ActivityStrip(bins: Array(repeating: 0, count: 12)).frame(width: 82, height: 14)
                }
                .padding(.horizontal, KitSpace.l)
                .frame(height: Layout.rowHeight)
                .overlay(alignment: .bottom) { if i < 2 { KitDivider() } }
            }
        }
    }
}
