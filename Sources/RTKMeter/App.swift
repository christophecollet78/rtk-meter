import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let settings = AppSettings.shared
    private lazy var store = StatsStore(settings: settings)
    private let updater = Updater()
    private let appearance = AppearanceMonitor()
    private var timer: Timer?
    private var updateTimer: Timer?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // A symbol plus a short percentage: a wide title is the first thing macOS
        // drops when the menu bar runs out of room next to the notch.
        let icon = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent",
                           accessibilityDescription: "RTK efficiency")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = " …"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: DetailView(store: store, settings: settings, updater: updater,
                                 appearance: appearance))

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.renderTitle() }
            .store(in: &subscriptions)

        settings.$refreshInterval
            .removeDuplicates()
            .sink { [weak self] interval in self?.scheduleTimer(every: interval) }
            .store(in: &subscriptions)

        settings.$showPercentage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.renderTitle() }
            .store(in: &subscriptions)

        store.refresh()
        scheduleUpdateChecks()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refreshNow),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: Refresh

    private func scheduleTimer(every interval: TimeInterval) {
        timer?.invalidate()
        let t = Timer(timeInterval: max(interval, 5), repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
        // Let macOS coalesce this with other timers; the exact second does not matter.
        t.tolerance = max(interval * 0.1, 2)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func refreshNow() { store.refresh() }

    /// Checks shortly after launch, then twice a day; GitHub allows 60 anonymous
    /// API calls an hour, so this is nowhere near the limit.
    private func scheduleUpdateChecks() {
        guard updater.canCheck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.updater.check()
        }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.updater.check()
        }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
    }

    // MARK: Status bar title

    private func renderTitle() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        guard let summary = store.stats?.summary else {
            if store.error != nil {
                statusItem.button?.attributedTitle =
                    NSAttributedString(string: " ⚠︎", attributes: [.font: font])
                statusItem.button?.toolTip = store.error?.message
            }
            return
        }
        let title = settings.showPercentage ? " \(Fmt.pct(summary.avgSavingsPct))" : ""
        statusItem.button?.attributedTitle =
            NSAttributedString(string: title, attributes: [.font: font])
        statusItem.button?.toolTip = """
            RTK — \(Fmt.pct(summary.avgSavingsPct)) saved \
            (\(Fmt.compact(summary.totalSaved)) tokens, \(settings.scopeLabel))
            """
    }

    // MARK: Interaction

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            store.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Without this the popover opens behind the frontmost app and loses key focus.
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow),
                                 keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit RTK Meter",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil  // restore left-click popover behaviour
    }
}
