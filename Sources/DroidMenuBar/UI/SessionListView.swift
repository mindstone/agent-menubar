import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Droid sessions")
                    .font(.headline)
                Spacer()
                if store.sessions.contains(where: { $0.status == .finished || $0.status == .stale }) {
                    Button("Clear finished") { store.clearFinished() }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if store.sessions.isEmpty {
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
                        ForEach(store.sessions) { session in
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
                Text("\(store.sessions.count) tracked")
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
    }
}
