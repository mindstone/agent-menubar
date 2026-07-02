import SwiftUI

struct SessionListView: View {
    @EnvironmentObject var store: SessionStore
    @AppStorage(NotchHUDMode.storageKey) private var notchModeRaw: String = NotchHUDMode.auto.rawValue
    @AppStorage(HotkeyChoice.storageKey) private var hotkeyRaw: String = HotkeyChoice.off.rawValue
    @State private var expandedSessionIds: Set<String> = []
    @State private var frozenSessionOrder: [String]?
    /// The "Closed" recovery section is collapsed by default so the popover
    /// stays focused on active work; the user expands it to recover a session.
    @State private var showClosed = false

    private var notchMode: NotchHUDMode {
        NotchHUDMode(rawValue: notchModeRaw) ?? .auto
    }

    private var hotkey: HotkeyChoice {
        HotkeyChoice(rawValue: hotkeyRaw) ?? .off
    }

    private var notchedScreenAvailable: Bool {
        NotchAvailability.notchedScreen() != nil
    }

    /// Active (running / waiting) sessions for the main list, pinned to the
    /// order captured when the popover opened so rows don't reshuffle live.
    private var activeSessions: [DroidSession] {
        let active = store.activeSessions
        guard let frozenSessionOrder else { return active }

        var remainingById = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0) })
        let pinned = frozenSessionOrder.compactMap { remainingById.removeValue(forKey: $0) }
        let newlyActive = active.filter { remainingById[$0.id] != nil }
        return pinned + newlyActive
    }

    private var activeSessionIds: [String] {
        store.activeSessions.map(\.id)
    }

    /// Closed, recoverable sessions shown in the collapsed "Closed" section.
    private var closedSessions: [DroidSession] {
        store.resumableSessions
    }

    @ViewBuilder
    private func sessionRow(_ session: DroidSession, resumable: Bool) -> some View {
        SessionRowView(
            session: session,
            isExpanded: expandedSessionIds.contains(session.id),
            onToggleExpanded: { toggleExpanded(session.id) },
            onFocus: { resumable ? store.resume(session) : store.focus(session) },
            onResume: resumable ? { store.resume(session) } : nil
        )
        .contextMenu {
            if resumable {
                Button("Resume") { store.resume(session) }
            }
            Button("Remove from list") { store.remove(session) }
        }
    }

    private func toggleExpanded(_ id: String) {
        if expandedSessionIds.contains(id) {
            expandedSessionIds.remove(id)
        } else {
            expandedSessionIds.insert(id)
        }
    }

    @ViewBuilder
    private var closedSection: some View {
        if !closedSessions.isEmpty {
            HStack(spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: showClosed ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Closed")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("\(closedSessions.count)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.gray)
                        .clipShape(Capsule())
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) { showClosed.toggle() }
                }
                if showClosed {
                    Button("Clear all") { store.clearFinished() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .help("Sessions whose terminal is closed — expand to resume one in a new tab")

            Divider()

            if showClosed {
                ForEach(closedSessions) { session in
                    sessionRow(session, resumable: true)
                    Divider()
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Agents")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let banner = store.banner {
                BannerView(banner: banner) { store.dismissBanner() }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()

            if activeSessions.isEmpty && closedSessions.isEmpty {
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
                        if activeSessions.isEmpty {
                            Text("No active agents right now.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                            Divider()
                        } else {
                            ForEach(activeSessions) { session in
                                sessionRow(session, resumable: false)
                                Divider()
                            }
                        }
                        closedSection
                    }
                }
                .frame(maxHeight: 420)
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(footerCountText)
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
            frozenSessionOrder = activeSessionIds
        }
        .onDisappear {
            frozenSessionOrder = nil
            expandedSessionIds.removeAll()
            showClosed = false
        }
        .onChange(of: activeSessionIds) { ids in
            reconcileFrozenOrder(with: ids)
        }
    }

    private var footerCountText: String {
        let active = activeSessions.count
        let closed = closedSessions.count
        if closed > 0 {
            return "\(active) active · \(closed) closed"
        }
        return "\(active) active"
    }

    private func reconcileFrozenOrder(with activeIds: [String]) {
        guard var frozen = frozenSessionOrder else { return }
        let activeSet = Set(activeIds)
        frozen.removeAll { !activeSet.contains($0) }

        let frozenSet = Set(frozen)
        frozen.append(contentsOf: activeIds.filter { !frozenSet.contains($0) })
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
