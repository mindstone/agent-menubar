import AppKit
import Carbon.HIToolbox

/// Carbon `RegisterEventHotKey` wrapper. Carbon is chosen over
/// `NSEvent.addGlobalMonitorForEvents` because it actually *consumes* the key
/// combo system-wide, preventing the active app from also receiving it — the
/// expected UX for an app-launcher-style global shortcut.
final class GlobalHotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onPress: () -> Void
    private var current: HotkeyChoice = .off

    init(onPress: @escaping () -> Void) {
        self.onPress = onPress
        installEventHandler()
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
    }

    func apply(_ choice: HotkeyChoice) {
        guard choice != current else { return }
        current = choice
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        guard let keyCode = choice.keyCode, let modifiers = choice.carbonModifiers else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x414D4250), id: 1) // "AMBP"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref = ref {
            hotKeyRef = ref
            NSLog("AgentMenuBar: global hotkey registered (\(choice.label))")
        } else {
            NSLog("AgentMenuBar: hotkey registration failed for \(choice.label) (status \(status))")
        }
    }

    private func installEventHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { (_, _, userData) -> OSStatus in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            // Defer to the next runloop tick so popover toggling doesn't run
            // inside the Carbon dispatch frame.
            DispatchQueue.main.async { manager.onPress() }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventSpec,
            userData,
            &eventHandlerRef
        )
    }
}
