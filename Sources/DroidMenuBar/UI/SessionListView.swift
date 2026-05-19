import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Droid sessions")
                    .font(.headline)
                Spacer()
                if store.visibleSessions.contains(where: { $0.status == .finished || $0.status == .stale }) {
                    Button("Clear finished") { store.clearFinished() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let banner = store.banner {
                BannerView(banner: banner) { store.dismissBanner() }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            if store.visibleSessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No droids yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Open an iTerm tab and run `droid`. Make sure `make install-hooks` was run.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.visibleSessions) { session in
                            SessionRowView(session: session) {
                                store.focus(session)
                            }
                            .contextMenu {
                                Button("Remove from list") { store.remove(session) }
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 420)
            }

            Divider()
            HStack(spacing: 12) {
                Text("\(store.visibleSessions.count) tracked")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            .padding(8)
        }
        .frame(width: 380)
        .animation(.easeInOut(duration: 0.18), value: store.banner)
    }
}

private struct BannerView: View {
    let banner: TransientBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 1)
            Text(banner.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
    }

    private var icon: String {
        switch banner.tone {
        case .info:    return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
    private var tint: Color {
        switch banner.tone {
        case .info:    return .blue
        case .warning: return .orange
        }
    }
}
