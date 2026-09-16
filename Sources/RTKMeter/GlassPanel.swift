import AppKit
import SwiftUI

/// A borderless panel hung under the status item.
///
/// NSPopover draws its own opaque chrome, which leaves glass panels inside it
/// nothing to refract and makes the system transparency settings irrelevant.
/// Owning the window means the background really is a material, so the desktop
/// shows through and the Appearance settings apply to it.
final class GlassPanelController<Content: View> {
    private let panel: NSPanel
    private let hosting: NSHostingView<AnyView>
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var resignObserver: Any?

    /// Called when the panel closes itself, so the owner can update state.
    var onClose: (() -> Void)?

    init(content: Content) {
        // The content paints and shapes its own background: it knows the
        // appearance settings, the window stays transparent so the material
        // reaches the desktop, and no border of ours covers the glass edge.
        hosting = NSHostingView(rootView: AnyView(content))

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(from button: NSStatusBarButton) {
        if isVisible { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }

        hosting.layoutSubtreeIfNeeded()
        let size = NSSize(width: 340, height: hosting.fittingSize.height)
        hosting.setFrameSize(size)

        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - size.height - 6)
        if let visible = screen?.visibleFrame {
            // Keep the panel on screen when the status item sits near an edge.
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        startDismissMonitors()
    }

    func close() {
        stopDismissMonitors()
        panel.orderOut(nil)
        onClose?()
    }

    // MARK: Dismissal

    private func startDismissMonitors() {
        stopDismissMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        // A click inside our own window must not dismiss it, so only the Escape
        // key is handled locally.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {  // Escape
                self?.close()
                return nil
            }
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            self?.close()
        }
    }

    private func stopDismissMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        globalMonitor = nil
        localMonitor = nil
        resignObserver = nil
    }

    /// The window number, for the diagnostics screenshot.
    var windowNumber: Int { panel.windowNumber }
}
