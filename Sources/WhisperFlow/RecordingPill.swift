import AppKit

/// Wispr-style floating pill, drawn with AppKit only (no SwiftUI).
///
/// STATIC pill (Bishal 2026-11-03: "no moving bars or pulsing dots").
/// No timer, no idle animation at all. The waveform is a true mic
/// reaction, not animation: each bar is one recent mic level sample
/// (history, newest on the right), so bars only move when the mic
/// itself moves, and freeze when silent. Dots are all solid.
/// Cleaning state is plain black + white text, no gradient, no colour
/// (Bishal 2026-11-03, from the Wispr article image: small black pill
/// above the Dock, white waveform, black-only background).
///   recording    — white waveform bars, history of live mic RMS
///   continuous   — same waveform, with a clickable X (discard) and
///                  check (commit) button, like the reference pill
///   transcribing — solid dots, no audio input
///   cleaningUp   — "Cleaning up..." in white on black only,
///                  shown while the LLM polish pass runs
///
/// The pill is a borderless floating panel at the bottom-centre of the
/// main screen, just above the Dock (Bishal's red-box position,
/// 2026-11-03) — not screen-centre. Compact: 40px tall, tight padding.
/// It never steals keyboard focus. In recording / transcribing /
/// cleaning-up states clicks pass through to the app underneath; in
/// continuous mode clicks are captured so X / check can be pressed.
final class RecordingPill {

    enum State {
        case recording(continuous: Bool)
        case transcribing
        case cleaningUp
    }

    private let panel: NSPanel
    private let pillView: PillView
    private var timer: Timer?
    private var energyHistory: [Float] = Array(repeating: 0.18, count: 11)

    init() {
        pillView = PillView(frame: NSRect(x: 0, y: 0, width: 180, height: 40))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = pillView
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
    }

    // AppKit UI must run on the main thread. processAndInject calls
    // showCleaningUp from a background queue, and macOS 26 kills the app
    // with SIGTRAP ("Must only be used from the main thread") if
    // setFrame/orderFront runs off-main — crash 2026-11-03 09:06, faulting
    // thread was RecordingPill.resizeAndShow via showCleaningUp.
    // Guard every public entry point, not just showCleaningUp, since
    // updateStatusIcon callers are not guaranteed main-thread either.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    func showRecording(continuous: Bool, onCancel: (() -> Void)?, onConfirm: (() -> Void)?) {
        onMain { [weak self] in
            guard let self else { return }
            self.pillView.onCancel = onCancel
            self.pillView.onConfirm = onConfirm
            self.pillView.state = .recording(continuous: continuous)
            self.panel.ignoresMouseEvents = !continuous
            self.resizeAndShow()
        }
    }

    func showTranscribing() {
        onMain { [weak self] in
            guard let self else { return }
            self.pillView.state = .transcribing
            self.panel.ignoresMouseEvents = true
            self.resizeAndShow()
        }
    }

    func showCleaningUp() {
        onMain { [weak self] in
            guard let self else { return }
            self.pillView.state = .cleaningUp
            self.panel.ignoresMouseEvents = true
            self.resizeAndShow()
        }
    }

    func hide() {
        onMain { [weak self] in
            guard let self else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.panel.orderOut(nil)
        }
    }

    /// Live mic RMS (0..~0.3 for speech). Each call shifts one new
    /// sample into the waveform history, so the bars react to the mic
    /// in real time and freeze when no new sample arrives. No timer.
    func setEnergy(_ rms: Float) {
        onMain { [weak self] in
            guard let self else { return }
            let target = min(max(rms * 3, 0), 1)
            self.energyHistory.removeFirst()
            self.energyHistory.append(target)
            self.pillView.energies = self.energyHistory
            self.pillView.needsDisplay = true
        }
    }

    private func resizeAndShow() {
        let width: CGFloat
        switch pillView.state {
        case .recording(let continuous): width = continuous ? 240 : 180
        case .transcribing: width = 140
        case .cleaningUp: width = 190
        }
        let height: CGFloat = 40
        guard let screen = NSScreen.main else { return }
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: 70,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: true)
        pillView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.orderFront(nil)
        pillView.needsDisplay = true
        // No timer on purpose: static pill, see header comment.
    }
}

/// The drawing view. Static: bars from mic history only, dots solid,
/// no border, no gradient. No timer, no phase, no animation.
private final class PillView: NSView {
    var state: RecordingPill.State = .transcribing
    var energies: [Float] = Array(repeating: 0.18, count: 11)
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private let barCount = 11

    func tick() {
        // Kept for callers; static pill never schedules it.
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let pillRect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: pillRect, xRadius: 20, yRadius: 20)

        // Black pill body only — no border, no gradient, no colour,
        // exactly like the Wispr article image. Shadow (panel) gives
        // the edge against the wallpaper.
        NSColor.black.setFill()
        path.fill()

        switch state {
        case .recording(let continuous):
            if continuous { drawButton(atX: 28, symbol: "x") }
            drawWaveform(continuous: continuous)
            if continuous { drawButton(atX: bounds.width - 28, symbol: "check") }
        case .transcribing:
            drawDots()
        case .cleaningUp:
            drawCleaningUp()
        }
    }

    private func drawWaveform(continuous: Bool) {
        let maxHeight: CGFloat = 20
        let barWidth: CGFloat = 3
        let gap: CGFloat = 5
        let totalWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * gap
        var startX: CGFloat
        if continuous {
            // Leave room for the X / check buttons.
            startX = (bounds.width - totalWidth) / 2
        } else {
            startX = (bounds.width - totalWidth) / 2
        }
        NSColor.white.setFill()
        // Each bar is one recent mic sample (history, newest right).
        // Bars move only when the mic moves — real reaction, no animation.
        for i in 0..<barCount {
            let level = i < energies.count ? energies[i] : 0.18
            let base = CGFloat(0.18 + 0.82 * min(max(level, 0), 1))
            let height = max(4, maxHeight * base)
            let x = startX + CGFloat(i) * (barWidth + gap)
            let y = (bounds.height - height) / 2
            NSBezierPath(roundedRect: NSRect(x: x, y: y, width: barWidth, height: height), xRadius: 2, yRadius: 2).fill()
        }
    }

    private func drawDots() {
        let dotCount = 8
        let diameter: CGFloat = 5
        let gap: CGFloat = 6
        let totalWidth = CGFloat(dotCount) * diameter + CGFloat(dotCount - 1) * gap
        var startX = (bounds.width - totalWidth) / 2
        for i in 0..<dotCount {
            // Static: all dots solid, no pulsing wave.
            NSColor.white.setFill()
            let rect = NSRect(
                x: startX,
                y: (bounds.height - diameter) / 2,
                width: diameter,
                height: diameter
            )
            NSBezierPath(ovalIn: rect).fill()
            startX += diameter + gap
        }
    }

    private func drawCleaningUp() {
        let text = "Cleaning up...  ✦"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = NSRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func drawButton(atX x: CGFloat, symbol: String) {
        let diameter: CGFloat = 26
        let rect = NSRect(
            x: x - diameter / 2,
            y: (bounds.height - diameter) / 2,
            width: diameter,
            height: diameter
        )
        NSColor(white: 0.25, alpha: 1.0).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let label = symbol == "x" ? "✕" : "✓"
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            in: NSRect(
                x: rect.midX - size.width / 2,
                y: rect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard case .recording(let continuous) = state, continuous else { return }
        let point = convert(event.locationInWindow, from: nil)
        if point.x < 60 {
            onCancel?()
        } else if point.x > bounds.width - 60 {
            onConfirm?()
        }
    }
}
