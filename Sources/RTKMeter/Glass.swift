import AppKit
import SwiftUI

/// Tracks the accessibility display settings that decide whether the popover may
/// use translucency, and republishes them when the user changes them.
final class AppearanceMonitor: ObservableObject {
    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var increaseContrast: Bool
    @Published private(set) var reduceMotion: Bool

    init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(optionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
    }

    @objc private func optionsChanged() {
        let workspace = NSWorkspace.shared
        DispatchQueue.main.async {
            self.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
            self.increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
            self.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        }
    }
}

/// An AppKit material, for the macOS versions that predate Liquid Glass.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
        view.isEmphasized = emphasized
    }
}

/// How a panel should be drawn, given the system settings and the user's own
/// preference. Resolved once per render so every panel agrees.
enum PanelStyle {
    /// Liquid Glass, macOS 26 and later.
    case glass
    /// A vibrant material: the same intent on older systems.
    case material
    /// Opaque fills, for Reduce Transparency.
    case solid

    static func resolve(monitor: AppearanceMonitor, enabled: Bool) -> PanelStyle {
        guard enabled, !monitor.reduceTransparency else { return .solid }
        if #available(macOS 26.0, *) { return .glass }
        return .material
    }
}

extension View {
    /// Draws the receiver as a panel: Liquid Glass where available, a vibrant
    /// material before that, and a plain fill whenever the system asks for
    /// reduced transparency.
    @ViewBuilder
    func panelBackground(_ style: PanelStyle, cornerRadius: CGFloat = 12,
                         bordered: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        switch style {
        case .glass:
            if #available(macOS 26.0, *) {
                glassEffect(.regular, in: shape)
                    .overlay { if bordered { shape.strokeBorder(.separator, lineWidth: 1) } }
            } else {
                self
            }
        case .material:
            background {
                VisualEffectBackground(material: .hudWindow, blending: .withinWindow)
                    .clipShape(shape)
            }
            .overlay { if bordered { shape.strokeBorder(.separator, lineWidth: 1) } }
        case .solid:
            background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay { if bordered { shape.strokeBorder(.separator, lineWidth: 1) } }
        }
    }

    /// Groups sibling panels so their glass can merge, on the systems that do that.
    @ViewBuilder
    func panelGroup(_ style: PanelStyle, spacing: CGFloat = 12) -> some View {
        if case .glass = style, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}
