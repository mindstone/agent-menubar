import SwiftUI
import AppKit
import Combine

@main
struct AgentMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var store: SessionStore!
    private var server: HookSocketServer!
    private var cancellables: Set<AnyCancellable> = []
    private var eventMonitor: Any?
    private var flashTimer: Timer?
    private var flashOn: Bool = true
    private var currentState: MenuBarState = .idle
    private var notchHUD: NotchHUDController?
    private var hotkeyManager: GlobalHotkeyManager?
    private var hotkeyDefaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = SessionStore()
        server = HookSocketServer()
        do {
            try server.start { [weak self] event in
                Task { @MainActor in
                    self?.store.apply(event)
                }
            }
            NSLog("AgentMenuBar: listening at \(HookSocketServer.socketURL.path)")
        } catch {
            NSLog("AgentMenuBar: socket bootstrap failed: \(error)")
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        item.behavior = []
        item.autosaveName = "com.mindstone.agentmenubar.statusitem"
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            button.imagePosition = .imageLeft
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.menuBarFont(ofSize: 0)
        }
        self.statusItem = item

        let pop = NSPopover()
        pop.behavior = .applicationDefined
        pop.animates = true
        pop.contentSize = NSSize(width: 380, height: 480)
        pop.contentViewController = NSHostingController(
            rootView: SessionListView()
                .environmentObject(store)
                .frame(width: 380)
        )
        self.popover = pop

        store.$menuBarState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in self?.render(state) }
            .store(in: &cancellables)
        render(store.menuBarState)

        notchHUD = NotchHUDController(
            store: store,
            onFocus: { [weak self] session in
                Task { @MainActor in self?.store.focus(session) }
            },
            onPopover: { [weak self] in
                Task { @MainActor in self?.toggleNotchPopover() }
            }
        )

        hotkeyManager = GlobalHotkeyManager { [weak self] in
            Task { @MainActor in self?.toggleFromHotkey() }
        }
        applyHotkeyFromDefaults()
        hotkeyDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyHotkeyFromDefaults() }
        }

        NSLog("AgentMenuBar: status item registered (visible=\(item.isVisible))")
    }

    private func applyHotkeyFromDefaults() {
        let raw = UserDefaults.standard.string(forKey: HotkeyChoice.storageKey) ?? HotkeyChoice.off.rawValue
        let choice = HotkeyChoice(rawValue: raw) ?? .off
        hotkeyManager?.apply(choice)
    }

    private func toggleFromHotkey() {
        guard let button = statusItem?.button else { return }
        toggle(from: button)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        toggle(from: button)
    }

    private func toggleNotchPopover() {
        guard let anchor = notchHUD?.anchorView else { return }
        toggle(from: anchor)
    }

    private func toggle(from anchor: NSView) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            removeEventMonitor()
        } else {
            presentPopover(from: anchor)
        }
    }

    private func presentPopover(from anchor: NSView) {
        guard let popover else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        addEventMonitor()
    }

    private func addEventMonitor() {
        removeEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover?.performClose(nil) }
        }
    }

    private func removeEventMonitor() {
        if let m = eventMonitor { NSEvent.removeMonitor(m); eventMonitor = nil }
    }

    private static let sparklineMax = 10

    private func render(_ state: MenuBarState) {
        currentState = state
        if state.hasAttention {
            flashOn = true
            startFlashing()
        } else {
            stopFlashing()
        }
        applyTitle(for: state, flashOn: flashOn)
    }

    private func applyTitle(for state: MenuBarState, flashOn: Bool) {
        guard let button = statusItem?.button else { return }

        button.image = nil
        button.contentTintColor = nil

        switch state {
        case .idle:
            button.attributedTitle = NSAttributedString(
                string: "🤖",
                attributes: [.font: NSFont.systemFont(ofSize: 14)]
            )

        case .active(let running, let waiting, let finished):
            let (r, w, f) = allocateSquares(running: running, waiting: waiting, finished: finished, capacity: Self.sparklineMax)
            button.attributedTitle = sparklineTitle(running: r, waiting: w, finished: f, flashOn: flashOn)
        }

        button.needsDisplay = true
    }

    private func sparklineTitle(running: Int, waiting: Int, finished: Int, flashOn: Bool) -> NSAttributedString {
        let waitingGlyph = flashOn ? "🟧" : "⬜"
        let squares =
            String(repeating: waitingGlyph, count: waiting) +
            String(repeating: "🟦", count: running) +
            String(repeating: "🟩", count: finished)
        return NSAttributedString(
            string: squares,
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
    }

    /// Largest-remainder proportional allocation. Ensures waiting >= 1 square
    /// if any sessions are waiting so the attention signal never gets squeezed out.
    private func allocateSquares(running: Int, waiting: Int, finished: Int, capacity: Int) -> (Int, Int, Int) {
        let total = running + waiting + finished
        guard total > capacity else { return (running, waiting, finished) }

        let scale = Double(capacity) / Double(total)
        let raw: [Double] = [Double(running) * scale, Double(waiting) * scale, Double(finished) * scale]
        var floors = raw.map { Int($0) }
        var leftover = capacity - floors.reduce(0, +)
        let remainders = raw.enumerated()
            .map { (idx: $0.offset, frac: $0.element - Double(Int($0.element))) }
            .sorted { $0.frac > $1.frac }
        var ri = 0
        while leftover > 0 && ri < remainders.count {
            floors[remainders[ri].idx] += 1
            leftover -= 1
            ri += 1
        }
        var (r, w, f) = (floors[0], floors[1], floors[2])
        if waiting > 0 && w == 0 {
            w = 1
            if f > 0 { f -= 1 } else if r > 0 { r -= 1 }
        }
        return (r, w, f)
    }

    private func startFlashing() {
        guard flashTimer == nil else { return }
        flashTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.flashOn.toggle()
                self.applyTitle(for: self.currentState, flashOn: self.flashOn)
            }
        }
    }

    private func stopFlashing() {
        flashTimer?.invalidate()
        flashTimer = nil
        flashOn = true
    }
}
