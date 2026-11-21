import AppKit
import Observation
import SwiftUI

// MARK: - Scripted demo (real views, fake data, a keyframe timeline)

/// One scene's demo state. Every scene owns its own instance so a leaving scene keeps its last frame.
@MainActor
@Observable
final class Demo {
    let model = SwitchModel(live: false)
    var cursor: CGPoint?
    var pressed = false
    var hoverID: String?
    var barCount = 0
    var keysShown = false
    var focus: CGRect?           // the pool of light, in stage coordinates
    @ObservationIgnored let scene: Int
    @ObservationIgnored private let frames: [Keyframe]
    @ObservationIgnored private var done = 0
    @ObservationIgnored private var now = 0.0
    @ObservationIgnored private var pressUntil = 0.0

    struct Keyframe { let t: Double; let run: @MainActor (Demo, _ late: Double) -> Void }

    init(scene: Int) { self.scene = scene; frames = Self.script(scene); reset() }

    // The panel is drawn at 0.8 scale, top centre of a 640 x 300 stage.
    static let scale = 0.8
    static func point(_ px: Double, _ py: Double) -> CGPoint { CGPoint(x: 144 + scale * px, y: 16 + scale * py) }
    static func rowY(_ i: Int) -> Double { 47 + 56 * Double(i) + 28 }
    static func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> CGRect {
        let a = point(x0, y0), b = point(x1, y1)
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }
    static func rowRect(_ i: Int) -> CGRect { rect(0, rowY(i) - 28, 440, rowY(i) + 28) }
    static let hoverKeyX = [382.0, 411.0]   // centres of the two 26 pt keys, trailing edge at 440 - 16

    static func line(_ id: String, _ tool: Tool, _ project: String, _ model: String, _ state: LineState, mins: Double, _ act: [Int]) -> Line {
        Line(id: id, tool: tool, cwd: "/Users/you/Projects/" + project, model: model, state: state,
             since: Date().addingTimeInterval(-mins * 60), activity: act, pid: 1)
    }
    static let a1 = [1, 3, 2, 5, 4, 6, 3, 2, 7, 5, 8, 6], a2 = [0, 0, 2, 4, 1, 0, 0, 3, 6, 2, 1, 4], a3 = [0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0], a4 = [5, 4, 6, 2, 0, 0, 1, 0, 0, 0, 0, 0]
    static func fleet(waiting: Bool) -> [Line] {
        Discovery.order([
            line("c:1", .claude, "copper-shop", "Opus 4.5", .working, mins: 4, a1),
            line("c:2", .claude, "orbit", "Sonnet 5.5", waiting ? .waitingTurn : .working, mins: waiting ? 3 : 9, waiting ? a4 : a2),
            line("x:1", .codex, "paper-planes", "gpt-6.2-astra", .working, mins: 2, a2),
            line("c:3", .claude, "atlas-web", "Opus 4.5", .idle, mins: 55, a3),
        ])
    }
    static let all = fleet(waiting: false)

    func reset() {
        cursor = nil; pressed = false; hoverID = nil; barCount = 0; keysShown = false; focus = nil
        switch scene {
        case 0: model.load([])
        case 1: model.load(Self.all)
        case 2: model.load(Self.fleet(waiting: true))
        default: model.load([])
        }
    }

    /// Runs every keyframe not yet run up to `time`. The intro clock calls this; QA frames call it once with the frame time.
    func step(to time: Double) {
        now = time
        while done < frames.count, frames[done].t <= time { frames[done].run(self, time - frames[done].t); done += 1 }
        if pressed, time >= pressUntil { withAnimation(KitMotion.press) { pressed = false } }
    }
    func jump(to time: Double) { step(to: time) }

    func move(_ p: CGPoint?) { withAnimation(KitMotion.list) { cursor = p } }
    func light(_ r: CGRect?) { withAnimation(KitMotion.list) { focus = r } }
    func click() {
        withAnimation(KitMotion.press) { pressed = true }
        pressUntil = now + 0.16
    }

    static func script(_ scene: Int) -> [Keyframe] {
        switch scene {
        case 0:   // lines light up as agents start
            var kfs: [Keyframe] = [Keyframe(t: 0.1) { d, _ in d.light(rect(0, 0, 440, 46)) },
                                   Keyframe(t: 0.45) { d, _ in d.light(rect(0, 47, 440, 271)) }]
            let order = ["c:1", "c:2", "x:1", "c:3"]
            for n in 1...4 {
                kfs.append(Keyframe(t: 0.5 + 0.8 * Double(n - 1)) { d, _ in
                    let ids = Set(order.prefix(n)); d.model.load(all.filter { ids.contains($0.id) })
                })
            }
            return kfs
        case 1:   // a lamp turns amber and slides to the top
            return [
                Keyframe(t: 0.2) { d, _ in d.light(rect(0, 47, 112, 271)) },
                Keyframe(t: 1.0) { d, _ in d.light(rowRect(1)) },
                Keyframe(t: 1.6) { d, _ in d.model.load(fleet(waiting: true)); d.light(rowRect(0)) },
                Keyframe(t: 2.8) { d, _ in d.light(rect(0, 0, 440, 46)) },
            ]
        case 2:   // hover keys jump to the waiting line
            return [
                Keyframe(t: 0.3) { d, _ in d.cursor = Demo.point(440, 330) },
                Keyframe(t: 0.5) { d, _ in d.move(Demo.point(230, rowY(0))); d.light(rowRect(0)) },
                Keyframe(t: 1.1) { d, _ in withAnimation(KitMotion.soft) { d.hoverID = "c:2" } },
                Keyframe(t: 1.7) { d, _ in d.move(Demo.point(hoverKeyX[0], rowY(0))); d.light(rect(364, rowY(0) - 20, 428, rowY(0) + 20)) },
                Keyframe(t: 2.4) { d, _ in d.click() },
                Keyframe(t: 3.0) { d, _ in d.move(Demo.point(hoverKeyX[1], rowY(0))) },
                Keyframe(t: 3.5) { d, _ in d.click() },
            ]
        default:  // the menu bar icon with the waiting dot, and the hot key
            return [
                Keyframe(t: 0.1) { d, _ in d.light(CGRect(x: 200, y: 50, width: 240, height: 120)) },
                Keyframe(t: 0.5) { d, _ in d.barCount = 1 }, Keyframe(t: 1.3) { d, _ in d.barCount = 2 },
                Keyframe(t: 2.4) { d, _ in withAnimation(KitMotion.list) { d.keysShown = true }; d.light(CGRect(x: 190, y: 182, width: 260, height: 40)) },
            ]
        }
    }
}

// MARK: - Intro model

@MainActor
@Observable
final class IntroModel {
    static let titles = ["Every session on one board", "Amber means it needs you", "Jump straight to it", "Always one click away"]
    static let lines = [
        "Each Claude Code and Codex session gets a line and lights up when it starts.",
        "A lamp blinks amber when a session asks permission or finishes and waits. It moves to the top.",
        "Hover a line to bring its app to the front or reveal the folder.",
        "A dot and a count in the menu bar tell you when something waits. Nothing leaves your Mac.",
    ]
    static let sceneSeconds = 4.6

    var scene: Int
    var demos: [Int: Demo] = [:]
    @ObservationIgnored var flow = IntroFlow(durations: Array(repeating: IntroModel.sceneSeconds, count: IntroModel.titles.count))
    @ObservationIgnored var onClose: () -> Void = {}
    @ObservationIgnored private var timer: Timer?

    init(scene: Int = 0, preview: Demo? = nil) {
        self.scene = scene
        if let preview { demos[scene] = preview }
    }

    var isLast: Bool { scene == Self.titles.count - 1 }

    /// The one clock: a 30 Hz timer drives auto-advance and every keyframe of the current scene.
    func start() {
        flow = IntroFlow(durations: flow.durations, now: CACurrentMediaTime())
        demos[0] = Demo(scene: 0)
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    func tick() {
        let now = CACurrentMediaTime()
        flow.tick(now: now)
        sync()
        demos[scene]?.step(to: flow.time(now: now))
    }

    func next() { flow.next(now: CACurrentMediaTime()); sync() }
    func back() { flow.back(now: CACurrentMediaTime()); sync() }
    /// Skip and Get started.
    func finish() { flow.close(); sync() }

    private func sync() {
        if flow.closed { stop(); onClose(); return }
        guard flow.scene != scene else { return }
        demos[flow.scene] = Demo(scene: flow.scene)
        withAnimation(KitMotion.list) { scene = flow.scene }
    }
}

// MARK: - Views

struct IntroView: View {
    let intro: IntroModel
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if let demo = intro.demos[intro.scene] {
                    IntroStage(demo: demo, scene: intro.scene)
                        .id(intro.scene)
                        .transition(reduce ? .opacity : .asymmetric(insertion: .offset(x: 24).combined(with: .opacity),
                                                                    removal: .offset(x: -24).combined(with: .opacity)))
                }
            }
            .frame(width: 640, height: 300)
            .background(KitColor.well)
            .clipped()
            .overlay(alignment: .bottom) { KitDivider() }

            VStack(spacing: 6) {
                Text(IntroModel.titles[intro.scene]).font(.system(size: 17, weight: .semibold)).foregroundStyle(KitColor.text)
                Text(IntroModel.lines[intro.scene]).font(KitFont.body).foregroundStyle(KitColor.text2)
            }
            .id(intro.scene)
            .transition(.opacity)
            .frame(maxWidth: .infinity, minHeight: 78)
            .padding(.top, KitSpace.m)

            Spacer(minLength: 0)
            HStack {
                Button("Skip") { intro.finish() }.buttonStyle(.kitQuiet).focusable(false)
                Spacer()
                HStack(spacing: 8) { ForEach(0..<IntroModel.titles.count, id: \.self) { KitLed(on: $0 == intro.scene) } }
                Spacer()
                if intro.isLast { Button("Get started") { intro.finish() }.buttonStyle(.kitPrimary).focusable(false) }
                else { Button("Next") { intro.next() }.buttonStyle(.kitSecondary).focusable(false) }
            }
            .padding(.horizontal, KitSpace.l)
            .frame(height: 60)
        }
        .frame(width: 640, height: 440)
        .background(KitColor.window)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(KitColor.line, lineWidth: 1))
        .kitAccent(boardAccent)
    }
}

/// The stage dims to 45% except a crisp pool of light cut exactly to the focused element's rounded rect
/// (4 pt padding, 1 pt edge softening), with a 1 px accent hairline. The pool is clipped to the stage.
struct Spotlight: View {
    let rect: CGRect?
    let reduce: Bool
    var stage = CGSize(width: 640, height: 300)
    var radius: CGFloat = 8
    @Environment(\.kitAccent) private var accent
    var body: some View {
        let r = rect ?? CGRect(x: stage.width / 2, y: stage.height / 2, width: 0, height: 0)
        ZStack {
            SpotShape(x: r.minX - 4, y: r.minY - 4, w: r.width + 8, h: r.height + 8, radius: radius + 4, stage: stage)
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .blur(radius: 1)
            SpotShape(x: r.minX - 4, y: r.minY - 4, w: r.width + 8, h: r.height + 8, radius: radius + 4, stage: stage, ring: true)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        }
        .frame(width: stage.width, height: stage.height)
        .clipped()
        .opacity(rect == nil ? 0 : 1)
        .animation(reduce ? nil : KitMotion.list, value: r)
        .animation(KitMotion.soft, value: rect == nil)
        .allowsHitTesting(false)
    }
}

struct SpotShape: Shape {
    var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    var radius: CGFloat = 12
    var stage = CGSize(width: 640, height: 300)
    var ring = false
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(x, y), .init(w, h)) }
        set { x = newValue.first.first; y = newValue.first.second; w = newValue.second.first; h = newValue.second.second }
    }
    func path(in _: CGRect) -> Path {
        var p = Path()
        let hole = CGRect(x: x, y: y, width: max(w, 0), height: max(h, 0)).intersection(CGRect(origin: .zero, size: stage))
        if !ring { p.addRect(CGRect(x: -4, y: -4, width: stage.width + 8, height: stage.height + 8)) }   // overshoot so the blur never lightens the stage edge
        if !hole.isNull { p.addRoundedRect(in: hole, cornerSize: CGSize(width: radius, height: radius)) }
        return p
    }
}


struct IntroStage: View {
    let demo: Demo
    let scene: Int
    @Environment(\.accessibilityReduceMotion) private var reduce

    var body: some View {
        ZStack(alignment: .top) {
            if scene < 3 {
                BoardView(model: demo.model, forceHover: demo.hoverID)
                    .frame(width: Layout.width, height: 400, alignment: .top)
                    .scaleEffect(Demo.scale, anchor: .top)
                    .offset(y: 16)
                    .allowsHitTesting(false)
                Spotlight(rect: demo.focus, reduce: reduce)
                if let c = demo.cursor { GhostCursor(pressed: demo.pressed).position(c).transition(.opacity)
                    .animation(reduce ? nil : KitMotion.list, value: c) }
            } else {
                MenuBarScene(demo: demo)
                Spotlight(rect: demo.focus, reduce: reduce)
            }
        }
        .frame(width: 640, height: 300, alignment: .top)
    }
}

struct GhostCursor: View {
    var pressed: Bool
    var body: some View {
        Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 17)); p.addLine(to: CGPoint(x: 4.5, y: 13))
            p.addLine(to: CGPoint(x: 7.5, y: 19.5)); p.addLine(to: CGPoint(x: 10, y: 18.5)); p.addLine(to: CGPoint(x: 7, y: 12))
            p.addLine(to: CGPoint(x: 12.5, y: 12)); p.closeSubpath()
        }
        .fill(KitColor.text)
        .overlay(Path { p in
            p.move(to: .zero); p.addLine(to: CGPoint(x: 0, y: 17)); p.addLine(to: CGPoint(x: 4.5, y: 13))
            p.addLine(to: CGPoint(x: 7.5, y: 19.5)); p.addLine(to: CGPoint(x: 10, y: 18.5)); p.addLine(to: CGPoint(x: 7, y: 12))
            p.addLine(to: CGPoint(x: 12.5, y: 12)); p.closeSubpath()
        }.stroke(KitColor.window, lineWidth: 1))
        .frame(width: 13, height: 20, alignment: .topLeading)
        .scaleEffect(pressed ? 0.85 : 1, anchor: .topLeading)
        .offset(x: 6, y: 9)    // the arrow tip sits on the position
    }
}

/// The menu bar key, drawn big, with the count rolling, and the hot key.

/// The menu bar icon drawn big: three jacks, and when something waits a dot and the count. Then the hot key.
struct MenuBarScene: View {
    let demo: Demo
    var body: some View {
        VStack(spacing: 28) {
            HStack(spacing: 14) {
                HStack(spacing: 10) {
                    ForEach(0..<3, id: \.self) { _ in Circle().strokeBorder(KitColor.text, lineWidth: 5).frame(width: 30, height: 30) }
                }
                if demo.barCount > 0 {
                    HStack(spacing: 8) {
                        Circle().fill(KitColor.text).frame(width: 18, height: 18)
                        Text("\(demo.barCount)").font(KitFont.figure(46, .semibold)).foregroundStyle(KitColor.text).kitRollingNumber(demo.barCount)
                    }
                    .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .frame(height: 60)
            .animation(KitMotion.press, value: demo.barCount > 0)
            HStack(spacing: 12) {
                KitKeycaps(keys: "⌥⌘B")
                Text("opens Switchboard from anywhere").font(KitFont.body).foregroundStyle(KitColor.text2)
            }
            .opacity(demo.keysShown ? 1 : 0)
            .offset(y: demo.keysShown ? 0 : 8)
        }
        .padding(.top, 62)
    }
}

// MARK: - Window

@MainActor
final class IntroController {
    static let seenKey = "switchboardIntroSeen"
    static var seen: Bool { UserDefaults.standard.bool(forKey: seenKey) }

    private let presenter = IntroPresenter()
    private var intro: IntroModel?
    var isShowing: Bool { presenter.isShowing }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)    // seen as soon as it is shown: a failed intro never repeats
        if presenter.isShowing { presenter.focus(); return }
        let m = IntroModel()
        intro = m
        m.onClose = { [weak self] in self?.presenter.close() }
        presenter.onClose = { [weak m] in m?.finish() }
        presenter.onNext = { [weak m] in m?.next() }
        presenter.onBack = { [weak m] in m?.back() }
        presenter.show(IntroView(intro: m), size: CGSize(width: 640, height: 440))
        m.start()
    }
}
