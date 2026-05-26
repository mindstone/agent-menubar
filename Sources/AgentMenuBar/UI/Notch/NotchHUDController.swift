import AppKit
import SwiftUI
import Combine

@MainActor
final class NotchHUDController {
    private let store: SessionStore
    private let onFocus: (DroidSession) -> Void
    private let onPopover: () -> Void
    private let panel: NotchPanel
    private let hosting: NSHostingView<NotchView>
    let anchorView: NSView
    private var cancellables: Set<AnyCancellable> = []
    private var pinnedScreen: NSScreen?
    private var currentNotchInset: CGFloat = 32
    private var currentNotchWidth: CGFloat = 200
    private var rightClickMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var pillBoundsInPanel: CGRect = .zero
    private var swiftUIExpanded: Bool = false

    /// Total panel height = max bezel inset (~40 on 16") + max visible card
    /// height (96) + a small safety margin so the pill never gets clipped on
    /// screens with unusually thick bezels.
    private static let panelHeight: CGFloat = 40 + 96 + 8
    private static let panelWidth: CGFloat = 360

    init(
        store: SessionStore,
        onFocus: @escaping (DroidSession) -> Void,
        onPopover: @escaping () -> Void
    ) {
        self.store = store
        self.onFocus = onFocus
        self.onPopover = onPopover

        let panelRect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        self.panel = NotchPanel(
            contentRect: panelRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        // Start fully pass-through. The mouse-moved monitor flips this off
        // when the cursor enters the visible pill so the rest of the panel
        // surface is permanently click-through to apps underneath.
        panel.ignoresMouseEvents = true

        // Seed with a no-op bounds callback so we can finish initialising
        // stored properties; the real callback is wired below once `self`
        // is fully formed.
        let view = NotchView(
            store: store,
            notchInset: 32,
            notchWidth: 200,
            onFocusRequest: onFocus,
            onPopoverRequest: onPopover,
            onPillBoundsChange: { _ in },
            onExpansionChange: { _ in }
        )
        let host = NSHostingView(rootView: view)
        host.frame = panelRect
        host.autoresizingMask = [.width, .height]
        self.hosting = host

        // Anchor used by the popover. y is in AppKit (bottom-up) coords; we
        // want it just below the pill's collapsed bottom so the popover drops
        // straight down from the notch when clicked.
        let anchor = NSView(frame: NSRect(
            x: Self.panelWidth / 2 - 0.5,
            y: Self.panelHeight - 32 - NotchView.collapsedVisibleHeight - 1,
            width: 1,
            height: 1
        ))
        self.anchorView = anchor

        let container = NSView(frame: panelRect)
        container.autoresizesSubviews = true
        container.addSubview(host)
        container.addSubview(anchor)
        panel.contentView = container

        // Swap in the real callbacks now that `self` is initialised.
        hosting.rootView = NotchView(
            store: store,
            notchInset: 32,
            notchWidth: 200,
            onFocusRequest: onFocus,
            onPopoverRequest: onPopover,
            onPillBoundsChange: { [weak self] rect in
                Task { @MainActor in self?.updatePillBounds(rect) }
            },
            onExpansionChange: { [weak self] expanded in
                Task { @MainActor in self?.updateExpansion(expanded) }
            }
        )

        observeStore()
        observeScreens()
        observeMode()
        installRightClickMonitor()
        installMouseMoveMonitors()
        refreshVisibility()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let monitor = rightClickMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func installRightClickMonitor() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            let action = self.onPopover
            DispatchQueue.main.async { action() }
            return nil
        }
    }

    /// Toggle `panel.ignoresMouseEvents` based on whether the cursor is over
    /// the visible pill. Without this the full 360×144 panel intercepts every
    /// click in the top-center of the screen, blocking the app underneath.
    private func installMouseMoveMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.updatePassthrough() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.updatePassthrough() }
            return event
        }
    }

    fileprivate func updatePillBounds(_ rect: CGRect) {
        pillBoundsInPanel = rect
        updatePassthrough()
    }

    fileprivate func updateExpansion(_ expanded: Bool) {
        swiftUIExpanded = expanded
        updatePassthrough()
    }

    private func updatePassthrough() {
        guard panel.isVisible else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        // While expanded, keep the panel fully interactive — clicking, hover,
        // right-click and the × button must all reach SwiftUI even if the
        // PreferenceKey-driven bounds haven't republished the new rect yet
        // and the cursor has drifted off the old collapsed bounds.
        if swiftUIExpanded {
            if panel.ignoresMouseEvents { panel.ignoresMouseEvents = false }
            return
        }
        guard pillBoundsInPanel.width > 0, pillBoundsInPanel.height > 0 else {
            if !panel.ignoresMouseEvents { panel.ignoresMouseEvents = true }
            return
        }
        // SwiftUI .global is top-down inside the hosting view; panel.frame is
        // bottom-up screen coords. Convert pill bounds → screen rect.
        let panelFrame = panel.frame
        let pillScreenRect = NSRect(
            x: panelFrame.origin.x + pillBoundsInPanel.origin.x,
            y: panelFrame.maxY - pillBoundsInPanel.maxY,
            width: pillBoundsInPanel.width,
            height: pillBoundsInPanel.height
        )
        let cursor = NSEvent.mouseLocation
        let cursorOverPill = pillScreenRect.contains(cursor)
        let shouldIgnore = !cursorOverPill
        if panel.ignoresMouseEvents != shouldIgnore {
            panel.ignoresMouseEvents = shouldIgnore
        }
    }

    // MARK: - Observation

    private func observeStore() {
        store.$menuBarState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshVisibility() }
            .store(in: &cancellables)
    }

    private func observeScreens() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshVisibility() }
        }
    }

    private func observeMode() {
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshVisibility() }
        }
    }

    // MARK: - Resolution

    private var resolvedMode: NotchHUDMode {
        let raw = UserDefaults.standard.string(forKey: NotchHUDMode.storageKey) ?? NotchHUDMode.auto.rawValue
        return NotchHUDMode(rawValue: raw) ?? .auto
    }

    private func resolvedScreen() -> NSScreen? {
        switch resolvedMode {
        case .off:
            return nil
        case .auto:
            return NotchAvailability.notchedScreen()
        case .on:
            // Forced-on falls back to the main screen with a synthetic 0pt
            // inset so the pill renders below the menu bar on un-notched Macs.
            return NotchAvailability.notchedScreen() ?? NSScreen.main
        }
    }

    // MARK: - Visibility

    func refreshVisibility() {
        guard store.menuBarState != .idle, let screen = resolvedScreen() else {
            if panel.isVisible { panel.orderOut(nil) }
            pinnedScreen = nil
            return
        }
        pin(to: screen)
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func pin(to screen: NSScreen) {
        let inset: CGFloat = NotchAvailability.notchInset(for: screen)
        let width: CGFloat = Self.notchWidth(for: screen)
        let originX = screen.frame.midX - Self.panelWidth / 2
        let originY = screen.frame.maxY - Self.panelHeight
        let frame = NSRect(x: originX, y: originY, width: Self.panelWidth, height: Self.panelHeight)

        if panel.frame != frame {
            panel.setFrame(frame, display: true)
        }

        let insetChanged = abs(inset - currentNotchInset) > 0.1
        let widthChanged = abs(width - currentNotchWidth) > 0.1
        if insetChanged || widthChanged {
            currentNotchInset = inset
            currentNotchWidth = width
            hosting.rootView = NotchView(
                store: store,
                notchInset: inset,
                notchWidth: width,
                onFocusRequest: onFocus,
                onPopoverRequest: onPopover,
                onPillBoundsChange: { [weak self] rect in
                    Task { @MainActor in self?.updatePillBounds(rect) }
                },
                onExpansionChange: { [weak self] expanded in
                    Task { @MainActor in self?.updateExpansion(expanded) }
                }
            )

            // Re-position the popover anchor relative to the new inset so the
            // popover drops just below the visible collapsed pill bottom.
            anchorView.frame = NSRect(
                x: Self.panelWidth / 2 - 0.5,
                y: Self.panelHeight - inset - NotchView.collapsedVisibleHeight - 1,
                width: 1,
                height: 1
            )
        }

        pinnedScreen = screen
    }

    /// Pixel width of the physical notch on `screen`, computed as the gap
    /// between the menu-bar auxiliary regions on either side of the camera
    /// cutout. Falls back to 200 pt on screens that don't expose aux areas
    /// (e.g. un-notched Macs being driven by `.on` mode for testing).
    private static func notchWidth(for screen: NSScreen) -> CGFloat {
        let leftEnd = screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX
        let rightStart = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        let gap = max(0, rightStart - leftEnd)
        return gap > 0 ? gap : 200
    }
}

/// `NSPanel` subclass that never becomes key — defence-in-depth so menu bar
/// status and active app focus never get stolen when the HUD is clicked.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
