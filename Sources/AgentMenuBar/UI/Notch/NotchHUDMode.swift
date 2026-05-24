import Foundation

enum NotchHUDMode: String, CaseIterable, Identifiable {
    case auto
    case on
    case off

    static let storageKey = "notchHUDMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .on:   return "On"
        case .off:  return "Off"
        }
    }
}
