import AppKit
import QuartzCore
import SwiftUI

/// Transparent AppKit markers on each lyric row and on the pill. SwiftUI places
/// them with the same animated geometry it draws with, so their layers show
/// where a row or the pill really is on every frame, scroll included.
struct LyricsFollowProbe: NSViewRepresentable {
    enum Kind: Equatable { case row(Int), pill(Int) }
    let kind: Kind

    func makeNSView(context: Context) -> Marker { Marker(kind: kind) }
    func updateNSView(_ view: Marker, context: Context) { view.kind = kind }

    final class Marker: NSView {
        var kind: Kind
        init(kind: Kind) {
            self.kind = kind
            super.init(frame: .zero)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// One sampled frame, in the scroll viewport's coordinates (y down).
struct Sample {
    let time: Double
    let rows: [Int: CGRect]
    /// Every pill drawn; more than one apart would be a box with no line under it.
    let pills: [(id: Int, frame: CGRect)]
    var pillIDs: Set<Int> { Set(pills.map(\.id)) }
    var split: Bool {
        pills.contains { Judge.offset($0.frame, pills[0].frame) > 1 }
    }
    var pill: CGRect? { split ? nil : pills.first?.frame }
}

/// The real `LyricsView` in an offscreen window, driven by a synthetic clock.
@MainActor final class Rig {
    let player = PlayerModel(), lyrics = LyricsModel()
    let lines: [LyricLine]
    let window: OffscreenWindow
    let host: NSHostingView<AnyView>
    let label: String

    init(size: CGSize, lines: [LyricLine], label: String) {
        self.lines = lines
        self.label = label
        player.isPlaying = false
        lyrics.state = .loaded(.synced(lines))
        window = OffscreenWindow(contentRect: CGRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: AnyView(LyricsView().environment(player).environment(lyrics)
            .environment(\.interfaceScale, .standard).preferredColorScheme(.dark)
            .background(Color(red: 0.04, green: 0.05, blue: 0.065))))
        window.contentView = host
        window.orderFrontRegardless()
    }

    var scrollView: NSScrollView? { Self.first(NSScrollView.self, in: host) }
    var viewport: CGRect { scrollView.map(frame) ?? .null }
    /// Where the current line's own 40% point rests.
    var anchorY: CGFloat { viewport.height * 0.4 }

    static func first<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = first(type, in: child) { return match } }
        return nil
    }

    static func markers(in view: NSView, into result: inout [LyricsFollowProbe.Marker]) {
        if let marker = view as? LyricsFollowProbe.Marker { result.append(marker) }
        for child in view.subviews { markers(in: child, into: &result) }
    }

    /// Through the presentation layers, so in-flight geometry counts.
    func frame(_ view: NSView) -> CGRect {
        guard let layer = view.layer, let root = host.layer else { return .null }
        let presented = layer.presentation() ?? layer
        return presented.convert(presented.bounds, to: root.presentation() ?? root)
    }

    func sample(at time: Double) -> Sample {
        var found: [LyricsFollowProbe.Marker] = []
        Self.markers(in: host, into: &found)
        let origin = viewport.origin
        var rows: [Int: CGRect] = [:], pills: [(Int, CGRect)] = []
        for marker in found where !marker.isHiddenOrHasHiddenAncestor {
            let rect = frame(marker).offsetBy(dx: -origin.x, dy: -origin.y)
            switch marker.kind {
            case let .row(id): rows[id] = rect
            case let .pill(id): pills.append((id, rect))
            }
        }
        return Sample(time: time, rows: rows, pills: pills)
    }

    /// Samples every few milliseconds, so every display frame is seen.
    func record(for seconds: Double, after action: () -> Void) async -> [Sample] {
        var samples = [sample(at: 0)]
        action()
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            try? await Task.sleep(for: .milliseconds(3))
            samples.append(sample(at: Date().timeIntervalSince(start)))
        }
        return samples
    }

    func settle(_ seconds: Double = 0.8) async { try? await Task.sleep(for: .seconds(seconds)) }

    /// Paused just after the line's tag.
    func pause(onLine index: Int) {
        player.isPlaying = false
        player.seek(toMs: (lines[index].time + 0.5) * 1_000)
    }

    /// Playing, a quarter second before the line becomes current by itself.
    func play(intoLine index: Int) {
        player.isPlaying = true
        player.seek(toMs: (lines[index].time - 0.15 - 0.25) * 1_000)
    }

    func stop() {
        let now = player.positionMs(at: Date())
        player.isPlaying = false
        player.seek(toMs: now)
    }

    /// A trackpad drag as AppKit reports it: a live scroll in small steps
    /// until the line under the anchor is `count` lines from `line`.
    /// (Synthetic wheel events don't scroll an offscreen window.)
    @discardableResult
    func drag(lines count: Int, from line: Int, towardStart: Bool) async -> Int {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let center = NotificationCenter.default
        center.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        var moved = 0
        for _ in 0..<400 {
            let clip = scrollView.contentView
            let limit = max(0, document.frame.height - clip.bounds.height)
            let y = min(max(clip.bounds.origin.y + (towardStart ? -40 : 40), 0), limit)
            clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: y))
            scrollView.reflectScrolledClipView(clip)
            center.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
            try? await Task.sleep(for: .milliseconds(8))
            let now = sample(at: 0)
            if let under = now.rows.first(where: { $0.value.minY <= anchorY && $0.value.maxY >= anchorY })?.key {
                moved = abs(under - line)
                if moved >= count { break }
            }
            if y == 0 || y == limit { break }
        }
        center.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        await settle(0.4)
        return moved
    }

    /// Clicks where the Follow button floats, bottom centre. Were it missing,
    /// the click would land on a lyric row and seek; that's reported.
    func pressFollow() -> Bool {
        let before = player.playbackAnchor
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: window.frame.width / 2, y: 69),
                                                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                clickCount: 1, pressure: 1)!)
        }
        return player.playbackAnchor == before
    }

    func close() { window.close() }
}

/// Measures and judges one scenario; collects every failure.
@MainActor final class Judge {
    var failures: [String] = []
    let tolerance: CGFloat = 2
    /// FLOE_FOLLOW_TRACE=1 prints every sampled frame.
    let trace = ProcessInfo.processInfo.environment["FLOE_FOLLOW_TRACE"] == "1"

    func check(_ ok: Bool, _ rig: Rig, _ scenario: String, _ message: String) {
        print("  \(ok ? "ok  " : "FAIL") \(message)")
        if !ok { failures.append("\(rig.label) \(scenario): \(message)") }
    }

    static func fmt(_ value: CGFloat) -> String { String(format: "%.1f", value) }
    nonisolated static func anchor(_ rect: CGRect) -> CGFloat { rect.minY + rect.height * 0.4 }
    nonisolated static func offset(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minY - b.minY), abs(a.maxY - b.maxY))
    }

    /// The largest move of `line` between two sampled frames, scaled to a
    /// 120 Hz frame: a list moving in steps leaves the pill between rows.
    static func step(_ samples: [Sample], line: Int) -> CGFloat {
        var largest: CGFloat = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            guard let from = a.rows[line], let to = b.rows[line] else { continue }
            largest = max(largest, abs(to.minY - from.minY) / max(1, CGFloat((b.time - a.time) * 120)))
        }
        return largest
    }

    /// Where the line rests once the motion is over, and that it stays there:
    /// at the anchor, under the pill, with no second jump.
    func landing(_ samples: [Sample], line: Int, rig: Rig, scenario: String, settledBy: Double) {
        guard let last = samples.last, let row = last.rows[line] else {
            check(false, rig, scenario, "line \(line) is not laid out at the end"); return
        }
        let error = Self.anchor(row) - rig.anchorY
        check(abs(error) <= tolerance, rig, scenario, "line \(line) rests \(Self.fmt(error)) pt from the anchor")
        if let pill = last.pill, last.pillIDs == [line] {
            let off = Self.offset(pill, row)
            check(off <= tolerance, rig, scenario, "pill \(Self.fmt(off)) pt from line \(line)")
        } else {
            check(false, rig, scenario, "pill on lines \(last.pillIDs.sorted()) at the end, split: \(last.split)")
        }
        let late = samples.filter { $0.time >= settledBy }
        let drift = late.compactMap { $0.rows[line].map { abs($0.minY - row.minY) } }.max() ?? 0
        let pillDrift = late.compactMap { $0.pill.map { abs($0.minY - (last.pill?.minY ?? 0)) } }.max() ?? 0
        check(drift <= 0.5 && pillDrift <= 0.5, rig, scenario, String(format: "from %.2f s: line moves %.1f pt, "
              + "pill %.1f pt (no second jump)", settledBy, drift, pillDrift))
    }

    /// A line advance while following: on every frame the pill must sit where
    /// the list has carried it, between the old and new rows at the scroll's own progress.
    func glide(_ samples: [Sample], from old: Int, to new: Int, rig: Rig, scenario: String) {
        guard let before = samples.last(where: { $0.pillIDs == [old] })?.rows[new],
              let after = samples.last?.rows[new] else {
            check(false, rig, scenario, "rows \(old)/\(new) missing around the glide"); return
        }
        let travel = before.minY - after.minY
        var worst: CGFloat = 0, worstPin: CGFloat = 0, frames = 0, split = 0, low: CGFloat = 0, high: CGFloat = 1
        for sample in samples where sample.pillIDs.contains(new) {
            guard let pill = sample.pill else { split += 1; continue }
            guard let a = sample.rows[old], let b = sample.rows[new] else { continue }
            let q = abs(travel) < 1 ? 1 : (before.minY - b.minY) / travel
            if q > 0.001 && q < 0.999 { frames += 1 }
            low = min(low, q)
            high = max(high, q)
            let ideal = CGRect(x: b.minX, y: a.minY + (b.minY - a.minY) * q, width: b.width,
                               height: a.height + (b.height - a.height) * q)
            worst = max(worst, Self.offset(pill, ideal))
            if trace {
                let p = abs(b.minY - a.minY) < 1 ? 1 : (pill.minY - a.minY) / (b.minY - a.minY)
                print(String(format: "   %.3f s  list %.3f  pill %.3f  off %.1f pt", sample.time, q, p,
                             Self.offset(pill, ideal)))
            }
            worstPin = max(worstPin, abs(Self.anchor(pill) - rig.anchorY))
        }
        let step = Self.step(samples, line: new)
        print("  glide \(old)→\(new): \(frames) frames in flight, list travels \(Self.fmt(travel)) pt, "
              + "pill's 40% point within \(Self.fmt(worstPin)) pt of the anchor, list steps up to \(Self.fmt(step)) pt")
        check(step <= 12, rig, scenario, "list moves at most \(Self.fmt(step)) pt between frames")
        check(frames >= 5, rig, scenario, "glide animates over \(frames) sampled frames")
        check(worstPin <= tolerance, rig, scenario, "pill's 40% point within \(Self.fmt(worstPin)) pt of the anchor")
        check(split == 0, rig, scenario, "\(split) frames with the pill in two places")
        check(worst <= tolerance, rig, scenario, "pill off the list's path by at most \(Self.fmt(worst)) pt")
        check(low >= -0.02 && high <= 1.02, rig, scenario,
              String(format: "scroll progress stays within %.2f…%.2f (no overshoot)", low, high))
    }

    /// Following on one curve, the list and the pill keep the pill's 40% point
    /// on the anchor on every frame, however the glides overlap.
    func pinned(_ samples: [Sample], rig: Rig, scenario: String) {
        var worst: CGFloat = 0, split = 0
        let last = samples.last?.pillIDs.first ?? -1
        for sample in samples where !sample.pills.isEmpty {
            guard let pill = sample.pill else { split += 1; continue }
            worst = max(worst, abs(Self.anchor(pill) - rig.anchorY))
            if trace { print(String(format: "   %.3f s  pill %@  %.1f pt, line %d at %.1f", sample.time,
                                    "\(sample.pillIDs.sorted())", Self.anchor(pill) - rig.anchorY, last,
                                    sample.rows[last]?.minY ?? -1)) }
        }
        check(split == 0 && worst <= tolerance, rig, scenario,
              "pill's 40% point within \(Self.fmt(worst)) pt of the anchor; \(split) frames split")
        let step = Self.step(samples, line: last)
        check(step <= 12, rig, scenario, "line \(last) moves at most \(Self.fmt(step)) pt between frames")
    }

    /// While no line changes, the pill rides on its row on every frame.
    func pillOnRow(_ samples: [Sample], line: Int, rig: Rig, scenario: String) {
        var worst: CGFloat = 0, split = 0, empty = 0, elsewhere = 0
        if trace {
            for sample in samples {
                print(String(format: "   %.3f s  line %@  pill %@", sample.time,
                             sample.rows[line].map { Self.fmt(Self.anchor($0) - rig.anchorY) } ?? "-",
                             sample.pill.map { Self.fmt(Self.anchor($0) - rig.anchorY) } ?? "\(sample.pillIDs.sorted())"))
            }
        }
        for sample in samples where !sample.pills.isEmpty {
            guard let pill = sample.pill else { split += 1; continue }
            guard sample.pillIDs == [line] else { elsewhere += 1; continue }
            guard let row = sample.rows[line] else { empty += 1; continue }
            worst = max(worst, Self.offset(pill, row))
        }
        check(split == 0 && empty == 0 && elsewhere == 0 && worst <= tolerance, rig, scenario,
              "pill on line \(line) in every frame: off by \(Self.fmt(worst)) pt; frames split \(split), "
              + "without its line \(empty), on another line \(elsewhere)")
    }
}

@main @MainActor
struct LyricsFollowTests {
    /// Mixed lengths: short lines, ones that wrap to two or three lines at
    /// both window sizes, and instrumental gaps.
    static let words = [
        "A quiet start",
        "Colors drift across the glass and carry every echo of the evening into the morning light",
        "Follow the sound",
        "",
        "The shapes move slowly through the light while every little memory returns and finds a place beside the window, waiting in the rain until the street is quiet again",
        "And settle when we pause",
        "Hold on",
        "We were dancing on the ceiling of a borrowed room with nothing left to lose",
        "",
        "Every road we never took is calling out our names tonight, so we keep driving through the dark with the radio turned all the way up and the windows down",
        "Oh",
        "Say it again",
    ]
    /// Ten seconds apart, except lines 15–17, a fifth of a second apart from
    /// a second after line 14: quicker than a glide, so each interrupts the last.
    static let lines = (0..<60).map { index in
        let time = (15...17).contains(index) ? 146 + Double(index - 15) * 0.2 : 5 + Double(index) * 10
        return LyricLine(id: index, time: time, text: words[index % words.count])
    }
    static let sizes = [CGSize(width: 900, height: 700), CGSize(width: 1400, height: 1000)]

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let only = ProcessInfo.processInfo.environment["FLOE_FOLLOW_ONLY"]
        // Volatile, so nothing reaches ~/Library/Preferences.
        UserDefaults.standard.setVolatileDomain(["reduceMotion": false], forName: UserDefaults.argumentDomain)
        let judge = Judge()
        for size in sizes { await motion(size: size, only: only, judge: judge) }
        if only == nil || only == "E" {
            UserDefaults.standard.setVolatileDomain(["reduceMotion": true], forName: UserDefaults.argumentDomain)
            for size in sizes { await reducedMotion(size: size, judge: judge) }
        }
        if judge.failures.isEmpty {
            print("PASS: lyrics follow the playing line, and Follow returns to it")
        } else {
            print("FAILED \(judge.failures.count) checks:")
            for failure in judge.failures { print("  \(failure)") }
            exit(1)
        }
    }

    static func motion(size: CGSize, only: String?, judge: Judge) async {
        let rig = Rig(size: size, lines: lines, label: "\(Int(size.width))×\(Int(size.height))")
        defer { rig.close() }
        print(rig.label)
        rig.pause(onLine: 20)
        await rig.settle(1.2)
        func runs(_ name: String) -> Bool { only == nil || only == name }

        // A. Natural advances while following, across short, long and gap lines.
        for line in 21...27 where runs("A") {
            print(" A. advance to line \(line)")
            let samples = await rig.record(for: 1.1) { rig.play(intoLine: line) }
            rig.stop()
            judge.glide(samples, from: line - 1, to: line, rig: rig, scenario: "A \(line)")
            judge.landing(samples, line: line, rig: rig, scenario: "A \(line)", settledBy: 0.25 + 0.5)
            await rig.settle(0.3)
        }

        // A. Lines quicker than the glide: each advance interrupts the last.
        if runs("A") {
            print(" A. rapid lines 15–17")
            rig.pause(onLine: 14)
            await rig.settle()
            let samples = await rig.record(for: 1.4) { rig.play(intoLine: 15) }
            rig.stop()
            judge.pinned(samples.filter { $0.time > 0.2 }, rig: rig, scenario: "A rapid")
            judge.landing(samples, line: 17, rig: rig, scenario: "A rapid", settledBy: 1.15)
        }

        // B. Scroll away, then Follow.
        for (count, start, towardStart) in [(5, 30, true), (5, 30, false), (20, 30, true), (20, 30, false),
                                             (50, 55, true), (50, 5, false)] where runs("B") {
            let scenario = "B \(count) \(towardStart ? "up" : "down")"
            print(" \(scenario) from line \(start)")
            rig.pause(onLine: start)
            await rig.settle()
            let moved = await rig.drag(lines: count, from: start, towardStart: towardStart)
            print("  scrolled \(moved) lines away")
            await follow(rig, line: start, judge: judge, scenario: scenario)
        }

        // C. The line changes while scrolled away, then Follow.
        for (count, towardStart, step) in [(5, true, 1), (20, true, 1), (20, false, 1), (50, false, 3)] where runs("C") {
            let start = towardStart ? 40 : 5
            let scenario = "C \(count) \(towardStart ? "up" : "down") +\(step)"
            print(" \(scenario) from line \(start)")
            rig.pause(onLine: start)
            await rig.settle()
            let moved = await rig.drag(lines: count, from: start, towardStart: towardStart)
            print("  scrolled \(moved) lines away")
            let changed = await rig.record(for: 0.8) { rig.pause(onLine: start + step) }
            judge.pillOnRow(changed.filter { $0.time > 0.5 }, line: start + step, rig: rig, scenario: scenario + " away")
            await follow(rig, line: start + step, judge: judge, scenario: scenario)
        }

        // D. A long seek jumps; following then resumes with a glide.
        for (from, to) in [(10, 45), (50, 8)] where runs("D") {
            let scenario = "D \(from)→\(to)"
            print(" \(scenario)")
            rig.pause(onLine: from)
            await rig.settle()
            let jump = await rig.record(for: 0.8) { rig.pause(onLine: to) }
            judge.landing(jump, line: to, rig: rig, scenario: scenario, settledBy: 0.1)
            judge.pillOnRow(jump.filter { $0.time > 0.1 }, line: to, rig: rig, scenario: scenario)
            let next = await rig.record(for: 1.1) { rig.play(intoLine: to + 1) }
            rig.stop()
            judge.glide(next, from: to, to: to + 1, rig: rig, scenario: scenario + " then")
            judge.landing(next, line: to + 1, rig: rig, scenario: scenario + " then", settledBy: 0.75)
            await rig.settle(0.3)
        }
    }

    /// Presses Follow and checks the way back to the current line.
    static func follow(_ rig: Rig, line: Int, judge: Judge, scenario: String) async {
        let away = rig.sample(at: 0)
        print("  line \(line) \(away.rows[line] == nil ? "not laid out" : "laid out") before Follow")
        var pressed = true
        let samples = await rig.record(for: 1.2) { pressed = rig.pressFollow() }
        judge.check(pressed, rig, scenario, "Follow pressed (a click on a lyric row would have seeked)")
        if let first = samples.first(where: { $0.time > 0 && $0.rows[line] != nil }), let row = first.rows[line] {
            print(String(format: "  line appears at %.0f ms, %.1f pt from the anchor", first.time * 1_000,
                         Judge.anchor(row) - rig.anchorY))
        }
        for time in [0.3, 0.4, 0.6] {
            if let end = samples.first(where: { $0.time >= time }), let row = end.rows[line] {
                print(String(format: "  at %.1f s: %.1f pt from the anchor", time, Judge.anchor(row) - rig.anchorY))
            }
        }
        // The glide is 0.35 s from the frame after the click.
        judge.landing(samples, line: line, rig: rig, scenario: scenario, settledBy: 0.4)
        judge.pillOnRow(samples, line: line, rig: rig, scenario: scenario)
    }

    /// With Reduce Motion nothing travels: the first frame showing a change is already final.
    static func reducedMotion(size: CGSize, judge: Judge) async {
        let rig = Rig(size: size, lines: lines, label: "\(Int(size.width))×\(Int(size.height)) reduce motion")
        defer { rig.close() }
        print(rig.label)
        rig.pause(onLine: 20)
        await rig.settle(1.2)
        for (scenario, line, action) in [("E advance", 21, { rig.play(intoLine: 21) }),
                                         ("E seek", 40, { rig.pause(onLine: 40) })] as [(String, Int, () -> Void)] {
            print(" \(scenario)")
            let samples = await rig.record(for: 0.9, after: action)
            rig.stop()
            let shown = samples.first { $0.pillIDs.contains(line) }?.time ?? 0
            judge.landing(samples, line: line, rig: rig, scenario: scenario, settledBy: shown + 0.02)
        }
        print(" E follow")
        rig.pause(onLine: 30)
        await rig.settle()
        await rig.drag(lines: 20, from: 30, towardStart: true)
        var pressed = true
        let samples = await rig.record(for: 0.8) { pressed = rig.pressFollow() }
        judge.check(pressed, rig, "E follow", "Follow pressed")
        let shown = samples.first { $0.time > 0 && $0.rows[30] != nil }?.time ?? 0
        judge.landing(samples, line: 30, rig: rig, scenario: "E follow", settledBy: shown + 0.02)
        judge.pillOnRow(samples, line: 30, rig: rig, scenario: "E follow")
    }
}

/// Keeps its offscreen origin instead of being pulled back onto a display.
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
