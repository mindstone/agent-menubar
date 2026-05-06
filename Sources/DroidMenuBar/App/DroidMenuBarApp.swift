import SwiftUI
import AppKit
import Combine

@main
struct DroidMenuBarApp: App {
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
            NSLog("DroidMenuBar: listening at \(HookSocketServer.socketURL.path)")
        } catch {
            NSLog("DroidMenuBar: socket bootstrap failed: \(error)")
        }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        item.behavior = []
        item.autosaveName = "dev.harry.droid-menubar.statusitem"
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
        pop.behavior = .transient
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

        NSLog("DroidMenuBar: status item registered (visible=\(item.isVisible))")
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
            removeEventMonitor()
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            addEventMonitor()
        }
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

    private func render(_ state: MenuBarState) {
        guard let button = statusItem?.button else { return }

        button.image = nil
        button.contentTintColor = nil

        switch state {
        case .idle:
            button.attributedTitle = NSAttributedString(
                string: "🤖",
                attributes: [.font: NSFont.systemFont(ofSize: 14)]
            )
        case .tracking(let count):
            button.attributedTitle = NSAttributedString(
                string: "🤖 \(count)",
                attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .medium)]
            )
        case .attention(let count, _):
            button.attributedTitle = NSAttributedString(
                string: "❓ \(count)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                    .foregroundColor: NSColor.systemOrange
                ]
            )
        }

        button.needsDisplay = true
        NSLog("DroidMenuBar.render: state=\(state) frame=\(button.frame) title='\(button.title)'")
    }
}
