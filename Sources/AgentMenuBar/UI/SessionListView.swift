import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage(NotchHUDMode.storageKey) private var notchModeRaw: String = NotchHUDMode.auto.rawValue
    @AppStorage(HotkeyChoice.storageKey) private var hotkeyRaw: String = HotkeyChoice.off.rawValue
    @State private var expandedSessionIds: Set<String> = []
    @State private var frozenSessionOrder: [String]?

    private var notchMode: NotchHUDMode {
        NotchHUDMode(rawValue: notchModeRaw) ?? .auto
    }

    private var hotkey: HotkeyChoice {
        HotkeyChoice(rawValue: hotkeyRaw) ?? .off
    }

    private var notchedScreenAvailable: Bool {
        NotchAvailability.notchedScreen() != nil
    }

    private var visibleSessions: [DroidSession] {
        let visible = store.visibleSessions
        guard let frozenSessionOrder else { return visible }

        var remainingById = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        let pinned = frozenSessionOrder.compactMap { remainingById.removeValue(forKey: $0) }
        let newlyVisible = visible.filter { remainingById[$0.id] != nil }
        return pinned + newlyVisible
    }

    private var visibleSessionIds: [String] {
        store.visibleSessions.map(\.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agents")
                    .font(.headline)
                Spacer()
                if visibleSessions.contains(where: { $0.status == .finished || $0.status == .stale }) {
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

            if visibleSessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No agents yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Open a terminal tab and start an agent (e.g. `codex` or `droid`). Make sure `make install-hooks` was run.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleSessions) { session in
                            SessionRowView(
                                session: session,
                                isExpanded: expandedSessionIds.contains(session.id),
                                onToggleExpanded: {
                                    if expandedSessionIds.contains(session.id) {
                                        expandedSessionIds.remove(session.id)
                                    } else {
                                        expandedSessionIds.insert(session.id)
                                    }
                                },
                                onFocus: {
                                    store.focus(session)
                                }
                            )
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
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(visibleSessions.count) tracked")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                        .buttonStyle(.borderless)
                        .font(.callout)
                }
                HStack(spacing: 12) {
                    notchHUDMenu
                    hotkeyMenu
                    Spacer()
                }
            }
            .padding(8)
        }
        .frame(width: 380)
        .animation(.easeInOut(duration: 0.18), value: store.banner)
        .onAppear {
            frozenSessionOrder = visibleSessionIds
        }
        .onDisappear {
            frozenSessionOrder = nil
            expandedSessionIds.removeAll()
        }
        .onChange(of: visibleSessionIds) { ids in
            reconcileFrozenOrder(with: ids)
        }
    }

    private func reconcileFrozenOrder(with visibleIds: [String]) {
        guard var frozen = frozenSessionOrder else { return }
        let visibleSet = Set(visibleIds)
        frozen.removeAll { !visibleSet.contains($0) }

        let frozenSet = Set(frozen)
        frozen.append(contentsOf: visibleIds.filter { !frozenSet.contains($0) })
        frozenSessionOrder = frozen
    }

    private var notchHUDMenu: some View {
        Menu {
            ForEach(NotchHUDMode.allCases) { mode in
                Button {
                    notchModeRaw = mode.rawValue
                } label: {
                    HStack {
                        if mode.rawValue == notchModeRaw {
                            Image(systemName: "checkmark")
                        }
                        Text(mode.label)
                        if mode == .auto {
                            Text(notchedScreenAvailable ? "(notch detected)" : "(no notch)")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } label: {
            Text("Notch status bar: \(notchMode.label)")
        }
        .menuStyle(.borderlessButton)
        .font(.callout)
        .fixedSize()
        .help(notchHelp)
    }

    private var notchHelp: String {
        switch notchMode {
        case .auto: return notchedScreenAvailable
            ? "Showing on the built-in display's notch."
            : "No notched display detected; notch status bar hidden."
        case .on:   return "Forced on. Falls back to top-center on un-notched displays."
        case .off:  return "Notch status bar disabled."
        }
    }

    private var hotkeyMenu: some View {
        Menu {
            ForEach(HotkeyChoice.allCases) { choice in
                Button {
                    hotkeyRaw = choice.rawValue
                } label: {
                    HStack {
                        if choice.rawValue == hotkeyRaw {
                            Image(systemName: "checkmark")
                        }
                        Text(choice.label)
                    }
                }
            }
        } label: {
            Text("Hotkey: \(hotkey.label)")
        }
        .menuStyle(.borderlessButton)
        .font(.callout)
        .fixedSize()
        .help(hotkey == .off
              ? "No global hotkey assigned."
              : "Press \(hotkey.label) anywhere to open the agents popover.")
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
