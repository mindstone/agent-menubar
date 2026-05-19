import SwiftUI

struct SessionRowView: View {
    let session: DroidSession
    let onFocus: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusDot
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.repoName ?? session.cwd.lastPathComponent)
                    .font(.system(size: 13, weight: .semibold))
                Text(session.lastEvent)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(relativeTime(from: session.lastEventAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }

    @ViewBuilder
    private var statusDot: some View {
        if session.status == .waitingForInput {
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 11, height: 11)
        } else {
            Circle()
                .fill(color(for: session.status))
                .frame(width: 8, height: 8)
        }
    }

    private func color(for status: SessionStatus) -> Color {
        switch status {
        case .running:         return .blue
        case .waitingForInput: return .orange
        case .finished:        return .green
        case .stale:           return .gray
        }
    }

    private func relativeTime(from date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
