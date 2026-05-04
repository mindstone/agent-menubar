import Foundation
import SwiftUI

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [DroidSession] = []

    var menuBarState: MenuBarState {
        let active = sessions.filter { $0.status != .finished && $0.status != .stale }
        let waiting = active.filter { $0.status == .waitingForInput }.count
        if active.isEmpty { return .idle }
        if waiting > 0 { return .attention(count: active.count, waiting: waiting) }
        return .tracking(count: active.count)
    }

    func apply(_ event: HookEvent) {
        // TODO: implement state-machine transitions per hook event name.
        //  - SessionStart  -> upsert running
        //  - Notification  -> waitingForInput, raise attention, fire NSUserNotification
        //  - UserPromptSubmit -> running, clear attention
        //  - Stop          -> finished, lower-urgency notification
        //  - SessionEnd    -> finalise + schedule prune
    }

    func focus(_ session: DroidSession) {
        // TODO: invoke ITermFocuser
    }
}
