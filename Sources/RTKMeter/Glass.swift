import AppKit
import SwiftUI

/// Tracks the accessibility display settings that decide whether the popover may
/// use translucency, and republishes them when the user changes them.
final class AppearanceMonitor: ObservableObject {
    @Published private(set) var reduceTransparency: Bool
    @Published private(set) var increaseContrast: Bool
    @Published private(set) var reduceMotion: Bool
    /// The system Liquid Glass tint slider (Appearance settings), 0 = clear,
    /// 1 = fully tinted. Absent before macOS 26, where 0.5 is a fair neutral.
    @Published private(set) var glassTint: Double

    /// Preferences written by System Settings reach us lazily, so the value is
    /// re-read whenever the popover is about to be shown.
    func refreshFromSystem() {
        let value = Self.readGlassTint()
        if value != glassTint { glassTint = value }
    }

    private static func readGlassTint() -> Double {
        if let override = ProcessInfo.processInfo.environment["PREVIEW_GLASS_TINT"],
           let value = Double(override) {
            return min(max(value, 0), 1)
        }
        // Read through CFPreferences after a sync: UserDefaults caches other
        // domains for the life of the process, so a slider moved in System
        // Settings would otherwise never reach a long-running agent.
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let raw = CFPreferencesCopyValue("NSGlassTintAmount" as CFString,
                                         kCFPreferencesAnyApplication,
                                         kCFPreferencesCurrentUser,
                                         kCFPreferencesAnyHost)
        guard let stored = (raw as? NSNumber)?.doubleValue else { return 0.5 }
        return min(max(stored, 0), 1)
    }

    init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        glassTint = Self.readGlassTint()

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
            self.glassTint = Self.readGlassTint()
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
enum PanelStyle: Equatable {
    /// Liquid Glass, macOS 26 and later, carrying the system tint amount so the
    /// panels follow the Appearance slider instead of pinning one look.
    case glass(tint: Double)
    /// A vibrant material: the same intent on older systems.
    case material
    /// Opaque fills, for Reduce Transparency.
    case solid

    static func resolve(monitor: AppearanceMonitor, enabled: Bool) -> PanelStyle {
        guard enabled, !monitor.reduceTransparency else { return .solid }
        if #available(macOS 26.0, *) { return .glass(tint: monitor.glassTint) }
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
        case .glass(let tint):
            if #available(macOS 26.0, *) {
                // Below the midpoint the slider asks for clear glass, above it
                // for tinted; the fill underneath tracks the whole range, so
                // moving the slider changes the panels rather than only their
                // edges. At 0 the panel is pure glass, at 1 it is nearly solid.
                let base: Glass = tint < 0.5 ? .clear : .regular
                background(Color(nsColor: .controlBackgroundColor).opacity(0.55 * tint),
                           in: shape)
                    .glassEffect(base, in: shape)
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
