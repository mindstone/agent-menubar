import SwiftUI
import AppKit

@main
struct DroidMenuBarApp: App {
    @StateObject private var store = SessionStore()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
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
