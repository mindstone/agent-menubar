import Foundation

enum AgentKind: String, Codable, CaseIterable {
    case factoryDroid = "factory-droid"
    case codex
    case unknown

    var displayName: String {
        switch self {
        case .factoryDroid: return "Droid"
        case .codex:        return "Codex"
        case .unknown:      return "Agent"
        }
    }

    static func fromBridgeValue(_ value: String?) -> AgentKind {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .factoryDroid
        }
        return AgentKind(rawValue: raw) ?? .unknown
    }
}
