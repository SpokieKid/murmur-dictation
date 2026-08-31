import SwiftUI
import AppKit

/// Drives the floating waveform pill shown while recording / processing.
final class WaveformModel: ObservableObject {
    let barCount = 28
    @Published var levels: [CGFloat]
    @Published var status: String = "Listening…"
    @Published var processing: Bool = false
    @Published var warning: Bool = false

    init() { levels = Array(repeating: 0.04, count: 28) }

    func push(_ level: Float) {
        var next = levels
        next.removeFirst()
        next.append(CGFloat(max(0.04, min(1.0, level))))
        levels = next
    }

    func reset() {
        levels = Array(repeating: 0.04, count: barCount)
        processing = false
        warning = false
    }
}

struct WaveformView: View {
    @ObservedObject var model: WaveformModel

    var body: some View {
        pill
            .frame(maxWidth: .infinity, maxHeight: .infinity) // center within the (clear) panel
    }

    private var pill: some View {
        HStack(spacing: 10) {
            statusDot
            bars
            Text(model.status)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        // Clean, fully-opaque dark pill — no material (which renders muddy/grey
        // and translucent over arbitrary backdrops).
        .background(Capsule().fill(Color(white: 0.14)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: .black.opacity(0.28), radius: 10, y: 3)
    }

    private var statusDot: some View {
        Circle()
            .fill(model.warning ? Color.yellow : (model.processing ? Color.orange : Color.red))
            .frame(width: 8, height: 8)
    }

    private var bars: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(Array(model.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.5, height: 4 + level * 22)
            }
        }
        .frame(height: 26)
        .animation(.easeOut(duration: 0.12), value: model.levels)
    }
}

/// Borderless floating panel that hosts the waveform near the bottom of the screen.
final class WaveformHUD {
    let model = WaveformModel()
    private var panel: NSPanel?
    private var generation = 0

    func show(status: String) {
        generation += 1
        model.reset()
        model.status = status
        model.processing = false
        ensurePanel()
        position()
        panel?.orderFrontRegardless()
    }

    func update(level: Float) { model.push(level) }

    func setProcessing(_ status: String) {
        model.processing = true
        model.warning = false
        model.status = status
    }

    /// Show an in-recording warning (yellow dot) without leaving the recording
    /// state — e.g. the countdown before the recording cap auto-stops capture.
    func warn(_ status: String) {
        model.processing = false
        model.warning = true
        model.status = status
    }

    /// Briefly show a confirmation message, then auto-hide (unless a new
    /// session started in the meantime).
    func finish(_ message: String) {
        model.processing = true
        model.warning = false
        model.status = message
        let g = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self = self, self.generation == g else { return }
            self.hide()
        }
    }

    func hide() {
        panel?.orderOut(nil)
        model.reset()
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = NSSize(width: 340, height: 60)
        let hosting = NSHostingView(rootView: WaveformView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.contentView = hosting
        panel = p
    }

    private func position() {
        guard let screen = NSScreen.main, let panel = panel else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
