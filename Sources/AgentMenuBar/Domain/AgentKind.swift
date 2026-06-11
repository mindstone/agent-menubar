import Foundation

enum AgentKind: String, Codable, CaseIterable {
    case factoryDroid = "factory-droid"
    case codex
    case cursor
    case claudeCode = "claude-code"
    case unknown

    var displayName: String {
        switch self {
        case .factoryDroid: return "Droid"
        case .codex:        return "Codex"
        case .cursor:       return "Cursor"
        case .claudeCode:   return "Claude"
        case .unknown:      return "Agent"
        }
    }

    /// Map the bridge's `agent_kind` string onto a kind. The shared bridge
    /// always tags events with an explicit kind (Factory sends `factory-droid`;
    /// a wrapper invoked with no arg sends the literal `"unknown"`), so an
    /// empty/absent value means a non-bridge sender — treat it as `.unknown`
    /// rather than silently labelling it Droid.
    static func fromBridgeValue(_ value: String?) -> AgentKind {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unknown
        }
        return AgentKind(rawValue: raw) ?? .unknown
    }
}
