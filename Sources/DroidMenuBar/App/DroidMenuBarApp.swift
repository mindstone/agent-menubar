import SwiftUI
import AppKit

@main
struct DroidMenuBarApp: App {
    @StateObject private var store: SessionStore
    private let server: HookSocketServer

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)

        let store = SessionStore()
        let server = HookSocketServer()
        do {
            try server.start { event in
                Task { @MainActor in
                    store.apply(event)
                }
            }
            NSLog("DroidMenuBar: listening at \(HookSocketServer.socketURL.path)")
        } catch {
            NSLog("DroidMenuBar: socket bootstrap failed: \(error)")
        }
        self._store = StateObject(wrappedValue: store)
        self.server = server
    }

    var body: some Scene {
        MenuBarExtra {
            SessionListView()
                .environmentObject(store)
        } label: {
            MenuBarLabel(state: store.menuBarState)
        }
        .menuBarExtraStyle(.window)
    }
}
