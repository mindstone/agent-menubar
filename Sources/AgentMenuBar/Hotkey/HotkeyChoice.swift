import Foundation
import Carbon.HIToolbox

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case off
    case ctrlAltCmdA
    case ctrlAltCmdG
    case ctrlAltCmdY
    case ctrlAltCmdJ

    static let storageKey = "globalHotkey"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:         return "Off"
        case .ctrlAltCmdA: return "⌃⌥⌘ A"
        case .ctrlAltCmdG: return "⌃⌥⌘ G"
        case .ctrlAltCmdY: return "⌃⌥⌘ Y"
        case .ctrlAltCmdJ: return "⌃⌥⌘ J"
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .off:         return nil
        case .ctrlAltCmdA: return UInt32(kVK_ANSI_A)
        case .ctrlAltCmdG: return UInt32(kVK_ANSI_G)
        case .ctrlAltCmdY: return UInt32(kVK_ANSI_Y)
        case .ctrlAltCmdJ: return UInt32(kVK_ANSI_J)
        }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .off:
            return nil
        case .ctrlAltCmdA, .ctrlAltCmdG, .ctrlAltCmdY, .ctrlAltCmdJ:
            return UInt32(controlKey | optionKey | cmdKey)
        }
    }
}
