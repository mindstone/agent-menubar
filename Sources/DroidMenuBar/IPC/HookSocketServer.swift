import Foundation
import Network

/// Listens on a Unix domain socket at
/// ~/Library/Application Support/DroidMenuBar/sock for line-delimited JSON
/// emitted by hooks/factory-event-bridge.sh.
final class HookSocketServer {
    static var socketURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DroidMenuBar", isDirectory: true)
            .appendingPathComponent("sock")
    }

    func start(onEvent: @escaping (HookEvent) -> Void) {
        // TODO: bind NWListener to a Unix domain socket, parse newline-delimited JSON,
        // decode as HookEvent, dispatch to onEvent on MainActor.
    }
}
