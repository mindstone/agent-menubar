import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Droid sessions")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            Divider()

            if store.sessions.isEmpty {
                Text("No droids yet. Start one in iTerm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.sessions) { session in
                            SessionRowView(session: session) {
                                store.focus(session)
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 400)
            }

            Divider()
            HStack {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.callout)
            }
            .padding(8)
        }
        .frame(width: 360)
    }
}
