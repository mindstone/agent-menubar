import Foundation
import Carbon.HIToolbox

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case off
    case shiftOptCmdA
    case shiftOptCmdG
    case shiftOptCmdY
    case shiftOptCmdJ

    static let storageKey = "globalHotkey"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:           return "Off"
        case .shiftOptCmdA:  return "⌥⇧⌘ A"
        case .shiftOptCmdG:  return "⌥⇧⌘ G"
        case .shiftOptCmdY:  return "⌥⇧⌘ Y"
        case .shiftOptCmdJ:  return "⌥⇧⌘ J"
        }
    }

    var keyCode: UInt32? {
        switch self {
        case .off:           return nil
        case .shiftOptCmdA:  return UInt32(kVK_ANSI_A)
        case .shiftOptCmdG:  return UInt32(kVK_ANSI_G)
        case .shiftOptCmdY:  return UInt32(kVK_ANSI_Y)
        case .shiftOptCmdJ:  return UInt32(kVK_ANSI_J)
        }
    }

    var carbonModifiers: UInt32? {
        switch self {
        case .off:
            return nil
        case .shiftOptCmdA, .shiftOptCmdG, .shiftOptCmdY, .shiftOptCmdJ:
            return UInt32(shiftKey | optionKey | cmdKey)
        }
    }
}
