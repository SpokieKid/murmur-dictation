import SwiftUI
import AppKit

enum WaveformHUDCompletionStyle {
    case success
    case failure
    case cancelled
}

private enum WaveformHUDPhase: Equatable {
    case recording
    case processing
    case waiting
    case success
    case failure
    case cancelled
}

private struct WaveformHUDItem: Identifiable, Equatable {
    let id: Int
    let sequence: Int
    var levels: [CGFloat]
    var status: String
    var phase: WaveformHUDPhase
    var warning: Bool
}

/// One observable collection drives the whole floating stack. Each dictation
/// keeps its own waveform/status so a new recording can animate at the bottom
/// while older transcription cards remain visible above it.
private final class WaveformStackModel: ObservableObject {
    let barCount = 20
    @Published var items: [WaveformHUDItem] = []

    func start(id: Int, sequence: Int, status: String) {
        items.removeAll { $0.id == id }
        items.append(WaveformHUDItem(
            id: id,
            sequence: sequence,
            levels: Array(repeating: 0.04, count: barCount),
            status: status,
            phase: .recording,
            warning: false
        ))
    }

    func push(id: Int, level: Float) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var next = items[index].levels
        next.removeFirst()
        next.append(CGFloat(max(0.04, min(1.0, level))))
        items[index].levels = next
    }

    func update(id: Int, status: String, phase: WaveformHUDPhase, warning: Bool = false) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].phase = phase
        items[index].warning = warning
    }

    func remove(id: Int) {
        items.removeAll { $0.id == id }
    }

    func reset() {
        items.removeAll()
    }
}

private struct WaveformStackView: View {
    @ObservedObject var model: WaveformStackModel
    private let maxVisibleItems = 5

    private var displayedItems: [WaveformHUDItem] {
        Array(model.items.suffix(maxVisibleItems).reversed())
    }

    private var hiddenCount: Int {
        max(0, model.items.count - maxVisibleItems)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if hiddenCount > 0 {
                Text(L10n.format("hud.hidden_processing", hiddenCount))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color(white: 0.2)))
                    .offset(y: -CGFloat(maxVisibleItems) * 34 - 2)
                    .transition(.opacity.combined(with: .scale))
            }

            ForEach(Array(displayedItems.enumerated()), id: \.element.id) { stackIndex, item in
                WaveformCard(item: item, stackIndex: stackIndex)
                    .offset(y: -CGFloat(stackIndex) * 34)
                    .zIndex(Double(100 - stackIndex))
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .scale(scale: 0.92).combined(with: .opacity)
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 10)
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: model.items.map(\.id))
    }
}

private struct WaveformCard: View {
    let item: WaveformHUDItem
    let stackIndex: Int

    var body: some View {
        HStack(spacing: 9) {
            phaseIndicator

            Text("#\(item.sequence)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .monospacedDigit()

            if item.phase == .recording {
                waveformBars
            } else if item.phase == .processing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.88))
                    .frame(width: 48)
            } else if item.phase == .waiting {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .frame(width: 48)
            }

            Text(item.status)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 15)
        .frame(width: 350, height: 40)
        .background(Capsule().fill(Color(white: 0.14 + Double(min(stackIndex, 4)) * 0.018)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 0.5))
        .compositingGroup()
        .scaleEffect(1 - CGFloat(min(stackIndex, 4)) * 0.018, anchor: .bottom)
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .animation(.easeInOut(duration: 0.18), value: item.phase)
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        switch item.phase {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure, .cancelled:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(item.phase == .cancelled ? Color.gray : Color.red)
        default:
            Circle()
                .fill(item.warning ? Color.yellow : (item.phase == .recording ? Color.red : Color.orange))
                .frame(width: 8, height: 8)
        }
    }

    private var waveformBars: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(item.levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2.2, height: 4 + level * 20)
            }
        }
        .frame(width: 82, height: 24)
        .animation(.easeOut(duration: 0.1), value: item.levels)
    }
}

/// Borderless floating panel that anchors the newest card where the original
/// waveform pill lived and grows older in-flight jobs upward as a visual stack.
final class WaveformHUD {
    private let model = WaveformStackModel()
    private var panel: NSPanel?
    private var completionTokens: [Int: UUID] = [:]

    func start(id: Int, sequence: Int, status: String) {
        completionTokens[id] = nil
        model.start(id: id, sequence: sequence, status: status)
        ensurePanel()
        position()
        panel?.orderFrontRegardless()
    }

    func update(id: Int, level: Float) {
        model.push(id: id, level: level)
    }

    func setProcessing(id: Int, status: String) {
        model.update(id: id, status: status, phase: .processing)
    }

    func setWaiting(id: Int, status: String) {
        model.update(id: id, status: status, phase: .waiting)
    }

    func warn(id: Int, status: String) {
        model.update(id: id, status: status, phase: .recording, warning: true)
    }

    /// Briefly leaves a terminal state in the stack, then removes only that
    /// card. Other recordings and processing jobs keep the panel alive.
    func finish(id: Int, message: String, style: WaveformHUDCompletionStyle) {
        let phase: WaveformHUDPhase
        let delay: TimeInterval
        switch style {
        case .success:
            phase = .success
            delay = 1.4
        case .failure:
            phase = .failure
            delay = 2.2
        case .cancelled:
            phase = .cancelled
            delay = 1.4
        }
        model.update(id: id, status: message, phase: phase)

        let token = UUID()
        completionTokens[id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.completionTokens[id] == token else { return }
            self.completionTokens[id] = nil
            self.model.remove(id: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.model.items.isEmpty else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    func hide() {
        completionTokens.removeAll()
        model.reset()
        panel?.orderOut(nil)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let size = NSSize(width: 390, height: 230)
        let hosting = NSHostingView(rootView: WaveformStackView(model: model))
        hosting.frame = NSRect(origin: .zero, size: size)

        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
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
        guard let screen = NSScreen.main, let panel else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        // The bottom/newest pill stays at the original HUD baseline; extra jobs
        // occupy the clear panel area above it rather than moving the active card.
        let y = visible.minY + 96
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
