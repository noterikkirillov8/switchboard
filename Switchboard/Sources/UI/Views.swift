import SwiftUI

enum Layout {
    static let width: CGFloat = 440
    static let rowHeight: CGFloat = 52
    static let sectionLabel: CGFloat = 30
    static let maxList: CGFloat = 468        // nine rows, then the list scrolls
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

    private var rowCount: Int { model.needsYou.count + model.rest.count }
    private var listHeight: CGFloat {
        min(CGFloat(rowCount) * Layout.rowHeight + (model.needsYou.isEmpty ? 0 : Layout.sectionLabel), Layout.maxList)
    }

    var targetHeight: CGFloat {
        let body: CGFloat
        if !model.hasData { body = 3 * Layout.rowHeight }
        else if rowCount == 0 { body = Layout.emptyBoard }
        else { body = listHeight }
        return 52 + 1 + (model.offerVisible ? 85 : 0) + (model.automationTarget != nil ? 41 : 0) + body + 1 + 24 + 28
    }

    private var header: some View {
        let waiting = model.counted ? model.needsYou.count : 0
        let working = model.counted ? model.workingCount : 0
        let text = Plain.header(waiting: waiting, working: working, total: model.counted ? model.lines.count : 0)
        return HStack(spacing: KitSpace.m) {
            KitBadge(text: text, lit: waiting > 0 || working > 0, color: waiting > 0 ? KitColor.amber : KitColor.text2).kitRollingNumber(waiting > 0 ? waiting : working)
        }
    }

    @ViewBuilder private var content: some View {
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
        else if rowCount == 0 { EmptyBoard().frame(height: Layout.emptyBoard) }
        else {
            let needs = model.needsYou, rest = model.rest
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !needs.isEmpty {
                        HStack { Text("Needs you").font(KitFont.header).foregroundStyle(KitColor.text2); Spacer() }
                            .padding(.horizontal, KitSpace.l).frame(height: Layout.sectionLabel)
                            .overlay(alignment: .bottom) { KitDivider() }
                    }
                    ForEach(Array((needs + rest).enumerated()), id: \.element.id) { i, line in
                        RowView(model: model, line: line, index: i, forced: forceHover == line.id, last: i == needs.count + rest.count - 1)
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
                if c > 0 {
                    Text("\(model.counted ? c : 0)").kitRollingNumber(model.counted ? c : 0)
                    Text("Claude Code").foregroundStyle(KitColor.text2)
                }
                if x > 0 {
                    Text("\(model.counted ? x : 0)").kitRollingNumber(model.counted ? x : 0).padding(.leading, c > 0 ? 6 : 0)
                    Text("Codex").foregroundStyle(KitColor.text2)
                }
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

struct RowView: View {
    let model: SwitchModel
    let line: Line
    var index = 0
    var forced = false
    var last = false
    @State private var hover = false

    private var expanded: Bool { hover || forced }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Lamp(state: line.state, lit: index < model.ledsLit).padding(.trailing, 12).frame(width: 21)
                Text(line.git?.repo ?? line.project).font(KitFont.bodyMedium).foregroundStyle(KitColor.text).lineLimit(1)
                Spacer(minLength: KitSpace.s)
                StateLabel(line: line).layoutPriority(1)
                if expanded {
                    HStack(spacing: 3) {
                        KitIconButton(symbol: "arrow.up.forward.app", help: "Go to this session") { model.open(line) }.disabled(line.focusPID == nil && line.terminal.isEmpty)
                        KitIconButton(symbol: "folder", help: "Reveal folder in Finder") { model.reveal(line) }.disabled(line.cwd.isEmpty)
                    }
                    .padding(.leading, KitSpace.s)
                    .transition(.opacity.combined(with: .offset(x: 4)))
                }
            }
            if expanded {
                HStack(spacing: KitSpace.s) {
                    Text(verbatim: Plain.summary(line)).font(KitFont.detail).foregroundStyle(KitColor.text2)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    ActivityStrip(bins: line.activity, waiting: Plain.isWaiting(line), dim: line.state.isQuiet, bar: 3, gap: 1).frame(height: 14).fixedSize()
                }
                .padding(.leading, 33)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, KitSpace.l)
        .frame(height: Layout.rowHeight)
        .background(expanded ? KitColor.well : Color.clear)
        .overlay(alignment: .bottom) { if !last { KitDivider() } }
        .opacity(model.shown ? 1 : 0)
        .offset(y: model.shown ? 0 : 8)
        .animation(model.shown ? KitMotion.stagger(index) : nil, value: model.shown)
        .contentShape(Rectangle())
        .onTapGesture { model.open(line) }
        .onHover { h in withAnimation(KitMotion.soft) { hover = h } }
        .help((line.cwd as NSString).abbreviatingWithTildeInPath + "\n" + Plain.details(line, number: model.number(line)))
    }
}

/// The one plain state, on its own 30 s clock. Amber only while the session waits for an answer.
struct StateLabel: View {
    let line: Line
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            Text(Plain.state(line, now: Layout.frozen ? line.since.addingTimeInterval(180) : ctx.date))
                .font(KitFont.detail).foregroundStyle(Plain.isWaiting(line) ? KitColor.amber : line.state == .failed ? KitColor.red : KitColor.text2)
                .lineLimit(1).fixedSize()
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
        switch state { case .waitingTurn, .waitingPermission, .blocked: KitColor.amber; case .failed: KitColor.red; default: KitColor.text2 }
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

/// 12 slots of 50 s, oldest left: bar height is how busy the line was. Heights animate.
struct ActivityStrip: View {
    let bins: [Int]
    var waiting = false
    var dim = false
    var bar: CGFloat = 5
    var gap: CGFloat = 2

    var body: some View {
        let peak = CGFloat(max(bins.max() ?? 1, 6))
        HStack(alignment: .bottom, spacing: gap) {
            ForEach(0..<12, id: \.self) { i in
                let n = i < bins.count ? bins[i] : 0
                RoundedRectangle(cornerRadius: 1)
                    .fill(n == 0 ? KitColor.line : (waiting ? KitColor.amber : dim ? KitColor.text3 : KitColor.text2))
                    .frame(width: bar, height: n == 0 ? 2 : 3 + 11 * min(1, CGFloat(n) / peak))
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
                    RoundedRectangle(cornerRadius: 2).fill(KitColor.well).frame(width: 110 - CGFloat(i) * 16, height: 10)
                    Spacer()
                    RoundedRectangle(cornerRadius: 2).fill(KitColor.well).frame(width: 70, height: 8)
                }
                .padding(.horizontal, KitSpace.l)
                .frame(height: Layout.rowHeight)
                .overlay(alignment: .bottom) { if i < 2 { KitDivider() } }
            }
        }
    }
}
