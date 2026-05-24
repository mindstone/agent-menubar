import SwiftUI
import AppKit

struct NotchView: View {
    @ObservedObject var store: SessionStore
    let notchInset: CGFloat
    let notchWidth: CGFloat
    let onTap: () -> Void

    @State private var hovered: Bool = false
    @State private var attentionPopVisible: Bool = false
    @State private var attentionTask: Task<Void, Never>? = nil
    @Namespace private var ns

    static let collapsedVisibleHeight: CGFloat = 16
    private static let expandedWidth: CGFloat = 340

    private static let attentionDisplayDuration: UInt64 = 3_000_000_000

    private var counts: (running: Int, waiting: Int, finished: Int) {
        if case let .active(r, w, f) = store.menuBarState {
            return (r, w, f)
        }
        return (0, 0, 0)
    }

    private var hasAttention: Bool { store.menuBarState.hasAttention }
    private var isExpanded: Bool { attentionPopVisible || hovered }

    /// Monotonic signature that changes every time any session raises a new
    /// attention event (`Notification`, `PreToolUse(AskUser)`). Drives the
    /// 3-second auto-popup so each new question retriggers the timer.
    private var attentionSignature: TimeInterval {
        store.sessions
            .compactMap { $0.attentionRaisedAt?.timeIntervalSince1970 }
            .max() ?? 0
    }

    private var topSession: DroidSession? {
        store.visibleSessions.first(where: { $0.status == .waitingForInput })
            ?? store.visibleSessions.first(where: { $0.status == .running })
            ?? store.visibleSessions.first
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var animation: Animation {
        reduceMotion
            ? .linear(duration: 0)
            : .spring(response: 0.35, dampingFraction: 0.82, blendDuration: 0.2)
    }

    private var pillWidth: CGFloat {
        isExpanded ? Self.expandedWidth : max(notchWidth, 60)
    }

    var body: some View {
        VStack(spacing: 0) {
            pill
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover { hovered = $0 }
        .onChange(of: attentionSignature) { new in
            handleAttentionEvent(new)
        }
        .onChange(of: hasAttention) { isAttention in
            if !isAttention {
                attentionTask?.cancel()
                attentionTask = nil
                if attentionPopVisible { attentionPopVisible = false }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
    }

    private func handleAttentionEvent(_ signature: TimeInterval) {
        guard signature > 0 else { return }
        attentionTask?.cancel()
        attentionPopVisible = true
        attentionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.attentionDisplayDuration)
            if !Task.isCancelled {
                attentionPopVisible = false
            }
        }
    }

    private var pill: some View {
        ZStack(alignment: .top) {
            if isExpanded {
                Color.black
                    .clipShape(BottomRoundedShape(radius: 22))
                    .transition(.opacity)
            }

            VStack(alignment: .leading, spacing: 0) {
                // Reserve the part of the pill that's hidden behind the bezel.
                Color.clear.frame(height: notchInset)

                if isExpanded {
                    expandedCard
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    collapsedRow
                        .frame(width: pillWidth, height: Self.collapsedVisibleHeight)
                }
            }
        }
        .frame(width: pillWidth)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .animation(animation, value: isExpanded)
        .animation(animation, value: counts.running)
        .animation(animation, value: counts.waiting)
        .animation(animation, value: counts.finished)
    }

    private var collapsedRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            beadSquares
                .matchedGeometryEffect(id: "notchSquares", in: ns)
            Spacer(minLength: 0)
        }
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                groupedSquares
                    .matchedGeometryEffect(id: "notchSquares", in: ns)
                if let s = topSession {
                    Text(s.repoName ?? s.cwd.lastPathComponent)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            if let prompt = topSession?.firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
                Text("› \(prompt)")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let s = topSession {
                Text(s.lastEvent)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let title = topSession?.tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var groupedSquares: some View {
        HStack(spacing: 6) {
            squareGroup(count: counts.waiting, color: .orange, hasAttention: hasAttention)
            squareGroup(count: counts.running, color: .blue, hasAttention: false)
            squareGroup(count: counts.finished, color: .green, hasAttention: false)
        }
    }

    @ViewBuilder
    private func squareGroup(count: Int, color: Color, hasAttention: Bool) -> some View {
        if count > 0 {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .modifier(AttentionPulse(active: hasAttention && !reduceMotion))
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
        }
    }

    /// Collapsed-state row: one square per agent, no numbers, hairline dark
    /// stroke on each so it stays legible directly on the wallpaper.
    private var beadSquares: some View {
        HStack(spacing: 4) {
            ForEach(0..<counts.waiting, id: \.self) { _ in
                bead(color: .orange, pulse: hasAttention)
            }
            ForEach(0..<counts.running, id: \.self) { _ in
                bead(color: .blue, pulse: false)
            }
            ForEach(0..<counts.finished, id: \.self) { _ in
                bead(color: .green, pulse: false)
            }
        }
    }

    private func bead(color: Color, pulse: Bool) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .stroke(Color.black.opacity(0.55), lineWidth: 0.5)
            )
            .modifier(AttentionPulse(active: pulse && !reduceMotion))
    }

    private var accessibilityLabel: String {
        let c = counts
        return "Agents pill, \(c.running) running, \(c.waiting) waiting, \(c.finished) done. Activate to open list."
    }
}

private struct AttentionPulse: ViewModifier {
    let active: Bool
    @State private var on: Bool = false

    func body(content: Content) -> some View {
        content
            .opacity(active ? (on ? 1.0 : 0.45) : 1.0)
            .onAppear {
                guard active else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    on.toggle()
                }
            }
    }
}

private struct BottomRoundedShape: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}
