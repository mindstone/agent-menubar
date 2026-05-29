import SwiftUI

struct SessionRowView: View {
    let session: DroidSession
    let isExpanded: Bool
    let onToggleExpanded: () -> Void
    let onFocus: () -> Void

    @State private var pulse: Bool = false

    var body: some View {
        let waiting = session.status == .waitingForInput
        let firstPrompt = session.firstPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)

        HStack(alignment: .top, spacing: 10) {
            statusIndicator
                .padding(.top, waiting ? 0 : 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 6) {
                    Text(session.repoName ?? session.cwd.lastPathComponent)
                        .font(.system(size: 13, weight: waiting ? .bold : .semibold))
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                    agentPill
                    statusPill
                    hostAppPill
                    Spacer(minLength: 6)
                    Text(relativeTime(from: session.lastEventAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(absoluteTime(session.lastEventAt))
                }
                .fixedSize(horizontal: false, vertical: true)
                .help(titleTooltip)

                if let firstPrompt, !firstPrompt.isEmpty {
                    Text("› \(firstPrompt)")
                        .font(.system(size: 12).italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: isExpanded)
                        .help(firstPrompt)
                }

                Text(session.lastEvent)
                    .font(.system(size: 12))
                    .foregroundStyle(waiting ? .primary : .secondary)
                    .lineLimit(isExpanded ? nil : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: isExpanded)
                    .help(session.lastEvent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(accentColor)
                .frame(width: 3)
                .opacity(waiting || session.status == .running ? 1 : 0)
        }
        .contentShape(Rectangle())
        .gesture(rowTapGesture)
        .onAppear {
            if session.status == .running {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
    }

    private var rowTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded { onFocus() }
            .exclusively(before: TapGesture(count: 1).onEnded { onToggleExpanded() })
    }

    private var titleTooltip: String {
        let id = String(session.id.prefix(8))
        return "\(session.repoName ?? session.cwd.lastPathComponent) · \(session.cwd.path) · \(id)"
    }

    private func absoluteTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch session.status {
        case .waitingForInput:
            Text("❓")
                .font(.system(size: 16))
                .frame(width: 18, height: 18)
        case .running:
            Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)
                .opacity(pulse ? 0.35 : 1.0)
        case .finished:
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
        case .stale:
            Circle()
                .fill(Color.gray)
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch session.status {
        case .waitingForInput:
            pill(text: "WAITING", color: .orange)
        case .running:
            pill(text: "RUNNING", color: .blue)
        case .finished:
            pill(text: "DONE", color: .green)
        case .stale:
            pill(text: "STALE", color: .gray)
        }
    }

    private func pill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var agentPill: some View {
        Text(session.agentKind.displayName)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.12))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var hostAppPill: some View {
        if session.hostApp != .unknown {
            Text(session.hostApp.displayName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    private var accentColor: Color {
        switch session.status {
        case .running:         return .blue
        case .waitingForInput: return .orange
        case .finished:        return .green
        case .stale:           return .gray
        }
    }

    private var rowBackground: Color {
        switch session.status {
        case .waitingForInput: return Color.orange.opacity(0.14)
        case .running:         return Color.blue.opacity(0.07)
        default:               return .clear
        }
    }

    private func relativeTime(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
