import AppKit

enum NotchAvailability {
    /// The first connected screen with a hardware notch
    /// (`safeAreaInsets.top > 0`), or `nil` when none exists — e.g. clamshell
    /// mode with an external display, a non-notched MacBook, or a Mac mini.
    static func notchedScreen() -> NSScreen? {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            return screen
        }
        return nil
    }

    /// Notch height (= menu bar height) on a given screen, in points.
    static func notchInset(for screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top
    }
}
